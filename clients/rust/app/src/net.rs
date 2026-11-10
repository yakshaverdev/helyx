//! The network thread of the app: one WebSocket to the server at a time,
//! driven by `helyx_client_core::client::Client`. The window reads `Shared`
//! and sends `Command`s; the thread calls `notify` after each change.
//!
//! Every wait of a connection after its TCP connect is a deadline of its
//! socket, which a watchdog thread holds (`socket::Watchdog`). An operation
//! goes as a typed `Operation` of the core, and its line in `Shared` shows
//! its state: pending, ok, the error of the server, or unknown when the
//! connection ended before its reply (ADR 0006 §4). A numbered send (of the
//! composer, or the answer of an ask) also gets one outcome in `outcomes`:
//! `Pending`, `Ok`, or `Failed` with a reason, so the window empties its
//! composer on `ok` and shows an ask again when its answer failed.

use crate::composer::{SendId, SendOutcome};
use crate::input::BUSY;
use crate::settings::Server;
use crate::socket::{Tap, WAITS, Waits, Watchdog};
use helyx_client_core::client::{Client, Follow, Hold, Next, Output, Refusal, Wait};
use helyx_client_core::frame::{LiveSession, Reply, SavedSession};
use helyx_client_core::json::object;
use helyx_client_core::operation::{MAX_LIMIT, Operation, Saved};
use helyx_client_core::parts::FRAME_BYTES;
use helyx_client_core::vocabulary::head;
use std::collections::HashMap;
use std::io::ErrorKind;
use std::net::{SocketAddr, TcpStream};
use std::sync::Mutex;
use std::sync::mpsc::{Receiver, TryRecvError};
use tungstenite::error::ProtocolError;
use tungstenite::protocol::WebSocketConfig;
use tungstenite::{Error, Message, WebSocket};

/// The request lines that the window keeps: the pending ones stay, so a
/// request in flight is never dropped from the list.
pub const MAX_LINES: usize = 12;
/// The bytes of a saved prompt that the window keeps for its list: the rest
/// of a prompt of up to 65,536 bytes is not drawn.
pub const MAX_PROMPT_BYTES: usize = 200;
/// The bytes of the text of a message that its request line names.
const MAX_LABEL_BYTES: usize = 40;
/// The line of a request that the client refused before it went.
const NOT_SENT: &str = "not sent";
/// The outcomes that the window has not read yet: at most two for each send
/// that the input holds (one composer send and the hidden answers), and the
/// window reads them all at each redraw. A host that never reads stops the
/// queue at this bound.
const MAX_OUTCOMES: usize = 64;

/// What the window asks.
#[derive(Debug, Clone, PartialEq)]
pub enum Command {
    /// Follow this session, and stop following the one before.
    Follow(String),
    /// Send an operation of the window: a prompt, a steer, a follow-up, an
    /// abort, the answer of an ask, a start, or a resume. `send` is the
    /// number of the send that the window waits for the outcome of, when it
    /// is one: a send of the composer or the answer of an ask.
    Operation {
        send: Option<SendId>,
        operation: Operation,
    },
    /// A page of the saved sessions; `after` is the `next` of the page
    /// before, or none for the first page.
    Saved { after: Option<String> },
}

/// The state of one request in the window.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RequestState {
    /// Sent, and the server has not answered.
    Pending,
    /// The server answered `ok`.
    Ok,
    /// The server answered with this error, or the client refused the
    /// request before it went, which `code` says as `not sent`.
    Error { code: String, text: String },
    /// The connection ended before the reply: the result is unknown, and the
    /// user decides whether to send it again (ADR 0006 §4).
    Unknown,
}

impl RequestState {
    pub fn text(&self) -> String {
        match self {
            RequestState::Pending => "pending".into(),
            RequestState::Ok => "ok".into(),
            RequestState::Error { code, text } => format!("{code}: {text}"),
            RequestState::Unknown => {
                "unknown: the reply was lost, send it again if you wish".into()
            }
        }
    }
}

/// One request of the window, as its status line shows it.
#[derive(Debug, Clone, PartialEq)]
pub struct RequestLine {
    pub id: String,
    pub op: &'static str,
    /// The op and a short text, for a person.
    pub label: String,
    pub state: RequestState,
    /// The number of the send that this request is, when the window waits
    /// for its outcome.
    pub send: Option<SendId>,
}

