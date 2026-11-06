//! The network thread of the app: one WebSocket to the server at a time,
//! driven by `helyx_client_core::client::Client`. The window reads `Shared`
//! and sends `Command`s; the thread calls `notify` after each change.
//!
//! Every wait of a connection is one deadline of its socket, which a
//! watchdog thread holds: it shuts the socket down when the deadline passes,
//! whatever read or write is in progress (`Watchdog`).

use crate::settings::Server;
use helyx_client_core::client::{Client, Next, Output};
use helyx_client_core::frame::{LiveSession, Reply};
use helyx_client_core::json::object;
use helyx_client_core::parts::FRAME_BYTES;
use std::io::ErrorKind;
use std::net::{Shutdown, SocketAddr, TcpStream};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::mpsc::Receiver;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use tungstenite::error::ProtocolError;
use tungstenite::protocol::WebSocketConfig;
use tungstenite::{Error, Message, WebSocket};

/// The TCP connect; then the upgrade and the wait for `welcome` in all, the
/// auth wait of the server (`docs/features/wire-protocol.md`, "Bounds"); and
/// each batch of frames that the thread sends.
pub const WAIT: Duration = Duration::from_millis(5_000);
/// The read timeout of the socket: how often the thread takes the commands
/// of the window while the server sends nothing.
pub const POLL: Duration = Duration::from_millis(100);
/// A server that is gone: the server pings every 15,000 ms, so 45,000 ms with
/// no inbound frame ends the connection as lost, as the server ends a client.
pub const SILENCE: Duration = Duration::from_millis(45_000);
/// The pause before each reconnect, so a server that welcomes and closes at
/// once gets at most one connection a second.
pub const PAUSE: Duration = Duration::from_millis(1_000);

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

/// The deadline of one socket. A thread checks it every `POLL` and shuts the
/// socket down once it has passed; it ends with the `Watchdog`, or at the
/// shutdown.
struct Watchdog {
    start: Instant,
    /// Milliseconds from `start`.
    deadline: Arc<AtomicU64>,
    fired: Arc<AtomicBool>,
    done: Arc<AtomicBool>,
}

impl Watchdog {
    fn start(stream: &TcpStream, wait: Duration) -> std::io::Result<Watchdog> {
        let watched = stream.try_clone()?;
        let start = Instant::now();
        let deadline = Arc::new(AtomicU64::new(wait.as_millis() as u64));
        let fired = Arc::new(AtomicBool::new(false));
        let done = Arc::new(AtomicBool::new(false));
        let (d, f, e) = (deadline.clone(), fired.clone(), done.clone());
        std::thread::spawn(move || {
            while !e.load(Ordering::SeqCst) {
                if start.elapsed().as_millis() as u64 > d.load(Ordering::SeqCst) {
                    f.store(true, Ordering::SeqCst);
                    let _ = watched.shutdown(Shutdown::Both);
                    return;
                }
                std::thread::sleep(POLL);
            }
        });
        Ok(Watchdog {
            start,
            deadline,
            fired,
            done,
        })
    }

    /// The deadline is `wait` from now.
    fn set(&self, wait: Duration) {
        let at = (self.start.elapsed() + wait).as_millis() as u64;
        self.deadline.store(at, Ordering::SeqCst);
    }

    fn fired(&self) -> bool {
        self.fired.load(Ordering::SeqCst)
    }
}

impl Drop for Watchdog {
    fn drop(&mut self) {
        self.done.store(true, Ordering::SeqCst);
    }
}

/// Runs connections until one ends with `Next::Stop`, and gives its line.
pub fn run(
    server: &Server,
    shared: &Mutex<Shared>,
    commands: &Receiver<Command>,
    notify: &dyn Fn(),
) -> String {
    loop {
        let (next, line) = connection(server, shared, commands, notify);
        shared.lock().unwrap().line = line.clone();
        notify();
        if next == Next::Stop {
            return line;
        }
        std::thread::sleep(PAUSE);
    }
}

type Socket = WebSocket<TcpStream>;

