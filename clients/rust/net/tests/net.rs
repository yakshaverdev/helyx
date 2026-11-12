//! The network thread against a stub server on the loopback: the handshake
//! with the proof of the token, the records feed and the live list of a
//! server with no Hub, a follow, the `4408` slow close, the reconnect with
//! `after`, the waits before the welcome, and the breaks of the wire contract.

use net::stub;

use helyx_client_core::json::{Json, decode};
use helyx_client_core::records::Status;
use helyx_client_net as net;
use net::Server;
use net::socket::{WAITS, Waits};
use net::{Command, RequestState, Shared};
use std::net::{TcpListener, TcpStream};
use std::sync::mpsc::{Receiver, channel};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use stub::{LIVE, challenge, next_text, welcome};
use tungstenite::protocol::CloseFrame;
use tungstenite::protocol::frame::coding::CloseCode;
use tungstenite::{Message, WebSocket, accept};

/// The next request of the client, as its frame; a response is skipped.
fn next_request(ws: &mut WebSocket<TcpStream>) -> Json {
    loop {
        let text = next_text(ws);
        let value = decode(&text).unwrap();
        if value.get("type").and_then(Json::as_str) == Some("req") {
            return value;
        }
    }
}

/// The next request of `op`, with any other request before it read and left
/// unanswered; a test names the replies that it gives.
fn request(ws: &mut WebSocket<TcpStream>, op: &str) -> Json {
    loop {
        let value = next_request(ws);
        if value.get("op").and_then(Json::as_str) == Some(op) {
            return value;
        }
    }
}

/// The `id` of a request or a reply.
fn id_of(frame: &Json) -> &str {
    frame.get("id").and_then(Json::as_str).unwrap()
}

fn snapshot(seq: u64) -> String {
    format!(
        r#"{{"older":0,"instance_id":"i1","seq":{seq},"messages":[{{"id":"u1","role":"user","content":[{{"type":"text","text":"hi"}}]}}],"turn":null,"model":"fake/echo","persisting":true,"context":null,"asks":[],"ui_blocks":[],"activated":[],"queue":{{"steers":0,"follow_ups":0,"running":0,"held":0,"waiting":0}},"usage":{{"input":0,"output":0,"cache_read":0,"cache_write":0,"cost":null,"unknown":false,"list":false}}}}"#
    )
}