impl RequestLine {
    /// The line that the window draws.
    pub fn text(&self) -> String {
        format!("{} · {}", self.label, self.state.text())
    }
}

/// What the window shows.
#[derive(Debug)]
pub struct Shared {
    pub client: Client,
    /// The live sessions of the server, from `sessions.live` at each welcome.
    pub live: Vec<LiveSession>,
    /// The session that the window follows.
    pub followed: Option<String>,
    /// One line of the state of the connection.
    pub line: String,
    /// The saved sessions, newest first, with each prompt cut for the list.
    pub saved: Vec<SavedSession>,
    /// The `next` of the last page of saved sessions, when more exist.
    pub saved_next: Option<String>,
    /// The requests of the window, oldest first.
    pub requests: Vec<RequestLine>,
    /// The outcome of each numbered send that the client took, answered, or
    /// lost: the window drains it and settles its composer or its ask.
    pub outcomes: Vec<(SendId, SendOutcome)>,
    /// The window asked for the saved sessions on this run.
    saved_asked: bool,
    /// The replace-or-append mode of each `sessions.saved` request in
    /// flight, by its id: a page appends at the `next` of the page before.
    saved_pages: HashMap<String, bool>,
    /// A page of saved sessions is on its way: one at a time, so two pages
    /// cannot replace and append the list in the wrong order.
    saved_pending: bool,
}

impl Shared {
    pub fn new(token: String) -> Shared {
        Shared {
            client: Client::new(Some(token)),
            live: vec![],
            followed: None,
            line: "connecting".into(),
            saved: vec![],
            saved_next: None,
            requests: vec![],
            outcomes: vec![],
            saved_asked: false,
            saved_pages: HashMap::new(),
            saved_pending: false,
        }
    }

    /// Gives the outcome of a numbered send to the window, within the bound.
    fn outcome(&mut self, send: SendId, outcome: SendOutcome) {
        self.outcomes.push((send, outcome));
        if self.outcomes.len() > MAX_OUTCOMES {
            self.outcomes.remove(0);
        }
    }

    /// Records a request that the client took: its line, and its send as
    /// pending.
    fn sent(&mut self, id: String, op: &'static str, label: String, send: Option<SendId>) {
        self.requests.push(RequestLine {
            id,
            op,
            label,
            state: RequestState::Pending,
            send,
        });
        if let Some(send) = send {
            self.outcome(send, SendOutcome::Pending);
        }
        self.trim();
    }

    /// Records a request that the client refused before it went: its line is
    /// an `Error` with `not sent`, and its send failed with that reason.
    fn refused(&mut self, op: &'static str, label: String, send: Option<SendId>, reason: String) {
        self.requests.push(RequestLine {
            id: String::new(),
            op,
            label,
            state: RequestState::Error {
                code: NOT_SENT.into(),
                text: reason.clone(),
            },
            send,
        });
        if let Some(send) = send {
            self.outcome(send, SendOutcome::Failed(reason));
        }
        self.trim();
    }

    /// The server answered the request `id`: its line takes the result, and
    /// the op of the line comes back.
    fn answered(
        &mut self,
        id: &str,
        result: &Result<Reply, (String, String)>,
    ) -> Option<&'static str> {
        // The ids of a connection count from 0, and only a request of the
        // current connection waits, so a pending line is the one.
        let line = self
            .requests
            .iter_mut()
            .find(|line| line.id == id && line.state == RequestState::Pending)?;
        line.state = match result {
            Ok(_) => RequestState::Ok,
            Err((code, text)) => RequestState::Error {
                code: code.clone(),
                text: text.clone(),
            },
        };
        let op = line.op;
        let send = line.send;
        self.trim();
        if let Some(send) = send {
            let outcome = match result {
                Ok(_) => SendOutcome::Ok,
                Err((code, text)) => SendOutcome::Failed(format!("{code}: {text}")),
            };
            self.outcome(send, outcome);
        }
        Some(op)
    }

    /// The connection ended with these requests in flight: each line is
    /// `Unknown`, and its numbered send failed with a lost reply (ADR 0006
    /// §4). None of them goes again.
    fn unknown(&mut self, lost: &[&str]) {
        for id in lost {
            let found = self
                .requests
                .iter_mut()
                .find(|line| line.id == *id && line.state == RequestState::Pending)
                .map(|line| {
                    line.state = RequestState::Unknown;
                    (line.op, line.send)
                });
            if let Some((op, send)) = found {
                if let Some(send) = send {
                    self.outcome(send, SendOutcome::Failed("the reply was lost".into()));
                }
                if op == "sessions.saved" {
                    self.saved_pages.remove(*id);
                    self.saved_pending = false;
                }
            }
        }
    }

    /// Drops the oldest answered line past `MAX_LINES`; a pending one stays.
    fn trim(&mut self) {
        while self.requests.len() > MAX_LINES {
            match (self.requests.iter()).position(|line| line.state != RequestState::Pending) {
                Some(at) => {
                    self.requests.remove(at);
                }
                None => break,
            }
        }
    }
}