fn connection(
    server: &Server,
    shared: &Mutex<Shared>,
    commands: &Receiver<Command>,
    notify: &dyn Fn(),
) -> (Next, String) {
    let (mut ws, watchdog) = match open(server) {
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
            (true, false, _) => format!("the server did not answer in {} ms", WAIT.as_millis()),
            (_, _, Next::Reconnect) => "reconnecting".into(),
            (_, _, Next::Stop) => "the connection ended".into(),
        };
        (next, line)
    };
    loop {
        for command in commands.try_iter() {
            let frames = follow(&mut shared.lock().unwrap(), command);
            if send(&mut ws, &watchdog, welcomed, frames).is_err() {
                return lost(welcomed);
            }
        }
        let text = match ws.read() {
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
            Ok(Message::Binary(_))
            | Err(Error::Capacity(_) | Error::Protocol(_) | Error::Utf8(_)) => {
                return broken(shared, &mut ws);
            }
            Ok(_) => {
                heard(&watchdog, welcomed);
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
        heard(&watchdog, welcomed);
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
                    heard(&watchdog, welcomed);
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
                Output::Reply {
                    result: Ok(Reply::SessionsLive(live)),
                    ..
                } => guard.live = live,
                _ => {}
            }
        }
        drop(guard);
        notify();
        if send(&mut ws, &watchdog, welcomed, frames).is_err() {
            return lost(welcomed);
        }
    }
}

/// An inbound frame: after the welcome, the silence starts again. Before
/// it, the deadline of the welcome stands.
fn heard(watchdog: &Watchdog, welcomed: bool) {
    if welcomed {
        watchdog.set(SILENCE);
    }
}

/// The TCP connect within `WAIT`, then the upgrade, under the watchdog that
/// also holds the wait for `welcome`.
fn open(server: &Server) -> Result<(Socket, Watchdog), String> {
    let address = SocketAddr::new(server.address, server.port);
    let stream = TcpStream::connect_timeout(&address, WAIT).map_err(|e| e.to_string())?;
    stream
        .set_read_timeout(Some(POLL))
        .map_err(|e| e.to_string())?;
    stream
        .set_write_timeout(Some(WAIT))
        .map_err(|e| e.to_string())?;
    let watchdog = Watchdog::start(&stream, WAIT).map_err(|e| e.to_string())?;
    let config = WebSocketConfig::default()
        .max_message_size(Some(FRAME_BYTES))
        .max_frame_size(Some(FRAME_BYTES));
    // A read of the upgrade that times out is retried until the watchdog
    // shuts the socket down.
    let mut handshake = tungstenite::client::client_with_config(server.url(), stream, Some(config));
    loop {
        match handshake {
            Ok((ws, _)) => return Ok((ws, watchdog)),
            Err(tungstenite::HandshakeError::Interrupted(mid)) => handshake = mid.handshake(),
            Err(tungstenite::HandshakeError::Failure(e)) => {
                return Err(match watchdog.fired() {
                    true => format!("the upgrade took over {} ms", WAIT.as_millis()),
                    false => e.to_string(),
                });
            }
        }
    }
}

fn follow(shared: &mut Shared, Command::Follow(session): Command) -> Vec<String> {
    let mut frames = vec![];
    if let Some(old) = shared.followed.take().filter(|old| *old != session) {
        frames.extend(shared.client.unsubscribe(&old).unwrap_or_default());
    }
    frames.extend(shared.client.subscribe(&session).unwrap_or_default());
    shared.followed = Some(session);
    frames
}

/// Sends `frames` within `WAIT` in all, then gives back the deadline of
/// reading: the silence from the last inbound frame after the welcome, the
/// wait for it before.
fn send(
    ws: &mut Socket,
    watchdog: &Watchdog,
    welcomed: bool,
    frames: Vec<String>,
) -> Result<(), Error> {
    if frames.is_empty() {
        return Ok(());
    }
    let before = watchdog.deadline.load(Ordering::SeqCst);
    // Before the welcome, the sends stay inside the wait for it.
    if welcomed {
        watchdog.set(WAIT);
    }
    for frame in frames {
        ws.send(Message::text(frame))?;
    }
    watchdog.deadline.store(before, Ordering::SeqCst);
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