#[test]
fn a_follow_survives_a_slow_close() {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let port = listener.local_addr().unwrap().port();
    let token = "secret-token";
    let server = Server {
        token: token.into(),
        ..stub::local(port)
    };
    let shared = Arc::new(Mutex::new(Shared::new()));
    let (commands, receive) = channel();
    let (changed, changes) = channel();
    let thread_shared = shared.clone();
    let thread = std::thread::spawn(move || {
        net::run(&stub::fixed(&server), &thread_shared, &receive, &|| {
            let _ = changed.send(());
        })
    });

    // The first connection: the records subscription refused, the live list
    // and the saved list, a follow, an event, then 4408.
    let mut ws = accept(listener.accept().unwrap().0).unwrap();
    welcome(&mut ws, token);
    let records = request(&mut ws, "records.subscribe");
    assert_eq!(id_of(&records), "0");
    error(&mut ws, id_of(&records), "unknown_op");
    let live = request(&mut ws, "sessions.live");
    ws.send(Message::text(
        LIVE.replace(r#""id":"0""#, &format!(r#""id":"{}""#, id_of(&live))),
    ))
    .unwrap();
    while shared.lock().unwrap().live.is_empty() {
        changes.recv().unwrap();
    }
    commands.send(Command::Follow("s1".into())).unwrap();
    let subscribe = request(&mut ws, "subscribe");
    assert_eq!(
        subscribe.get("params"),
        Some(&decode(r#"{"session":"s1","answers":true}"#).unwrap())
    );
    ws.send(Message::text(format!(
        r#"{{"type":"res","id":"{}","ok":true,"result":{{"sub":"0","snapshot":{}}}}}"#,
        id_of(&subscribe),
        snapshot(4)
    )))
    .unwrap();
    ws.send(Message::text(
        r#"{"type":"event","sub":"0","event":{"type":"notice","session_id":"s1","instance_id":"i1","turn_id":null,"seq":5,"data":{"text":"n"}}}"#,
    ))
    .unwrap();
    let close = CloseFrame {
        code: CloseCode::from(4408),
        reason: "slow".into(),
    };
    ws.close(Some(close)).unwrap();
    let _ = ws.flush();

    // The second connection: the records subscription refused again, the
    // subscribe with `after` of the state, and the live list.
    let mut ws = accept(listener.accept().unwrap().0).unwrap();
    welcome(&mut ws, token);
    let records = request(&mut ws, "records.subscribe");
    let subscribe = next_text(&mut ws);
    let after = r#""params":{"session":"s1","after":{"instance_id":"i1","seq":5},"answers":true}"#;
    assert!(subscribe.contains(after), "{subscribe}");
    error(&mut ws, id_of(&records), "unknown_op");
    let live = next_text(&mut ws);
    assert!(live.contains(r#""op":"sessions.live""#), "{live}");
    // The window is gone: the thread ends at the end of the connection.
    drop(commands);
    drop(ws);
    drop(listener);
    let line = thread.join().unwrap();
    assert_eq!(line, "reconnecting");
    let shared = shared.lock().unwrap();
    let state = shared.client.state("s1").unwrap();
    assert_eq!((state.seq.to_u64(), state.notices.len()), (Some(5), 1));
}

/// Runs the network thread against one stub connection, `serve`, and gives
/// the line that the thread ends with and its state. The window is gone, so
/// the thread ends at the end of the connection.
fn against_state(serve: impl FnOnce(WebSocket<TcpStream>) + Send + 'static) -> (String, Shared) {
    let (server, stub) = stub::one(serve);
    let shared = Mutex::new(Shared::new());
    let receive = channel::<Command>().1;
    let line = net::run(&stub::fixed(&server), &shared, &receive, &|| {});
    stub.join().unwrap();
    (line, shared.into_inner().unwrap())
}

fn against(serve: impl FnOnce(WebSocket<TcpStream>) + Send + 'static) -> String {
    against_state(serve).0
}

#[test]
fn pings_do_not_hold_the_welcome_wait_open() {
    let started = Instant::now();
    let line = against(|mut ws| {
        challenge(&mut ws);
        let until = Instant::now() + WAITS.welcome + Duration::from_secs(3);
        while Instant::now() < until {
            if ws.send(Message::Ping(vec![].into())).is_err() {
                return;
            }
            std::thread::sleep(Duration::from_millis(50));
        }
    });
    assert_eq!(line, "the server did not answer in 5000 ms");
    // Ends at the wait, not when the stub stops at 8 s; the margin is for load.
    assert!(started.elapsed() >= WAITS.welcome);
}

#[test]
fn refused_keeps_its_line() {
    let line = against(|mut ws| {
        challenge(&mut ws);
        next_text(&mut ws);
        ws.send(Message::text(
            r#"{"type":"refused","code":"protocol","server_protocol":14}"#,
        ))
        .unwrap();
        let _ = ws.read();
    });
    assert_eq!(line, "the server speaks protocol 14: update the app");
}

#[test]
fn a_frame_over_the_bound_is_a_break() {
    let line = against(|mut ws| {
        welcome(&mut ws, "tok-q4");
        let big = format!("\"{}\"", "a".repeat(helyx_client_core::parts::FRAME_BYTES));
        let _ = ws.send(Message::text(big));
        let _ = ws.read();
    });
    assert_eq!(line, "the server broke the wire contract");
}

#[test]
fn no_debug_form_holds_the_token() {
    let shared = Shared::new();
    assert!(!format!("{shared:?}").contains("tok-5b1e"));
    let server = Server {
        token: "tok-5b1e".into(),
        ..stub::local(1)
    };
    assert!(!format!("{server:?}").contains("tok-5b1e"));
}

/// A stub that answers the upgrade one byte each 400 ms: the upgrade ends
/// at its wait, not when the stub stops.
#[test]
fn a_slow_upgrade_ends_at_its_wait() {
    use std::io::{Read, Write};
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let port = listener.local_addr().unwrap().port();
    let stub = std::thread::spawn(move || {
        let (mut stream, _) = listener.accept().unwrap();
        let mut request = [0u8; 1024];
        let _ = stream.read(&mut request);
        for byte in b"HTTP/1.1 101 Switching Protocols\r\nX-Slow: aaaaaaaaaaaaaaaaaaaaaaaa" {
            if stream.write_all(&[*byte]).is_err() {
                return;
            }
            std::thread::sleep(Duration::from_millis(400));
        }
    });
    let shared = Mutex::new(Shared::new());
    let (_commands, receive) = channel();
    let line = net::run(&stub::fixed(&stub::local(port)), &shared, &receive, &|| {});
    assert!(line.ends_with("the upgrade took over 5000 ms"), "{line}");
    stub.join().unwrap();
}

/// A text frame that comes one byte each 50 ms before `welcome`: the wait
/// for `welcome` ends it.
#[test]
fn a_slow_frame_does_not_hold_the_welcome_wait_open() {
    let line = against(|mut ws| {
        challenge(&mut ws);
        let _hello = next_text(&mut ws);
        let stream = ws.get_mut();
        use std::io::Write;
        if stream.write_all(&[0x81, 0x7e, 0x03, 0xe8]).is_err() {
            return;
        }
        for _ in 0..200 {
            if stream.write_all(b"a").is_err() {
                return;
            }
            std::thread::sleep(Duration::from_millis(50));
        }
    });
    assert_eq!(line, "the server did not answer in 5000 ms");
}

#[test]
fn a_text_that_is_not_utf8_is_a_break() {
    let line = against(|mut ws| {
        welcome(&mut ws, "tok-q4");
        use std::io::Write;
        let _ = ws.get_mut().write_all(&[0x81, 0x02, 0xff, 0xfe]);
        let _ = ws.read();
    });
    assert_eq!(line, "the server broke the wire contract");
}

/// A binary frame that is not final, then pings and a close: a binary frame
/// is a break at its first frame.
#[test]
fn an_unfinished_binary_frame_is_a_break() {
    let line = against(|mut ws| {
        welcome(&mut ws, "tok-q4");
        use std::io::Write;
        let stream = ws.get_mut();
        let _ = stream.write_all(&[0x02, 0x01, b'x']);
        for _ in 0..5 {
            let _ = stream.write_all(&[0x89, 0x00]);
            std::thread::sleep(Duration::from_millis(50));
        }
        let _ = stream.write_all(&[0x88, 0x02, 0x03, 0xe8]);
        let _ = ws.read();
    });
    assert_eq!(line, "the server broke the wire contract");
}

/// A binary frame that is not final, then continuation frames with no ping:
/// the read returns at the binary frame, and the app stops at once.
#[test]
fn continuations_of_a_binary_frame_do_not_hold_the_read() {
    let line = against(|mut ws| {
        welcome(&mut ws, "tok-q4");
        use std::io::Write;
        let stream = ws.get_mut();
        let _ = stream.write_all(&[0x02, 0x01, b'x']);
        for _ in 0..40 {
            if stream.write_all(&[0x00, 0x00]).is_err() {
                return;
            }
            std::thread::sleep(Duration::from_millis(50));
        }
    });
    assert_eq!(line, "the server broke the wire contract");
}

/// A text frame and a binary frame in one write, and a ping, a text frame,
/// and a binary frame: every frame before the binary frame is taken, then
/// the app stops.
#[test]
fn every_frame_before_a_binary_frame_is_taken() {
    for ping in [vec![], vec![0x89, 0x00]] {
        let (line, shared) = against_state(move |mut ws| {
            welcome(&mut ws, "tok-q4");
            // The records subscription of the welcome, refused: the live
            // list of a server with no Hub follows.
            let records = decode(&next_text(&mut ws)).unwrap();
            let refused = format!(
                r#"{{"type":"res","id":"{}","ok":false,"error":{{"code":"unknown_op","text":"x"}}}}"#,
                id_of(&records)
            );
            // The live request takes id 2: the records subscription is 0 and
            // the saved list is 1.
            let live = LIVE.replace(r#""id":"0""#, r#""id":"2""#);
            let mut bytes = ping;
            bytes.extend([0x81, 126, (refused.len() >> 8) as u8, refused.len() as u8]);
            bytes.extend(refused.as_bytes());
            bytes.extend([0x81, 126, (live.len() >> 8) as u8, live.len() as u8]);
            bytes.extend(live.as_bytes());
            bytes.extend([0x02, 0x01, b'x']);
            use std::io::Write;
            let _ = ws.get_mut().write_all(&bytes);
            let _ = ws.read();
        });
        assert_eq!(line, "the server broke the wire contract");
        assert_eq!(shared.live.len(), 1);
    }
}

/// After a binary frame, a close that came before it in the same read
/// ends the connection as the break that the mark is.
#[test]
fn a_close_with_a_binary_frame_is_a_break() {
    let line = against(|mut ws| {
        welcome(&mut ws, "tok-q4");
        let _live = next_text(&mut ws);
        let bytes = [0x88, 0x02, 0x03, 0xe8, 0x02, 0x01, b'x'];
        use std::io::Write;
        let _ = ws.get_mut().write_all(&bytes);
        let _ = ws.read();
    });
    assert_eq!(line, "the server broke the wire contract");
}

/// The line of a followed session that waits or is held says why.
#[test]
fn the_line_of_a_follow_says_why_it_waits() {
    use helyx_client_core::client::{Follow, Hold, Wait};
    let places = Follow::Waiting(Wait::Places {
        unwanted: vec!["s05".into()],
    });
    let line = net::follow_line("a", &places).unwrap();
    assert!(
        line.contains("16 subscriptions") && line.contains("s05"),
        "{line}"
    );
    let none = Follow::Waiting(Wait::Places { unwanted: vec![] });
    assert_eq!(
        net::follow_line("a", &none).as_deref(),
        Some("a waits for a free place of the 16 subscriptions")
    );
    assert_eq!(
        net::follow_line("a", &Follow::Held(Hold::Ended)).as_deref(),
        Some("a ended")
    );
    let requests = Follow::Waiting(Wait::Requests);
    assert!(
        net::follow_line("a", &requests)
            .unwrap()
            .contains("16 requests")
    );
    // These keep the line of the connection, or of `Output::Failed`.
    for quiet in [
        Follow::Live,
        Follow::Subscribing,
        Follow::Unwanted,
        Follow::Held(Hold::Refused),
        Follow::Waiting(Wait::Connection),
        Follow::Waiting(Wait::Ending),
    ] {
        assert_eq!(net::follow_line("a", &quiet), None);
    }
}

/// After a welcome, a failed open reconnects: a connection ends, the next two
/// connects are refused, and the third subscribes again with `after` of the
/// state. Before any welcome, a failed open stops (`net::run` of the upgrade
/// test above), as the first connect of the TUI does.
#[test]
fn a_failed_open_after_a_welcome_reconnects() {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let port = listener.local_addr().unwrap().port();
    let server = stub::local(port);
    let shared = Arc::new(Mutex::new(Shared::new()));
    let (commands, receive) = channel();
    let (lines, notified) = channel();
    let waits = net::socket::Waits {
        pause: Duration::from_millis(50),
        ..WAITS
    };
    let thread_shared = shared.clone();
    let thread = std::thread::spawn(move || {
        let read = thread_shared.clone();
        let notify = move || {
            let _ = lines.send(read.lock().unwrap().line.clone());
        };
        net::run_with(
            &stub::fixed(&server),
            &thread_shared,
            &receive,
            &notify,
            waits,
        )
    });

    // The first connection: a follow and its snapshot, then a lost end.
    let mut ws = accept(listener.accept().unwrap().0).unwrap();
    let (saved, live) = no_hub(&mut ws, "tok-q4");
    ok(&mut ws, id_of(&live), r#"{"sessions":[]}"#);
    ok(&mut ws, id_of(&saved), r#"{"items":[],"next":null}"#);
    commands.send(Command::Follow("s1".into())).unwrap();
    let subscribe = request(&mut ws, "subscribe");
    ws.send(Message::text(format!(
        r#"{{"type":"res","id":"{}","ok":true,"result":{{"sub":"0","snapshot":{}}}}}"#,
        id_of(&subscribe),
        snapshot(4)
    )))
    .unwrap();
    let seq = |shared: &Mutex<Shared>| {
        let shared = shared.lock().unwrap();
        shared.client.state("s1").and_then(|s| s.seq.to_u64())
    };
    while seq(&shared) != Some(4) {
        notified.recv().unwrap();
    }
    drop(ws);
    drop(listener);

    // Two connects refused, with no listener on the port.
    let mut refused = 0;
    while refused < 2 {
        let line = notified.recv().unwrap();
        refused += usize::from(line.starts_with("could not connect"));
    }

    // A listener on the port again: the subscribe goes with `after`.
    let listener = TcpListener::bind(("127.0.0.1", port)).unwrap();
    let mut ws = accept(listener.accept().unwrap().0).unwrap();
    welcome(&mut ws, "tok-q4");
    let records = request(&mut ws, "records.subscribe");
    error(&mut ws, id_of(&records), "unknown_op");
    let subscribe = next_text(&mut ws);
    let after = r#""params":{"session":"s1","after":{"instance_id":"i1","seq":4},"answers":true}"#;
    assert!(subscribe.contains(after), "{subscribe}");

    // The window is gone: the thread ends at the end of the connection.
    drop(commands);
    drop(ws);
    assert_eq!(thread.join().unwrap(), "reconnecting");
}

/// The app comes back to the foreground: a socket that a suspend left dead,
/// with the server holding it open and silent, is dropped and replaced on the
/// path of a lost connection, without the 45,000 ms silence.
#[test]
fn an_active_app_replaces_a_dead_socket_without_the_silence() {
    /// A margin for load: other worktrees run tests on this machine.
    const LOAD_MARGIN: Duration = Duration::from_secs(3);
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let port = listener.local_addr().unwrap().port();
    let server = stub::local(port);
    let shared = Arc::new(Mutex::new(Shared::new()));
    let (commands, receive) = channel();
    let (welcomed, at_welcome) = channel();
    let (accepted, at_accept) = channel();
    let (stop, stopped) = channel::<()>();
    let stub = std::thread::spawn(move || {
        // The first connection: the welcome, the two requests that it sends,
        // and then silence. The stub holds the socket open, so the client
        // cannot tell that the suspend killed it.
        let mut ws = accept(listener.accept().unwrap().0).unwrap();
        welcome(&mut ws, "tok-q4");
        let _live = ws.read();
        let _saved = ws.read();
        welcomed.send(()).unwrap();
        // Only the wake-up ends it: the server sends nothing.
        assert!(ws.read().is_err());
        // The second connection: the same server, on the path of a lost
        // connection.
        let mut ws = accept(listener.accept().unwrap().0).unwrap();
        welcome(&mut ws, "tok-q4");
        accepted.send(()).unwrap();
        let _ = stopped.recv();
    });
    let thread_shared = shared.clone();
    let thread = std::thread::spawn(move || {
        net::run(&stub::fixed(&server), &thread_shared, &receive, &|| {})
    });
    at_welcome.recv().unwrap();
    let started = Instant::now();
    net::became_active(&commands);
    at_accept
        .recv_timeout(WAITS.pause + LOAD_MARGIN)
        .expect("the dead socket is replaced");
    // The pause of the reconnect, far below the silence bound.
    assert!(
        started.elapsed() < WAITS.pause + LOAD_MARGIN,
        "{:?}",
        started.elapsed()
    );
    // The host is gone: the thread ends at the end of the connection.
    drop(commands);
    stop.send(()).unwrap();
    stub.join().unwrap();
    thread.join().unwrap();
}

/// A wake-up that comes before the first welcome names no socket that a
/// suspend left dead: the connection goes on to the welcome, and its thread
/// reconnects at its end rather than stopping as a connection that never came
/// up.
#[test]
fn a_wake_up_before_the_welcome_leaves_the_connection() {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let port = listener.local_addr().unwrap().port();
    let server = stub::local(port);
    let shared = Arc::new(Mutex::new(Shared::new()));
    let (commands, receive) = channel();
    // The launch: the host reports that it is active before the thread meets
    // the server.
    net::became_active(&commands);
    let thread_shared = shared.clone();
    let thread = std::thread::spawn(move || {
        net::run(&stub::fixed(&server), &thread_shared, &receive, &|| {})
    });
    let mut ws = accept(listener.accept().unwrap().0).unwrap();
    welcome(&mut ws, "tok-q4");
    // The requests of the welcome: the records subscription, refused on a
    // server with no Hub, then the first page of the saved sessions, and the
    // live sessions that the refusal allows.
    let records = request(&mut ws, "records.subscribe");
    error(&mut ws, id_of(&records), "unknown_op");
    let _saved = request(&mut ws, "sessions.saved");
    let live = request(&mut ws, "sessions.live");
    ws.send(Message::text(
        LIVE.replace(r#""id":"0""#, &format!(r#""id":"{}""#, id_of(&live))),
    ))
    .unwrap();
    // The host is gone: the thread ends at the end of the connection.
    drop(commands);
    drop(ws);
    assert_eq!(thread.join().unwrap(), "reconnecting");
    assert_eq!(shared.lock().unwrap().live.len(), 1);
}

/// The pause of a reconnect is a wait on the commands: a host that goes during
/// it ends the thread at once, and the server sees no second connection.
#[test]
fn a_drop_in_the_pause_opens_no_connection() {
    /// A margin for load: other worktrees run tests on this machine.
    const LOAD_MARGIN: Duration = Duration::from_secs(3);
    let pause = Duration::from_secs(6);
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let port = listener.local_addr().unwrap().port();
    let server = stub::local(port);
    let shared = Arc::new(Mutex::new(Shared::new()));
    let (commands, receive) = channel();
    let (lines, notified) = channel();
    let waits = Waits { pause, ..WAITS };
    let thread_shared = shared.clone();
    let thread = std::thread::spawn(move || {
        let read = thread_shared.clone();
        let notify = move || {
            let _ = lines.send(read.lock().unwrap().line.clone());
        };
        net::run_with(
            &stub::fixed(&server),
            &thread_shared,
            &receive,
            &notify,
            waits,
        )
    });
    let (ended, at_end) = channel();
    let (checked, at_check) = channel();
    let stub = std::thread::spawn(move || {
        let mut ws = accept(listener.accept().unwrap().0).unwrap();
        welcome(&mut ws, "tok-q4");
        let _live = ws.read();
        let _saved = ws.read();
        // A close: the thread reconnects after its pause.
        let _ = ws.close(None);
        let _ = ws.flush();
        // Whether a connection comes while the host is gone.
        at_end.recv().unwrap();
        listener.set_nonblocking(true).unwrap();
        checked.send(listener.accept().is_ok()).unwrap();
    });
    // The end of the connection, then the return of the commands between
    // connections: the pause starts after the second line.
    let mut ended_once = 0;
    while ended_once < 2 {
        if notified.recv().unwrap() == "reconnecting" {
            ended_once += 1;
        }
    }
    let dropped = Instant::now();
    drop(commands);
    assert_eq!(thread.join().unwrap(), "reconnecting");
    // Well before the pause, and the server took no second connection.
    assert!(
        dropped.elapsed() < pause - LOAD_MARGIN,
        "{:?}",
        dropped.elapsed()
    );
    ended.send(()).unwrap();
    assert!(
        !at_check.recv().unwrap(),
        "the server took a second connection"
    );
    stub.join().unwrap();
}

/// The wait for a frame that a test expects: a bound of the stub, so a frame
/// that does not come fails the test instead of blocking it.
const FRAME_WAIT: Duration = Duration::from_secs(5);
/// A margin for load when a test waits for a frame that must not come: other
/// worktrees run tests on this machine.
const QUIET_MARGIN: Duration = Duration::from_millis(500);

/// The welcome of a server with no Hub: `records.subscribe` is refused with
/// `unknown_op`, and the requests of the old path follow. Gives the
/// `sessions.saved` and the `sessions.live` request, which the test answers.
fn no_hub(ws: &mut WebSocket<TcpStream>, token: &str) -> (Json, Json) {
    welcome(ws, token);
    let records = request(ws, "records.subscribe");
    error(ws, id_of(&records), "unknown_op");
    let saved = request(ws, "sessions.saved");
    let live = request(ws, "sessions.live");
    (saved, live)
}

/// The welcome of a stub connection with no Hub, with the answers of the two
/// requests of the old path: the live sessions and the saved ones.
fn start(ws: &mut WebSocket<TcpStream>, token: &str) {
    let (saved, live) = no_hub(ws, token);
    ok(ws, id_of(&live), r#"{"sessions":[]}"#);
    ok(ws, id_of(&saved), r#"{"items":[],"next":null}"#);
}

/// One `record` of the records feed, as the server sends it.
fn record(
    session: &str,
    title: &str,
    prompt: &str,
    status: &str,
    active_at: u64,
    parent: Option<&str>,
) -> String {
    let parent = match parent {
        None => "null".to_owned(),
        Some(id) => format!(r#"{{"session":"{id}","kind":"child"}}"#),
    };
    format!(
        r#"{{"session":"{session}","owner":{{"id":"u1","name":"ada"}},"project":null,"title":"{title}","labels":[],"visibility":"private","archived":false,"created_at":1,"updated_at":1,"cwd":"/r/{session}","model":"fake/echo","prompt":"{prompt}","active_at":{active_at},"parent":{parent},"status":"{status}"}}"#
    )
}

/// Whether the stub reads no frame within the margin. The margin holds the
/// poll of the network thread, 100 ms, so a frame that the thread sends goes
/// before the end of it.
fn silent(ws: &mut WebSocket<TcpStream>) -> bool {
    ws.get_mut().set_read_timeout(Some(QUIET_MARGIN)).unwrap();
    let quiet = matches!(ws.read(), Err(tungstenite::Error::Io(_)));
    ws.get_mut().set_read_timeout(None).unwrap();
    quiet
}

fn ok(ws: &mut WebSocket<TcpStream>, id: &str, result: &str) {
    ws.send(Message::text(format!(
        r#"{{"type":"res","id":"{id}","ok":true,"result":{result}}}"#
    )))
    .unwrap();
}

fn error(ws: &mut WebSocket<TcpStream>, id: &str, code: &str) {
    ws.send(Message::text(format!(
        r#"{{"type":"res","id":"{id}","ok":false,"error":{{"code":"{code}","text":"x"}}}}"#
    )))
    .unwrap();
}

/// Waits until the window state passes `done`, on the changes of the thread.
fn until(changes: &Receiver<()>, shared: &Mutex<Shared>, done: impl Fn(&Shared) -> bool) {
    while !(done)(&shared.lock().unwrap()) {
        changes.recv().unwrap();
    }
}

/// The network thread of a test and the channel that drives it.
fn drive(
    server: Server,
    shared: Arc<Mutex<Shared>>,
) -> (std::sync::mpsc::Sender<Command>, Receiver<()>) {
    drive_with(server, shared, WAITS)
}

/// `drive` with other waits.
fn drive_with(
    server: Server,
    shared: Arc<Mutex<Shared>>,
    waits: Waits,
) -> (std::sync::mpsc::Sender<Command>, Receiver<()>) {
    let (commands, receive) = channel();
    let (changed, changes) = channel();
    std::thread::spawn(move || {
        net::run_with(
            &stub::fixed(&server),
            &shared,
            &receive,
            &|| {
                let _ = changed.send(());
            },
            waits,
        )
    });
    (commands, changes)
}

#[test]
fn the_welcome_asks_for_the_records_first() {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let port = listener.local_addr().unwrap().port();
    let shared = Arc::new(Mutex::new(Shared::new()));
    let (_commands, changes) = drive(stub::local(port), shared.clone());
    let mut ws = accept(listener.accept().unwrap().0).unwrap();
    ws.get_mut().set_read_timeout(Some(FRAME_WAIT)).unwrap();
    welcome(&mut ws, "tok-q4");
    let records = next_request(&mut ws);
    assert_eq!(
        records.get("op").and_then(Json::as_str),
        Some("records.subscribe")
    );
    assert_eq!(records.get("params"), Some(&decode("{}").unwrap()));
    let waiting = record("s1", "fix the build", "", "waiting", 100, None);
    let idle = record("s2", "", "go", "idle", 200, None);
    ok(
        &mut ws,
        id_of(&records),
        &format!(r#"{{"records":[{waiting},{idle}],"more":true}}"#),
    );
    until(&changes, &shared, |s| {
        s.records && s.client.records().rows().len() == 2
    });
    {
        let shared = shared.lock().unwrap();
        let rows = shared.client.records().rows();
        assert_eq!(rows[0].session, "s1");
        assert_eq!(rows[0].status, Status::Waiting);
        assert_eq!(rows[1].session, "s2");
        assert!(shared.client.records().more());
        // The request is not one of the host's, so it has no line.
        assert!(
            shared
                .requests
                .iter()
                .all(|line| line.op != "records.subscribe"),
            "{:?}",
            shared.requests
        );
    }
    // The saved page of the welcome is not a live list: read it, so the next
    // read waits for a frame of the feed or the live list only.
    let _saved = request(&mut ws, "sessions.saved");
    // A server with a feed gets no `sessions.live` on this connection.
    assert!(silent(&mut ws));
}

#[test]
fn a_record_change_notifies_the_host_and_moves_a_waiting_row_first() {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let port = listener.local_addr().unwrap().port();
    let shared = Arc::new(Mutex::new(Shared::new()));
    let (_commands, changes) = drive(stub::local(port), shared.clone());
    let mut ws = accept(listener.accept().unwrap().0).unwrap();
    ws.get_mut().set_read_timeout(Some(FRAME_WAIT)).unwrap();
    welcome(&mut ws, "tok-q4");
    let records = next_request(&mut ws);
    let idle = record("s2", "", "go", "idle", 200, None);
    ok(
        &mut ws,
        id_of(&records),
        &format!(r#"{{"records":[{idle}],"more":false}}"#),
    );
    until(&changes, &shared, |s| {
        s.records && s.client.records().rows().len() == 1
    });
    let waiting = record("s1", "", "", "waiting", 400, None);
    ws.send(Message::text(format!(
        r#"{{"type":"record","change":{{"kind":"changed","record":{waiting}}}}}"#
    )))
    .unwrap();
    until(&changes, &shared, |s| {
        let rows = s.client.records().rows();
        rows.len() == 2
            && rows[0].session == "s1"
            && rows[0].status == Status::Waiting
            && rows[1].session == "s2"
    });
}

#[test]
fn a_server_without_a_hub_falls_back_to_the_live_list() {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let port = listener.local_addr().unwrap().port();
    let shared = Arc::new(Mutex::new(Shared::new()));
    let (_commands, changes) = drive(stub::local(port), shared.clone());
    let mut ws = accept(listener.accept().unwrap().0).unwrap();
    ws.get_mut().set_read_timeout(Some(FRAME_WAIT)).unwrap();
    welcome(&mut ws, "tok-q4");
    let records = next_request(&mut ws);
    error(&mut ws, id_of(&records), "unknown_op");
    let live = request(&mut ws, "sessions.live");
    ok(
        &mut ws,
        id_of(&live),
        r#"{"sessions":[{"id":"s1","instance_id":"i1","cwd":"/r","model":"fake/echo","status":"idle"}]}"#,
    );
    until(&changes, &shared, |s| s.live.len() == 1);
    let shared = shared.lock().unwrap();
    assert!(!shared.records);
    assert!(
        shared
            .requests
            .iter()
            .all(|line| line.op != "records.subscribe"),
        "{:?}",
        shared.requests
    );
}

#[test]
fn records_end_subscribes_again_after_the_pause() {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let port = listener.local_addr().unwrap().port();
    let shared = Arc::new(Mutex::new(Shared::new()));
    let waits = Waits {
        pause: Duration::from_millis(150),
        ..WAITS
    };
    let (_commands, changes) = drive_with(stub::local(port), shared.clone(), waits);
    let mut ws = accept(listener.accept().unwrap().0).unwrap();
    ws.get_mut().set_read_timeout(Some(FRAME_WAIT)).unwrap();
    welcome(&mut ws, "tok-q4");
    let first = request(&mut ws, "records.subscribe");
    ok(
        &mut ws,
        id_of(&first),
        &format!(
            r#"{{"records":[{}],"more":false}}"#,
            record("s1", "", "", "idle", 1, None)
        ),
    );
    until(&changes, &shared, |s| {
        s.records && s.client.records().rows().len() == 1
    });
    let ended = Instant::now();
    ws.send(Message::text(r#"{"type":"records_end"}"#)).unwrap();
    let second = request(&mut ws, "records.subscribe");
    // The subscribe waits the pause of a reconnect; load only makes it later.
    assert!(ended.elapsed() >= waits.pause, "{:?}", ended.elapsed());
    // The connection keeps its feed across the end: the window keeps its
    // list while the new one waits.
    assert!(shared.lock().unwrap().records);
    ok(
        &mut ws,
        id_of(&second),
        &format!(
            r#"{{"records":[{}],"more":false}}"#,
            record("s2", "", "", "idle", 2, None)
        ),
    );
    until(&changes, &shared, |s| {
        let rows = s.client.records().rows();
        s.records && rows.len() == 1 && rows[0].session == "s2"
    });
    // A second end does the same.
    ws.send(Message::text(r#"{"type":"records_end"}"#)).unwrap();
    let third = request(&mut ws, "records.subscribe");
    ok(
        &mut ws,
        id_of(&third),
        &format!(
            r#"{{"records":[{}],"more":false}}"#,
            record("s3", "", "", "idle", 3, None)
        ),
    );
    until(&changes, &shared, |s| {
        let rows = s.client.records().rows();
        s.records && rows.len() == 1 && rows[0].session == "s3"
    });
}

#[test]
fn a_new_connection_subscribes_again() {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let port = listener.local_addr().unwrap().port();
    let shared = Arc::new(Mutex::new(Shared::new()));
    let (_commands, changes) = drive(stub::local(port), shared.clone());
    let mut ws = accept(listener.accept().unwrap().0).unwrap();
    ws.get_mut().set_read_timeout(Some(FRAME_WAIT)).unwrap();
    welcome(&mut ws, "tok-q4");
    let first = request(&mut ws, "records.subscribe");
    ok(
        &mut ws,
        id_of(&first),
        &format!(
            r#"{{"records":[{}],"more":false}}"#,
            record("s1", "", "", "idle", 1, None)
        ),
    );
    until(&changes, &shared, |s| {
        s.records && s.client.records().rows().len() == 1
    });
    drop(ws);
    // The next connection opens after the pause of a reconnect, and
    // subscribes again.
    let mut ws = accept(listener.accept().unwrap().0).unwrap();
    ws.get_mut().set_read_timeout(Some(FRAME_WAIT)).unwrap();
    welcome(&mut ws, "tok-q4");
    let again = request(&mut ws, "records.subscribe");
    // The rows of the old connection stay until the new reply.
    {
        let shared = shared.lock().unwrap();
        assert!(shared.records);
        assert_eq!(shared.client.records().rows().len(), 1);
    }
    let second = record("s2", "", "", "idle", 2, None);
    let first = record("s1", "", "", "idle", 1, None);
    ok(
        &mut ws,
        id_of(&again),
        &format!(r#"{{"records":[{first},{second}],"more":false}}"#),
    );
    until(&changes, &shared, |s| {
        s.records && s.client.records().rows().len() == 2
    });
}

#[test]
fn a_transient_error_of_the_records_subscribe_asks_again() {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let port = listener.local_addr().unwrap().port();
    let shared = Arc::new(Mutex::new(Shared::new()));
    let (_commands, changes) = drive(stub::local(port), shared.clone());
    let mut ws = accept(listener.accept().unwrap().0).unwrap();
    ws.get_mut().set_read_timeout(Some(FRAME_WAIT)).unwrap();
    welcome(&mut ws, "tok-q4");
    let first = request(&mut ws, "records.subscribe");
    error(&mut ws, id_of(&first), "timeout");
    let second = request(&mut ws, "records.subscribe");
    error(&mut ws, id_of(&second), "busy");
    let third = request(&mut ws, "records.subscribe");
    ok(
        &mut ws,
        id_of(&third),
        &format!(
            r#"{{"records":[{}],"more":false}}"#,
            record("s1", "", "", "idle", 1, None)
        ),
    );
    until(&changes, &shared, |s| {
        s.records && s.client.records().rows().len() == 1
    });
}

#[test]
fn another_error_of_the_records_subscribe_is_one_line() {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let port = listener.local_addr().unwrap().port();
    let shared = Arc::new(Mutex::new(Shared::new()));
    let (_commands, changes) = drive(stub::local(port), shared.clone());
    let mut ws = accept(listener.accept().unwrap().0).unwrap();
    ws.get_mut().set_read_timeout(Some(FRAME_WAIT)).unwrap();
    welcome(&mut ws, "tok-q4");
    let records = next_request(&mut ws);
    error(&mut ws, id_of(&records), "too_many_subscriptions");
    let _saved = request(&mut ws, "sessions.saved");
    until(&changes, &shared, |s| {
        s.line.contains("too_many_subscriptions")
    });
    {
        let shared = shared.lock().unwrap();
        assert!(!shared.records);
        assert!(
            shared
                .requests
                .iter()
                .all(|line| line.op != "records.subscribe"),
            "{:?}",
            shared.requests
        );
    }
    // The line is once, and the thread does not ask again on this connection.
    assert!(silent(&mut ws));
}

#[test]
fn a_live_command_sends_nothing_with_a_feed() {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let port = listener.local_addr().unwrap().port();
    let shared = Arc::new(Mutex::new(Shared::new()));
    let (commands, changes) = drive(stub::local(port), shared.clone());
    let mut ws = accept(listener.accept().unwrap().0).unwrap();
    ws.get_mut().set_read_timeout(Some(FRAME_WAIT)).unwrap();
    welcome(&mut ws, "tok-q4");
    let records = next_request(&mut ws);
    ok(
        &mut ws,
        id_of(&records),
        &format!(
            r#"{{"records":[{}],"more":false}}"#,
            record("s1", "", "", "idle", 1, None)
        ),
    );
    until(&changes, &shared, |s| {
        s.records && s.client.records().rows().len() == 1
    });
    // The saved page of the welcome is answered, so the command below goes.
    let saved = request(&mut ws, "sessions.saved");
    ok(&mut ws, id_of(&saved), r#"{"items":[],"next":null}"#);
    // The live command sends nothing; the saved one that follows sends its
    // page. The commands go in order, so the first request is the saved one.
    commands.send(Command::Live).unwrap();
    commands.send(Command::Saved { after: None }).unwrap();
    let next = next_request(&mut ws);
    assert_eq!(
        next.get("op").and_then(Json::as_str),
        Some("sessions.saved")
    );
}

#[test]
fn a_prompt_goes_with_its_text_and_its_reply_is_ok() {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let port = listener.local_addr().unwrap().port();
    let shared = Arc::new(Mutex::new(Shared::new()));
    let (commands, changes) = drive(stub::local(port), shared.clone());
    let mut ws = accept(listener.accept().unwrap().0).unwrap();
    start(&mut ws, "tok-q4");
    commands
        .send(Command::Operation {
            send: Some(3),
            operation: helyx_client_core::operation::Operation::prompt("s1", "a text").unwrap(),
        })
        .unwrap();
    let prompt = request(&mut ws, "prompt");
    assert_eq!(
        prompt.get("params"),
        Some(&decode(r#"{"session":"s1","text":"a text"}"#).unwrap())
    );
    // The line of the request waits for its reply.
    until(&changes, &shared, |s| {
        s.requests
            .iter()
            .any(|line| line.op == "prompt" && line.state == RequestState::Pending)
    });
    ok(&mut ws, id_of(&prompt), "{}");
    until(&changes, &shared, |s| {
        s.requests
            .iter()
            .any(|line| line.op == "prompt" && line.state == RequestState::Ok)
    });
    let shared = shared.lock().unwrap();
    let line = (shared.requests.iter())
        .find(|line| line.op == "prompt")
        .cloned()
        .unwrap();
    assert_eq!(line.label, "prompt \"a text\"");
    // The send's outcome is `ok`: the input empties its composer.
    assert!(
        shared
            .outcomes
            .iter()
            .any(|(send, outcome)| *send == 3 && *outcome == net::send::SendOutcome::Ok),
        "{:?}",
        shared.outcomes
    );
}

#[test]
fn an_error_of_the_server_is_its_line() {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let port = listener.local_addr().unwrap().port();
    let shared = Arc::new(Mutex::new(Shared::new()));
    let (commands, changes) = drive(stub::local(port), shared.clone());
    let mut ws = accept(listener.accept().unwrap().0).unwrap();
    start(&mut ws, "tok-q4");
    commands
        .send(Command::Operation {
            send: None,
            operation: helyx_client_core::operation::Operation::abort("s1"),
        })
        .unwrap();
    let abort = request(&mut ws, "abort");
    error(&mut ws, id_of(&abort), "session_not_found");
    until(&changes, &shared, |s| {
        (s.requests.iter()).any(|line| {
            line.op == "abort"
                && line.state
                    == (RequestState::Error {
                        code: "session_not_found".into(),
                        text: "x".into(),
                    })
        })
    });
}

#[test]
fn a_close_with_a_request_out_takes_its_reply_as_unknown_and_never_resends() {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let port = listener.local_addr().unwrap().port();
    let shared = Arc::new(Mutex::new(Shared::new()));
    let (commands, changes) = drive(stub::local(port), shared.clone());
    let mut ws = accept(listener.accept().unwrap().0).unwrap();
    start(&mut ws, "tok-q4");
    commands
        .send(Command::Operation {
            send: None,
            operation: helyx_client_core::operation::Operation::abort("s1"),
        })
        .unwrap();
    let _abort = request(&mut ws, "abort");
    // The connection ends before the reply: the abort is unknown.
    drop(ws);
    drop(listener);
    until(&changes, &shared, |s| {
        (s.requests.iter()).any(|line| line.op == "abort" && line.state == RequestState::Unknown)
    });
    // The next connection sends no abort of its own: its first request is
    // the records subscription of every welcome, then the live list of a
    // server with no Hub, and the request lines still hold only the abort.
    let listener = TcpListener::bind(("127.0.0.1", port)).unwrap();
    let mut ws = accept(listener.accept().unwrap().0).unwrap();
    welcome(&mut ws, "tok-q4");
    let records = next_request(&mut ws);
    assert_eq!(
        records.get("op").and_then(Json::as_str),
        Some("records.subscribe")
    );
    error(&mut ws, id_of(&records), "unknown_op");
    let frame = next_request(&mut ws);
    assert_eq!(
        frame.get("op").and_then(Json::as_str),
        Some("sessions.live")
    );
    ok(&mut ws, id_of(&frame), r#"{"sessions":[]}"#);
    let shared = shared.lock().unwrap();
    let ops: Vec<&str> = (shared.requests.iter()).map(|line| line.op).collect();
    assert_eq!(
        ops,
        ["sessions.saved", "sessions.live", "abort", "sessions.live"]
    );
    let abort = (shared.requests.iter())
        .find(|line| line.op == "abort")
        .unwrap();
    assert_eq!(abort.state, RequestState::Unknown);
    let _ = commands;
}

#[test]
fn a_lost_reply_of_a_composer_send_fails_its_outcome() {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let port = listener.local_addr().unwrap().port();
    let shared = Arc::new(Mutex::new(Shared::new()));
    let (commands, changes) = drive(stub::local(port), shared.clone());
    let mut ws = accept(listener.accept().unwrap().0).unwrap();
    start(&mut ws, "tok-q4");
    commands
        .send(Command::Operation {
            send: Some(5),
            operation: helyx_client_core::operation::Operation::prompt("s1", "lost").unwrap(),
        })
        .unwrap();
    let _prompt = request(&mut ws, "prompt");
    // The connection ends before the reply: the outcome is `Failed`, so the
    // input keeps the text and the user decides whether to send it again.
    drop(ws);
    drop(listener);
    until(&changes, &shared, |s| {
        (s.outcomes.iter()).any(|(send, outcome)| {
            *send == 5 && *outcome == net::send::SendOutcome::Failed("the reply was lost".into())
        })
    });
    let _ = commands;
}

#[test]
fn a_start_follows_the_session_that_it_made() {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let port = listener.local_addr().unwrap().port();
    let shared = Arc::new(Mutex::new(Shared::new()));
    let (commands, changes) = drive(stub::local(port), shared.clone());
    let mut ws = accept(listener.accept().unwrap().0).unwrap();
    start(&mut ws, "tok-q4");
    commands
        .send(Command::Operation {
            send: None,
            operation: helyx_client_core::operation::Operation::start("/r", None).unwrap(),
        })
        .unwrap();
    let start = request(&mut ws, "start");
    assert_eq!(
        start.get("params"),
        Some(&decode(r#"{"cwd":"/r"}"#).unwrap())
    );
    ok(&mut ws, id_of(&start), r#"{"session":"s2"}"#);
    let subscribe = request(&mut ws, "subscribe");
    assert_eq!(
        subscribe.get("params"),
        Some(&decode(r#"{"session":"s2","answers":true}"#).unwrap())
    );
    ok(
        &mut ws,
        id_of(&subscribe),
        &format!(r#"{{"sub":"0","snapshot":{}}}"#, snapshot(1)),
    );
    until(&changes, &shared, |s| s.followed.as_deref() == Some("s2"));
}

#[test]
fn more_saved_sessions_append_the_next_page() {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let port = listener.local_addr().unwrap().port();
    let shared = Arc::new(Mutex::new(Shared::new()));
    let (commands, changes) = drive(stub::local(port), shared.clone());
    let mut ws = accept(listener.accept().unwrap().0).unwrap();
    let (saved, live) = no_hub(&mut ws, "tok-q4");
    ok(&mut ws, id_of(&live), r#"{"sessions":[]}"#);
    let page =
        r#"{"items":[{"id":"a","cwd":"/r","model":"m","mtime":0,"prompt":"first"}],"next":"c1"}"#;
    ok(&mut ws, id_of(&saved), page);
    until(&changes, &shared, |s| s.saved.len() == 1);
    commands
        .send(Command::Saved {
            after: Some("c1".into()),
        })
        .unwrap();
    let more = request(&mut ws, "sessions.saved");
    assert_eq!(
        more.get("params"),
        Some(&decode(r#"{"after":"c1","limit":256}"#).unwrap())
    );
    let page =
        r#"{"items":[{"id":"b","cwd":"/r2","model":"m","mtime":0,"prompt":"second"}],"next":null}"#;
    ok(&mut ws, id_of(&more), page);
    until(&changes, &shared, |s| s.saved.len() == 2);
    let shared = shared.lock().unwrap();
    assert_eq!(
        shared
            .saved
            .iter()
            .map(|s| s.id.as_str())
            .collect::<Vec<_>>(),
        ["a", "b"]
    );
    assert_eq!(shared.saved_next, None);
}

#[test]
fn two_more_pages_before_a_reply_do_not_replace_the_first_page() {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let port = listener.local_addr().unwrap().port();
    let shared = Arc::new(Mutex::new(Shared::new()));
    let (commands, changes) = drive(stub::local(port), shared.clone());
    let mut ws = accept(listener.accept().unwrap().0).unwrap();
    let (saved, live) = no_hub(&mut ws, "tok-q4");
    ok(&mut ws, id_of(&live), r#"{"sessions":[]}"#);
    let page =
        r#"{"items":[{"id":"a","cwd":"/r","model":"m","mtime":0,"prompt":"first"}],"next":"c1"}"#;
    ok(&mut ws, id_of(&saved), page);
    until(&changes, &shared, |s| s.saved.len() == 1);
    for _ in 0..2 {
        commands
            .send(Command::Saved {
                after: Some("c1".into()),
            })
            .unwrap();
    }
    let more = request(&mut ws, "sessions.saved");
    let page =
        r#"{"items":[{"id":"b","cwd":"/r","model":"m","mtime":0,"prompt":"second"}],"next":null}"#;
    ok(&mut ws, id_of(&more), page);
    until(&changes, &shared, |s| s.saved.len() == 2);
    let shared = shared.lock().unwrap();
    assert_eq!(
        (shared.saved.iter())
            .map(|session| session.id.as_str())
            .collect::<Vec<_>>(),
        ["a", "b"]
    );
}

#[test]
fn a_refresh_then_a_more_keeps_the_first_page() {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let port = listener.local_addr().unwrap().port();
    let shared = Arc::new(Mutex::new(Shared::new()));
    let (commands, changes) = drive(stub::local(port), shared.clone());
    let mut ws = accept(listener.accept().unwrap().0).unwrap();
    let (saved, live) = no_hub(&mut ws, "tok-q4");
    ok(&mut ws, id_of(&live), r#"{"sessions":[]}"#);
    let page =
        r#"{"items":[{"id":"a","cwd":"/r","model":"m","mtime":0,"prompt":"first"}],"next":"c1"}"#;
    ok(&mut ws, id_of(&saved), page);
    until(&changes, &shared, |s| s.saved.len() == 1);
    // The refresh and the more are sent before either reply.
    commands.send(Command::Saved { after: None }).unwrap();
    commands
        .send(Command::Saved {
            after: Some("c1".into()),
        })
        .unwrap();
    let refresh = request(&mut ws, "sessions.saved");
    assert!(
        more_after(&refresh).is_none(),
        "{:?}",
        refresh.get("params")
    );
    let page = r#"{"items":[{"id":"a2","cwd":"/r","model":"m","mtime":0,"prompt":"first again"}],"next":"c1"}"#;
    ok(&mut ws, id_of(&refresh), page);
    until(&changes, &shared, |s| {
        s.saved.first().is_some_and(|session| session.id == "a2")
    });
    assert_eq!(shared.lock().unwrap().saved.len(), 1);
    // A later more appends at the next page.
    commands
        .send(Command::Saved {
            after: Some("c1".into()),
        })
        .unwrap();
    let more = request(&mut ws, "sessions.saved");
    let page =
        r#"{"items":[{"id":"b","cwd":"/r","model":"m","mtime":0,"prompt":"second"}],"next":null}"#;
    ok(&mut ws, id_of(&more), page);
    until(&changes, &shared, |s| s.saved.len() == 2);
    let shared = shared.lock().unwrap();
    assert_eq!(
        (shared.saved.iter())
            .map(|session| session.id.as_str())
            .collect::<Vec<_>>(),
        ["a2", "b"]
    );
}

/// The `after` of the params of a `sessions.saved` request, if it has one.
fn more_after(frame: &Json) -> Option<&str> {
    frame
        .get("params")
        .and_then(|params| params.get("after"))
        .and_then(Json::as_str)
}

#[test]
fn a_send_between_connections_is_not_sent_and_its_line_stays() {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let port = listener.local_addr().unwrap().port();
    let shared = Arc::new(Mutex::new(Shared::new()));
    let (commands, changes) = drive(stub::local(port), shared.clone());
    let mut ws = accept(listener.accept().unwrap().0).unwrap();
    start(&mut ws, "tok-q4");
    drop(ws);
    drop(listener);
    // The connection is over before the command goes: a send between
    // connections.
    until(&changes, &shared, |s| s.line != "connected");
    // No connection takes it: the line is `not sent` and the composer keeps
    // the text.
    commands
        .send(Command::Operation {
            send: Some(9),
            operation: helyx_client_core::operation::Operation::prompt("s1", "kept").unwrap(),
        })
        .unwrap();
    until(&changes, &shared, |s| {
        (s.outcomes.iter()).any(|(send, outcome)| {
            *send == 9
                && *outcome == net::send::SendOutcome::Failed("the connection is not ready".into())
        })
    });
    {
        let shared = shared.lock().unwrap();
        let line = (shared.requests.iter())
            .find(|line| {
                line.state
                    == RequestState::Error {
                        code: "not sent".into(),
                        text: "the connection is not ready".into(),
                    }
            })
            .unwrap();
        assert_eq!(line.op, "prompt");
        assert_eq!(line.label, "prompt \"kept\"");
    }
    // The next connection does not overwrite the line.
    let listener = TcpListener::bind(("127.0.0.1", port)).unwrap();
    let mut ws = accept(listener.accept().unwrap().0).unwrap();
    welcome(&mut ws, "tok-q4");
    let records = request(&mut ws, "records.subscribe");
    error(&mut ws, id_of(&records), "unknown_op");
    let live = request(&mut ws, "sessions.live");
    ok(&mut ws, id_of(&live), r#"{"sessions":[]}"#);
    let shared = shared.lock().unwrap();
    assert!(
        shared.requests.iter().any(|line| {
            line.op == "prompt"
                && line.state
                    == (RequestState::Error {
                        code: "not sent".into(),
                        text: "the connection is not ready".into(),
                    })
        }),
        "{:?}",
        shared.requests
    );
    assert_eq!(shared.line, "connected");
}

/// A margin for load on the notify channel: other worktrees run tests on this
/// machine.
const LOAD_MARGIN: Duration = Duration::from_secs(10);

/// Waits for the line `want` among the changes of the network thread.
fn line_is(lines: &Receiver<String>, want: &str) {
    loop {
        let line = lines.recv_timeout(LOAD_MARGIN).expect("the line");
        if line == want {
            return;
        }
    }
}

/// The owner restarts the server at another port with another token: the
/// source gives the new server, the client proves the new token, and the
/// followed session subscribes again with `after` of its state.
#[test]
fn a_restarted_server_at_another_port_and_token_is_followed_again() {
    // The first server: the welcome, a follow with its snapshot, then its end.
    let (first, first_stub) = stub::one(|mut ws| {
        welcome(&mut ws, "tok-q4");
        // The requests of the welcome: the records subscription, refused on
        // a server with no Hub, the first page of the saved sessions, and the
        // live sessions that the refusal allows.
        let records = request(&mut ws, "records.subscribe");
        error(&mut ws, id_of(&records), "unknown_op");
        let saved = request(&mut ws, "sessions.saved");
        ok(&mut ws, id_of(&saved), r#"{"items":[],"next":null}"#);
        // The follow and the live list of the welcome: the order of the two
        // depends on the step of the thread that sends them, so read both.
        for _ in 0..2 {
            let frame = next_request(&mut ws);
            match frame.get("op").and_then(Json::as_str) {
                Some("subscribe") => ok(
                    &mut ws,
                    id_of(&frame),
                    &format!(r#"{{"sub":"0","snapshot":{}}}"#, snapshot(4)),
                ),
                Some("sessions.live") => ok(&mut ws, id_of(&frame), r#"{"sessions":[]}"#),
                other => panic!("unexpected op {other:?}"),
            }
        }
        let _ = ws.close(None);
        let _ = ws.flush();
    });
    let current = Arc::new(Mutex::new(first.clone()));
    let source = {
        let current = current.clone();
        move || -> Result<Server, String> { Ok(current.lock().unwrap().clone()) }
    };
    let shared = Arc::new(Mutex::new(Shared::new()));
    let (commands, receive) = channel();
    let (lines, notified) = channel();
    let waits = Waits {
        pause: Duration::from_millis(20),
        ..WAITS
    };
    let thread_shared = shared.clone();
    let thread = std::thread::spawn(move || {
        let read = thread_shared.clone();
        let notify = move || {
            let _ = lines.send(read.lock().unwrap().line.clone());
        };
        net::run_with(&source, &thread_shared, &receive, &notify, waits)
    });
    commands.send(Command::Follow("s1".into())).unwrap();
    first_stub.join().unwrap();
    // The first connection ended, and the thread is on the reconnect path.
    line_is(&notified, "reconnecting");

    // The second server, at another port and with another token. The source
    // gives it from now on.
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let port = listener.local_addr().unwrap().port();
    let second = Server {
        token: "tok-second".into(),
        ..stub::local(port)
    };
    *current.lock().unwrap() = second;
    let (subscribed, at_subscribe) = channel();
    let (stop, stopped) = channel::<()>();
    let second_stub = std::thread::spawn(move || {
        let mut ws = accept(listener.accept().unwrap().0).unwrap();
        // The proof of the second token, as the handshake of this server has
        // it.
        welcome(&mut ws, "tok-second");
        // The live list and the subscribe with `after`; the saved list went
        // at the first welcome of the run.
        let mut texts = vec![];
        for _ in 0..2 {
            texts.push(next_text(&mut ws));
        }
        let after =
            r#""params":{"session":"s1","after":{"instance_id":"i1","seq":4},"answers":true}"#;
        assert!(texts.iter().any(|text| text.contains(after)), "{texts:?}");
        subscribed.send(()).unwrap();
        let _ = stopped.recv();
    });
    at_subscribe
        .recv_timeout(LOAD_MARGIN)
        .expect("the second server took the subscribe with after");
    assert_eq!(shared.lock().unwrap().line, "connected");

    // The window is gone: the thread ends at the end of the connection.
    drop(commands);
    stop.send(()).unwrap();
    second_stub.join().unwrap();
    assert_eq!(thread.join().unwrap(), "reconnecting");
    let shared = shared.lock().unwrap();
    assert_eq!(shared.followed.as_deref(), Some("s1"));
    assert_eq!(
        shared
            .client
            .state("s1")
            .and_then(|state| state.seq.to_u64()),
        Some(4)
    );
}

/// A source that fails after a welcome: its error is the line, the loop does
/// not end, and when the source gives a server again the client connects.
#[test]
fn a_source_that_fails_after_a_welcome_waits_for_the_server() {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let port = listener.local_addr().unwrap().port();
    let first = stub::local(port);
    let state = Arc::new(Mutex::new(Ok(first.clone())));
    let source = {
        let state = state.clone();
        move || state.lock().unwrap().clone()
    };
    let shared = Arc::new(Mutex::new(Shared::new()));
    let (commands, receive) = channel();
    let (lines, notified) = channel();
    let waits = Waits {
        pause: Duration::from_millis(20),
        ..WAITS
    };
    let thread_shared = shared.clone();
    let thread = std::thread::spawn(move || {
        let read = thread_shared.clone();
        let notify = move || {
            let _ = lines.send(read.lock().unwrap().line.clone());
        };
        net::run_with(&source, &thread_shared, &receive, &notify, waits)
    });

    // The first connection comes up. The source fails before the close: the
    // thread asks it only before a connection, so the order holds at any load.
    let mut ws = accept(listener.accept().unwrap().0).unwrap();
    start(&mut ws, "tok-q4");
    let down = "no server runs for the data folder";
    *state.lock().unwrap() = Err(down.into());
    let _ = ws.close(None);
    let _ = ws.flush();

    // The line is the error of the source, and the loop goes on.
    line_is(&notified, down);
    assert!(!thread.is_finished(), "the loop ended at a failed source");

    // The source gives a server again: the client connects.
    *state.lock().unwrap() = Ok(first.clone());
    let mut ws = accept(listener.accept().unwrap().0).unwrap();
    welcome(&mut ws, "tok-q4");
    // The saved list went at the first welcome of the run: this welcome has
    // the records subscription, refused on a server with no Hub, and the live
    // sessions that the refusal allows.
    let records = request(&mut ws, "records.subscribe");
    error(&mut ws, id_of(&records), "unknown_op");
    let live = request(&mut ws, "sessions.live");
    ok(&mut ws, id_of(&live), r#"{"sessions":[]}"#);
    line_is(&notified, "connected");

    // The window is gone: the thread ends at the end of the connection.
    drop(commands);
    drop(ws);
    drop(listener);
    assert_eq!(thread.join().unwrap(), "reconnecting");
}

/// A source that fails before the first welcome: the loop does not end, and it
/// connects when the source gives a server.
#[test]
fn a_source_that_fails_before_the_first_welcome_waits_for_the_server() {
    let state: Arc<Mutex<Result<Server, String>>> = Arc::new(Mutex::new(Err(
        "no server runs for the data folder".to_string(),
    )));
    let source = {
        let state = state.clone();
        move || state.lock().unwrap().clone()
    };
    let shared = Arc::new(Mutex::new(Shared::new()));
    let (commands, receive) = channel();
    let (lines, notified) = channel();
    let waits = Waits {
        pause: Duration::from_millis(20),
        ..WAITS
    };
    let thread_shared = shared.clone();
    let thread = std::thread::spawn(move || {
        let read = thread_shared.clone();
        let notify = move || {
            let _ = lines.send(read.lock().unwrap().line.clone());
        };
        net::run_with(&source, &thread_shared, &receive, &notify, waits)
    });

    let down = "no server runs for the data folder";
    line_is(&notified, down);
    assert!(!thread.is_finished(), "the loop ended before a connection");

    // A server starts: the source gives it, and the client connects.
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let port = listener.local_addr().unwrap().port();
    *state.lock().unwrap() = Ok(stub::local(port));
    let mut ws = accept(listener.accept().unwrap().0).unwrap();
    start(&mut ws, "tok-q4");
    line_is(&notified, "connected");

    // The window is gone: the thread ends at the end of the connection.
    drop(commands);
    drop(ws);
    drop(listener);
    assert_eq!(thread.join().unwrap(), "reconnecting");
}

/// A source that gives a server keeps the rule of a failed first connect: a
/// connect that fails before the welcome stops the loop.
#[test]
fn a_source_that_gives_a_server_that_does_not_answer_stops() {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let port = listener.local_addr().unwrap().port();
    let server = stub::local(port);
    drop(listener);
    let shared = Mutex::new(Shared::new());
    let (_commands, receive) = channel();
    let line = net::run(&stub::fixed(&server), &shared, &receive, &|| {});
    assert!(line.starts_with("could not connect"), "{line}");
}

/// A `4401` of the second server stops the loop: with a fresh read before each
/// connection, the token of the file is wrong for the server at that address,
/// and a retry cannot pass.
#[test]
fn a_second_server_that_refuses_the_token_stops_the_loop() {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let port = listener.local_addr().unwrap().port();
    let first = stub::local(port);
    let state = Arc::new(Mutex::new(Ok(first)));
    let source = {
        let state = state.clone();
        move || state.lock().unwrap().clone()
    };
    let shared = Arc::new(Mutex::new(Shared::new()));
    let (_commands, receive) = channel();
    let waits = Waits {
        pause: Duration::from_millis(20),
        ..WAITS
    };
    let thread_shared = shared.clone();
    let thread =
        std::thread::spawn(move || net::run_with(&source, &thread_shared, &receive, &|| {}, waits));

    // The first connection comes up and ends.
    let mut ws = accept(listener.accept().unwrap().0).unwrap();
    start(&mut ws, "tok-q4");
    let _ = ws.close(None);
    let _ = ws.flush();
    drop(listener);

    // The second server refuses the proof of the token.
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let port = listener.local_addr().unwrap().port();
    let second = Server {
        token: "tok-second".into(),
        ..stub::local(port)
    };
    *state.lock().unwrap() = Ok(second);
    let second_stub = std::thread::spawn(move || {
        let mut ws = accept(listener.accept().unwrap().0).unwrap();
        challenge(&mut ws);
        let _hello = next_text(&mut ws);
        let close = CloseFrame {
            code: CloseCode::from(4401),
            reason: "token".into(),
        };
        ws.close(Some(close)).unwrap();
        let _ = ws.flush();
    });

    assert_eq!(thread.join().unwrap(), "the server refused the token");
    second_stub.join().unwrap();
}

/// The host that goes away while the source fails ends the loop: the pause is
/// a wait on the commands, so no thread waits for a server that the host gave
/// up on.
#[test]
fn a_host_that_goes_while_the_source_fails_ends_the_loop() {
    /// A margin for load: other worktrees run tests on this machine.
    const LOAD_MARGIN: Duration = Duration::from_secs(3);
    let pause = Duration::from_secs(6);
    let waits = Waits { pause, ..WAITS };
    let shared = Arc::new(Mutex::new(Shared::new()));
    let (commands, receive) = channel();
    let (lines, notified) = channel();
    let thread_shared = shared.clone();
    let thread = std::thread::spawn(move || {
        let read = thread_shared.clone();
        let notify = move || {
            let _ = lines.send(read.lock().unwrap().line.clone());
        };
        let source =
            || -> Result<Server, String> { Err("no server runs for the data folder".into()) };
        net::run_with(&source, &thread_shared, &receive, &notify, waits)
    });
    let down = "no server runs for the data folder";
    line_is(&notified, down);
    // Well before the pause, as the commands are the pause.
    let dropped = Instant::now();
    drop(commands);
    assert_eq!(thread.join().unwrap(), down);
    assert!(
        dropped.elapsed() < pause - LOAD_MARGIN,
        "{:?}",
        dropped.elapsed()
    );
}