/// The text of a refusal of the client, for a person: what did not go and
/// why.
fn refusal_text(refusal: &Refusal) -> String {
    match refusal {
        Refusal::NotReady => "the connection is not ready".into(),
        Refusal::Busy => BUSY.into(),
        Refusal::TooManySubscriptions => "16 sessions are followed".into(),
        Refusal::TooLarge => "the request is over its size".into(),
        Refusal::Subscription => "a subscription goes another way".into(),
    }
}

/// Runs connections until one ends with `Next::Stop`, or the window is gone
/// at the end of one, and gives its line.
pub fn run(
    server: &Server,
    shared: &Mutex<Shared>,
    commands: &Receiver<Command>,
    notify: &dyn Fn(),
) -> String {
    run_with(server, shared, commands, notify, WAITS)
}

/// `run` with other waits, for tests.
pub fn run_with(
    server: &Server,
    shared: &Mutex<Shared>,
    commands: &Receiver<Command>,
    notify: &dyn Fn(),
    waits: Waits,
) -> String {
    loop {
        let (next, line) = connection(server, shared, commands, notify, waits);
        shared.lock().unwrap().line = line.clone();
        notify();
        let gone = window_gone(shared, commands);
        // A command that the window sent between connections shows its line.
        notify();
        if next == Next::Stop || gone {
            return line;
        }
        std::thread::sleep(waits.pause);
    }
}

type Socket = WebSocket<Tap>;

