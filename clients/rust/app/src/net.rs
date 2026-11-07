//! The network thread of the app: one WebSocket to the server at a time,
//! driven by `helyx_client_core::client::Client`. The window reads `Shared`
//! and sends `Command`s; the thread calls `notify` after each change.
//!
//! Every wait of a connection after its TCP connect is a deadline of its
//! socket, which a watchdog thread holds (`socket::Watchdog`).

use crate::settings::Server;
use crate::socket::{Tap, WAITS, Waits, Watchdog};
use helyx_client_core::client::{Client, Next, Output};
use helyx_client_core::frame::{LiveSession, Reply};
use helyx_client_core::json::object;
use helyx_client_core::parts::FRAME_BYTES;
use std::io::ErrorKind;
use std::net::{SocketAddr, TcpStream};
use std::sync::Mutex;
use std::sync::mpsc::Receiver;
use tungstenite::error::ProtocolError;
use tungstenite::protocol::WebSocketConfig;
use tungstenite::{Error, Message, WebSocket};

/// What the window asks.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Command {
    /// Follow this session, and stop following the one before.
    Follow(String),
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
}

impl Shared {
    pub fn new(token: String) -> Shared {
        Shared {
            client: Client::new(Some(token)),
            live: vec![],
            followed: None,
            line: "connecting".into(),
        }
    }
}

/// Runs connections until one ends with `Next::Stop`, and gives its line.
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
        if next == Next::Stop {
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
            let next = shared.lock().unwrap().client.closed(None);
            let line = format!("could not connect to {}: {text}", server.url());
            return (next, line);
        }
    };
    shared.lock().unwrap().client.connect();
    let mut welcomed = false;
    let lost = |welcomed: bool| {
        let next = shared.lock().unwrap().client.closed(None);
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
        for command in commands.try_iter() {
            let frames = follow(&mut shared.lock().unwrap(), command);
            if send(&mut ws, &watchdog, waits, frames).is_err() {
                return lost(welcomed);
            }
        }
        let text = match ws.read() {
            // A binary frame, at its first byte: the tap gave the frames
            // before it, which the reads take one by one, and then fails the
            // read.
            Err(_) if ws.get_ref().binary() => return broken(shared, &mut ws),
            Ok(Message::Text(text)) => text,
            Ok(Message::Close(frame)) => {
                let next = shared
                    .lock()
                    .unwrap()
                    .client
                    .closed(frame.map(|f| f.code.into()));
                let line = if next == Next::Reconnect {
                    "reconnecting"
                } else {
                    "the connection ended"
                };
                return (next, line.into());
            }
            // A reset with no close frame is a lost connection, not a break.
            Err(Error::Protocol(ProtocolError::ResetWithoutClosingHandshake)) => {
                return lost(welcomed);
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
            Err(_) => return lost(welcomed),
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
                    if let Ok((_, live)) = guard.client.request("sessions.live", object([])) {
                        frames.extend(live);
                    }
                }
                Output::Refused(n) => {
                    drop(guard);
                    let _ = ws.close(None);
                    let next = shared.lock().unwrap().client.closed(None);
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
                Output::Reply {
                    result: Ok(Reply::SessionsLive(live)),
                    ..
                } => guard.live = live,
                _ => {}
            }
        }
        drop(guard);
        notify();
        if send(&mut ws, &watchdog, waits, frames).is_err() {
            return lost(welcomed);
        }
    }
}

/// A frame was read: after the welcome, the silence starts again. Before
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

fn follow(shared: &mut Shared, Command::Follow(session): Command) -> Vec<String> {
    let mut frames = vec![];
    if let Some(old) = shared.followed.take().filter(|old| *old != session) {
        frames.extend(shared.client.unsubscribe(&old));
    }
    match shared.client.subscribe(&session) {
        Ok(more) => frames.extend(more),
        Err(refusal) => shared.line = format!("could not follow {session}: {refusal:?}"),
    }
    shared.followed = Some(session);
    frames
}

/// Sends `frames` within the send wait in all. The read deadline does not
/// move: the silence counts from the last frame read, however many frames
/// go.
fn send(
    ws: &mut Socket,
    watchdog: &Watchdog,
    waits: Waits,
    frames: Vec<String>,
) -> Result<(), Error> {
    if frames.is_empty() {
        return Ok(());
    }
    watchdog.sending(waits.send);
    for frame in frames {
        ws.send(Message::text(frame))?;
    }
    watchdog.sent();
    Ok(())
}

fn broken(shared: &Mutex<Shared>, ws: &mut Socket) -> (Next, String) {
    let _ = ws.close(None);
    let _ = ws.flush();
    // A break that the socket found (a binary frame, a frame over the
    // bound, a text that is not UTF-8) is not one that the core saw: it
    // stops all the same.
    shared.lock().unwrap().client.closed(None);
    (Next::Stop, "the server broke the wire contract".into())
}