fn connection(
    server: &Server,
    shared: &Mutex<Shared>,
    commands: &Receiver<Command>,
    notify: &dyn Fn(),
    waits: Waits,
) -> (Next, String) {
    let (mut ws, watchdog) = match open(server, waits) {
        Ok(opened) => opened,
        Err(text) => {
            let next = close(shared, None);
            let line = format!("could not connect to {}: {text}", server.url());
            return (next, line);
        }
    };
    shared.lock().unwrap().client.connect();
    let mut welcomed = false;
    // The end of the connection after an error: a break when the server
    // sent a binary frame, whatever error ended it, else a lost connection.
    let ended = |ws: &mut Socket, welcomed: bool| {
        if ws.get_ref().binary() {
            return broken(shared, ws);
        }
        let next = close(shared, None);
        let line = match (watchdog.fired(), welcomed, next) {
            (true, false, _) => format!(
                "the server did not answer in {} ms",
                waits.welcome.as_millis()
            ),
            (_, _, Next::Reconnect) => "reconnecting".into(),
            (_, _, Next::Stop) => "the connection ended".into(),
        };
        (next, line)
    };
    loop {
        // After a failed write, the commands wait for the next connection.
        while !ws.get_ref().write_failed() {
            let Ok(command) = commands.try_recv() else {
                break;
            };
            let frames = apply(&mut shared.lock().unwrap(), command);
            if send(&mut ws, &watchdog, waits, frames).is_err() {
                return ended(&mut ws, welcomed);
            }
        }
        // A binary frame at its first byte, or a write that failed: the tap
        // gave the bytes before it, which the reads take frame by frame, and
        // then fails the read with an I/O error, which ends the connection
        // below; a frame that the WebSocket refuses is a break.
        let text = match ws.read() {
            Ok(Message::Text(text)) => text,
            // After a binary frame, a close ends the connection as a break.
            Ok(Message::Close(_)) if ws.get_ref().binary() => return broken(shared, &mut ws),
            Ok(Message::Close(frame)) => {
                let next = close(shared, frame.map(|f| f.code.into()));
                let line = if next == Next::Reconnect {
                    "reconnecting"
                } else {
                    "the connection ended"
                };
                return (next, line.into());
            }
            // A reset with no close frame is a lost connection, not a break.
            Err(Error::Protocol(ProtocolError::ResetWithoutClosingHandshake)) => {
                return ended(&mut ws, welcomed);
            }
            // A binary message: the tap stops it at its first frame first.
            Ok(Message::Binary(_))
            | Err(Error::Capacity(_) | Error::Protocol(_) | Error::Utf8(_)) => {
                return broken(shared, &mut ws);
            }
            Ok(_) => {
                heard(&watchdog, welcomed, waits);
                continue;
            }
            Err(Error::Io(e))
                if matches!(e.kind(), ErrorKind::WouldBlock | ErrorKind::TimedOut) =>
            {
                // Sends the pong of a ping that a read took.
                let _ = ws.flush();
                continue;
            }
            Err(_) => return ended(&mut ws, welcomed),
        };
        heard(&watchdog, welcomed, waits);
        let mut guard = shared.lock().unwrap();
        let Ok(outputs) = guard.client.receive(text.as_str()) else {
            drop(guard);
            return broken(shared, &mut ws);
        };
        let mut frames = vec![];
        for output in outputs {
            match output {
                Output::Send(text) => frames.push(text),
                Output::Welcome => {
                    welcomed = true;
                    heard(&watchdog, welcomed, waits);
                    guard.line = "connected".into();
                    let live = guard.client.request("sessions.live", object([]));
                    frames.extend(record(
                        &mut guard,
                        "sessions.live",
                        "sessions.live".into(),
                        None,
                        live,
                    ));
                    if !guard.saved_asked {
                        guard.saved_asked = true;
                        frames.extend(saved(&mut guard, None));
                    }
                }
                Output::Refused(n) => {
                    drop(guard);
                    let _ = ws.close(None);
                    let next = close(shared, None);
                    return (
                        next,
                        format!("the server speaks protocol {n}: update the app"),
                    );
                }
                Output::Failed {
                    session, op, code, ..
                } => {
                    guard.line = format!("{op} of {session}: {code}");
                }
                Output::Reply { id, result } => {
                    let op = guard.answered(&id, &result);
                    match result {
                        Ok(Reply::SessionsLive(live)) => guard.live = live,
                        Ok(Reply::SessionsSaved { items, next }) => {
                            // The mode belongs to this request, not to the
                            // latest one: two pages can cross, and a refused
                            // request changes nothing.
                            let append = guard.saved_pages.remove(&id).unwrap_or(false);
                            guard.saved_pending = false;
                            let page = (items.into_iter())
                                .map(|mut item| {
                                    item.prompt = first_line(&item.prompt, MAX_PROMPT_BYTES);
                                    item
                                })
                                .collect::<Vec<_>>();
                            match append {
                                true => guard.saved.extend(page),
                                false => guard.saved = page,
                            }
                            guard.saved_next = next;
                        }
                        // A start or a resume: the window follows the session
                        // that the server made or attached.
                        Ok(Reply::Session(session)) => {
                            frames.extend(follow(&mut guard, &session));
                        }
                        _ => {}
                    }
                    if op == Some("sessions.saved") {
                        guard.saved_pages.remove(&id);
                        guard.saved_pending = false;
                    }
                }
                _ => {}
            }
        }
        drop(guard);
        notify();
        if send(&mut ws, &watchdog, waits, frames).is_err() {
            return ended(&mut ws, welcomed);
        }
    }
}

/// A message was read: after the welcome, the silence starts again. Before
/// it, the deadline of the welcome stands.
fn heard(watchdog: &Watchdog, welcomed: bool, waits: Waits) {
    if welcomed {
        watchdog.heard(waits.silence);
    }
}

/// The TCP connect within its wait, then the upgrade, under the watchdog
/// whose read deadline is the wait for `welcome`.
fn open(server: &Server, waits: Waits) -> Result<(Socket, Watchdog), String> {
    let address = SocketAddr::new(server.address, server.port);
    let stream = TcpStream::connect_timeout(&address, waits.connect).map_err(|e| e.to_string())?;
    stream
        .set_read_timeout(Some(waits.poll))
        .map_err(|e| e.to_string())?;
    stream
        .set_write_timeout(Some(waits.send))
        .map_err(|e| e.to_string())?;
    let watchdog =
        Watchdog::start(&stream, waits.welcome, waits.poll).map_err(|e| e.to_string())?;
    let config = WebSocketConfig::default()
        .max_message_size(Some(FRAME_BYTES))
        .max_frame_size(Some(FRAME_BYTES));
    // A read of the upgrade that times out is retried until the watchdog
    // shuts the socket down.
    let mut handshake =
        tungstenite::client::client_with_config(server.url(), Tap::new(stream), Some(config));
    loop {
        match handshake {
            Ok((ws, _)) => return Ok((ws, watchdog)),
            Err(tungstenite::HandshakeError::Interrupted(mid)) => handshake = mid.handshake(),
            Err(tungstenite::HandshakeError::Failure(e)) => {
                return Err(match watchdog.fired() {
                    true => format!("the upgrade took over {} ms", waits.welcome.as_millis()),
                    false => e.to_string(),
                });
            }
        }
    }
}

/// The line of the followed `session` while it waits for a place or its
/// session ended, from the state of its follow (`Client::follow`). A
/// refusal keeps the line of its `Output::Failed`, which names the error; a
/// wait for the connection or for the end of an old subscription keeps the
/// line of the connection.
pub fn follow_line(session: &str, follow: &Follow) -> Option<String> {
    let places = "waits for a free place of the 16 subscriptions";
    match follow {
        Follow::Waiting(Wait::Places { unwanted }) if unwanted.is_empty() => {
            Some(format!("{session} {places}"))
        }
        Follow::Waiting(Wait::Places { unwanted }) => Some(format!(
            "{session} {places}, held by {} that the window does not follow",
            unwanted.join(", ")
        )),
        Follow::Waiting(Wait::Requests) => Some(format!(
            "{session} waits for a free place of the 16 requests"
        )),
        Follow::Held(Hold::Ended) => Some(format!("{session} ended")),
        _ => None,
    }
}

/// Between connections: takes the commands of the window, whose frames go
/// at the next welcome, and gives whether the window is gone, its sender of
/// commands dropped.
fn window_gone(shared: &Mutex<Shared>, commands: &Receiver<Command>) -> bool {
    loop {
        match commands.try_recv() {
            // No connection takes a frame: the intent goes at the welcome,
            // and an operation is refused with `NotReady` on its line, so
            // nothing that the user asked for is sent without an answer to
            // this.
            Ok(command) => drop(apply(&mut shared.lock().unwrap(), command)),
            Err(TryRecvError::Empty) => return false,
            Err(TryRecvError::Disconnected) => return true,
        }
    }
}

/// One command of the window: its frames.
fn apply(shared: &mut Shared, command: Command) -> Vec<String> {
    match command {
        Command::Follow(session) => follow(shared, &session),
        Command::Operation { send, operation } => perform(shared, send, operation),
        Command::Saved { after } => saved(shared, after),
    }
}

/// Sends an operation of the window and records its line, and the outcome of
/// the send of the composer that it is.
fn perform(shared: &mut Shared, send: Option<SendId>, operation: Operation) -> Vec<String> {
    let op = operation.name();
    let label = label(&operation);
    let sent = shared.client.perform(operation);
    record(shared, op, label, send, sent)
}

/// The line of a request that the client sent or refused: its frames.
fn record(
    shared: &mut Shared,
    op: &'static str,
    label: String,
    send: Option<SendId>,
    sent: Result<(String, Vec<String>), Refusal>,
) -> Vec<String> {
    match sent {
        Ok((id, frames)) => {
            shared.sent(id, op, label, send);
            frames
        }
        Err(refusal) => {
            shared.refused(op, label, send, refusal_text(&refusal));
            vec![]
        }
    }
}

/// A page of the saved sessions: one at a time, so the replace and the append
/// of two pages cannot cross; the reply replaces the list, or appends at the
/// `next` of the page before.
fn saved(shared: &mut Shared, after: Option<String>) -> Vec<String> {
    if shared.saved_pending {
        shared.refused(
            "sessions.saved",
            "sessions.saved".into(),
            None,
            "a page of sessions is on the way".into(),
        );
        return vec![];
    }
    let append = after.is_some();
    let operation = Operation::saved(Saved {
        cwd: None,
        after,
        limit: Some(MAX_LIMIT),
    })
    .expect("no folder and a limit within its bound");
    let op = operation.name();
    let label = op.to_owned();
    match shared.client.perform(operation) {
        Ok((id, frames)) => {
            shared.sent(id.clone(), op, label, None);
            shared.saved_pages.insert(id, append);
            shared.saved_pending = true;
            frames
        }
        Err(refusal) => {
            shared.refused(op, label, None, refusal_text(&refusal));
            vec![]
        }
    }
}

fn follow(shared: &mut Shared, session: &str) -> Vec<String> {
    let mut frames = vec![];
    if let Some(old) = shared.followed.take().filter(|old| old.as_str() != session) {
        frames.extend(shared.client.unsubscribe(&old));
    }
    match shared.client.subscribe(session) {
        Ok(more) => frames.extend(more),
        Err(refusal) => shared.line = format!("could not follow {session}: {refusal:?}"),
    }
    shared.followed = Some(session.to_owned());
    frames
}

/// The line of an operation for a person: its op, and the head of a text.
fn label(operation: &Operation) -> String {
    match operation.text() {
        Some(text) => format!(
            "{} \"{}\"",
            operation.name(),
            first_line(text, MAX_LABEL_BYTES)
        ),
        None => operation.name().to_owned(),
    }
}

/// The first line of `text`, cut to `max` bytes.
fn first_line(text: &str, max: usize) -> String {
    let line = (text.split(['\n', '\r'])).next().unwrap_or("");
    head(line, max).0.to_owned()
}

/// The connection ended: the host's requests in flight are `Unknown`, and
/// the host gets what it does next. The client sends none of them again
/// (ADR 0006 §4).
fn close(shared: &Mutex<Shared>, code: Option<u16>) -> Next {
    let mut guard = shared.lock().unwrap();
    let closed = guard.client.closed(code);
    let lost: Vec<&str> = (closed.unknown.iter()).map(|(id, _)| id.as_str()).collect();
    guard.unknown(&lost);
    closed.next
}

/// Sends `frames` within the send wait in all. The read deadline does not
/// move: the silence counts from the last message read, however many frames
/// go. A write that the tap keeps is no error here: the connection ends at
/// the next read, after the frames that `tungstenite` read before it, and
/// no frame goes after it.
fn send(
    ws: &mut Socket,
    watchdog: &Watchdog,
    waits: Waits,
    frames: Vec<String>,
) -> Result<(), Error> {
    if frames.is_empty() || ws.get_ref().write_failed() {
        return Ok(());
    }
    watchdog.sending(waits.send);
    let sent = frames
        .into_iter()
        .try_for_each(|frame| ws.send(Message::text(frame)));
    watchdog.sent();
    match sent {
        Err(Error::Io(e)) if e.kind() == ErrorKind::WouldBlock && ws.get_ref().write_failed() => {
            Ok(())
        }
        sent => sent,
    }
}

fn broken(shared: &Mutex<Shared>, ws: &mut Socket) -> (Next, String) {
    let _ = ws.close(None);
    let _ = ws.flush();
    // A break that the socket found (a binary frame, a frame over the
    // bound, a text that is not UTF-8) is not one that the core saw: it
    // stops all the same.
    close(shared, None);
    (Next::Stop, "the server broke the wire contract".into())
}

#[cfg(test)]
mod tests {
    use super::{
        MAX_LABEL_BYTES, MAX_PROMPT_BYTES, RequestState, Shared, first_line, label, perform,
        refusal_text,
    };
    use crate::composer::SendOutcome;
    use helyx_client_core::client::Refusal;
    use helyx_client_core::operation::Operation;

    fn line(shared: &Shared, at: usize) -> &super::RequestLine {
        &shared.requests[at]
    }

    #[test]
    fn a_refused_send_is_a_line_and_keeps_its_text() {
        // No connection: `Client::perform` refuses with `NotReady`.
        let mut shared = Shared::new("t".into());
        let frames = perform(
            &mut shared,
            Some(7),
            Operation::prompt("s1", "hello").unwrap(),
        );
        assert!(frames.is_empty());
        assert_eq!(
            line(&shared, 0).state,
            RequestState::Error {
                code: "not sent".into(),
                text: "the connection is not ready".into(),
            }
        );
        assert_eq!(
            shared.outcomes,
            [(7, SendOutcome::Failed("the connection is not ready".into()))]
        );
        assert_eq!(
            line(&shared, 0).text(),
            "prompt \"hello\" · not sent: the connection is not ready"
        );
        assert_eq!(
            refusal_text(&Refusal::TooLarge),
            "the request is over its size"
        );
    }

    #[test]
    fn the_request_lines_keep_twelve_and_never_drop_a_pending_one() {
        let mut shared = Shared::new("t".into());
        // Thirteen answered lines: the oldest leaves.
        for n in 0..13 {
            let id = n.to_string();
            shared.sent(id.clone(), "abort", "abort".into(), None);
            shared.answered(&id, &Ok(helyx_client_core::frame::Reply::Empty));
        }
        assert_eq!(shared.requests.len(), 12);
        assert_eq!(line(&shared, 0).id, "1");
        assert_eq!(line(&shared, 11).id, "12");
        // A pending line is kept past the bound, so a request in flight is
        // never dropped from the list.
        shared.sent("p".into(), "abort", "abort".into(), None);
        for n in 13..20 {
            let id = n.to_string();
            shared.sent(id.clone(), "abort", "abort".into(), None);
            shared.answered(&id, &Ok(helyx_client_core::frame::Reply::Empty));
        }
        assert_eq!(shared.requests.len(), 12);
        assert!(
            shared
                .requests
                .iter()
                .any(|line| line.id == "p" && line.state == RequestState::Pending)
        );
    }

    #[test]
    fn a_label_takes_the_first_line_and_forty_bytes() {
        let short = Operation::prompt("s1", "one\ntwo").unwrap();
        assert_eq!(label(&short), "prompt \"one\"");
        // 39 `a` and a two-byte character: the cut lands before the
        // character, at a boundary.
        let long = Operation::prompt("s1", &format!("{}éand more", "a".repeat(39))).unwrap();
        let line = label(&long);
        assert_eq!(line, format!("prompt \"{}\"", "a".repeat(39)));
        assert_eq!(first_line(&"a".repeat(100), MAX_LABEL_BYTES).len(), 40);
    }

    #[test]
    fn a_saved_prompt_is_cut_at_two_hundred_bytes() {
        let at = "a".repeat(65_536);
        assert_eq!(first_line(&at, MAX_PROMPT_BYTES), "a".repeat(200));
        // The first line only, and a cut at a character boundary.
        let lines = format!("one\n{}", "b".repeat(300));
        assert_eq!(first_line(&lines, MAX_PROMPT_BYTES), "one");
        let multibyte = format!("{}émore", "a".repeat(199));
        let cut = first_line(&multibyte, MAX_PROMPT_BYTES);
        assert_eq!(cut, "a".repeat(199));
        assert!(cut.is_char_boundary(cut.len()));
    }

    #[test]
    fn the_outcome_of_each_send() {
        use helyx_client_core::frame::Reply;
        let mut shared = Shared::new("t".into());
        // The client took it: pending.
        shared.sent("0".into(), "answer", "answer".into(), Some(4));
        assert_eq!(shared.outcomes, [(4, SendOutcome::Pending)]);
        // An `ok` reply.
        shared.answered("0", &Ok(Reply::Empty));
        assert_eq!(&shared.outcomes[1..], [(4, SendOutcome::Ok)]);
        // An error reply, with the reason that the line shows.
        shared.sent("1".into(), "answer", "answer".into(), Some(5));
        shared.answered("1", &Err(("busy".into(), "x".into())));
        assert_eq!(
            &shared.outcomes[3..],
            [(5, SendOutcome::Failed("busy: x".into()))]
        );
        // A reply lost with the connection.
        shared.sent("2".into(), "answer", "answer".into(), Some(6));
        shared.unknown(&["2"]);
        assert_eq!(
            &shared.outcomes[5..],
            [(6, SendOutcome::Failed("the reply was lost".into()))]
        );
        // A refusal before the request goes.
        let frames = perform(
            &mut shared,
            Some(7),
            Operation::answer(
                "s1",
                "a1",
                helyx_client_core::json::decode(r#"{"decision":"allow"}"#).unwrap(),
            )
            .unwrap(),
        );
        assert!(frames.is_empty());
        assert_eq!(
            shared.outcomes.last(),
            Some(&(7, SendOutcome::Failed("the connection is not ready".into())))
        );
    }

    #[test]
    fn the_outcomes_are_bounded() {
        let mut shared = Shared::new("t".into());
        for n in 0..(super::MAX_OUTCOMES as u64 + 10) {
            shared.sent(n.to_string(), "answer", "answer".into(), Some(n));
        }
        assert_eq!(shared.outcomes.len(), super::MAX_OUTCOMES);
        assert_eq!(shared.outcomes[0].0, 10);
        assert_eq!(
            shared.outcomes.last().unwrap().0,
            super::MAX_OUTCOMES as u64 + 9
        );
    }
}
