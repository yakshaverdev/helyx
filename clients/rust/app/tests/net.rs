//! The network thread against a stub server on the loopback: the handshake
//! with the proof of the token, `sessions.live`, a follow, the `4408` slow
//! close, the reconnect with `after`, the waits before the welcome, and the
//! breaks of the wire contract.

mod stub;

use helyx_desktop::net::{self, Command, Shared};
use helyx_desktop::settings::Server;
use helyx_desktop::socket::WAITS;
use std::net::{TcpListener, TcpStream};
use std::sync::mpsc::channel;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use stub::{LIVE, challenge, next_text, welcome};
use tungstenite::protocol::CloseFrame;
use tungstenite::protocol::frame::coding::CloseCode;
use tungstenite::{Message, WebSocket, accept};

fn snapshot(seq: u64) -> String {
    format!(
        r#"{{"instance_id":"i1","seq":{seq},"messages":[{{"id":"u1","role":"user","content":[{{"type":"text","text":"hi"}}]}}],"more":false,"turn":null,"model":"fake/echo","persisting":true,"context":null,"asks":[],"ui_blocks":[],"activated":[],"queue":{{"steers":0,"follow_ups":0,"running":0,"held":0,"waiting":0}},"usage":{{"input":0,"output":0,"cache_read":0,"cache_write":0,"cost":null,"unknown":false,"list":false}}}}"#
    )
}

#[test]
fn a_follow_survives_a_slow_close() {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let port = listener.local_addr().unwrap().port();
    let token = "secret-token";
    let server = stub::local(port);
    let shared = Arc::new(Mutex::new(Shared::new(token.into())));
    let (commands, receive) = channel();
    let (changed, changes) = channel();
    let thread_shared = shared.clone();
    let thread = std::thread::spawn(move || {
        net::run(&server, &thread_shared, &receive, &|| {
            let _ = changed.send(());
        })
    });

    // The first connection: the live list, a follow, an event, then 4408.
    let mut ws = accept(listener.accept().unwrap().0).unwrap();
    welcome(&mut ws, token);
    let live = next_text(&mut ws);
    assert!(live.contains(r#""op":"sessions.live""#), "{live}");
    ws.send(Message::text(LIVE)).unwrap();
    while shared.lock().unwrap().live.is_empty() {
        changes.recv().unwrap();
    }
    commands.send(Command::Follow("s1".into())).unwrap();
    let subscribe = next_text(&mut ws);
    assert!(
        subscribe.contains(r#""params":{"session":"s1"}"#),
        "{subscribe}"
    );
    ws.send(Message::text(format!(
        r#"{{"type":"res","id":"1","ok":true,"result":{{"sub":"0","snapshot":{}}}}}"#,
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

    // The second connection: the subscribe with `after` of the state.
    let mut ws = accept(listener.accept().unwrap().0).unwrap();
    welcome(&mut ws, token);
    let texts = [next_text(&mut ws), next_text(&mut ws)];
    let after = r#""params":{"session":"s1","after":{"instance_id":"i1","seq":5}}"#;
    assert!(texts.iter().any(|t| t.contains(after)), "{texts:?}");
    assert!(
        texts.iter().any(|t| t.contains(r#""op":"sessions.live""#)),
        "{texts:?}"
    );
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
    let shared = Mutex::new(Shared::new("tok-q4".into()));
    let receive = channel::<Command>().1;
    let line = net::run(&server, &shared, &receive, &|| {});
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
            r#"{"type":"refused","code":"protocol","server_protocol":9}"#,
        ))
        .unwrap();
        let _ = ws.read();
    });
    assert_eq!(line, "the server speaks protocol 9: update the app");
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
    let shared = Shared::new("tok-5b1e".into());
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
    let shared = Mutex::new(Shared::new("tok-q4".into()));
    let (_commands, receive) = channel();
    let line = net::run(&stub::local(port), &shared, &receive, &|| {});
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
            let _live = next_text(&mut ws);
            let mut bytes = ping;
            bytes.extend([0x81, 126, (LIVE.len() >> 8) as u8, LIVE.len() as u8]);
            bytes.extend(LIVE.as_bytes());
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
    let shared = Arc::new(Mutex::new(Shared::new("tok-q4".into())));
    let (commands, receive) = channel();
    let (lines, notified) = channel();
    let waits = helyx_desktop::socket::Waits {
        pause: Duration::from_millis(50),
        ..WAITS
    };
    let thread_shared = shared.clone();
    let thread = std::thread::spawn(move || {
        let read = thread_shared.clone();
        let notify = move || {
            let _ = lines.send(read.lock().unwrap().line.clone());
        };
        net::run_with(&server, &thread_shared, &receive, &notify, waits)
    });

    // The first connection: a follow and its snapshot, then a lost end.
    let mut ws = accept(listener.accept().unwrap().0).unwrap();
    welcome(&mut ws, "tok-q4");
    let _live = next_text(&mut ws);
    commands.send(Command::Follow("s1".into())).unwrap();
    let _subscribe = next_text(&mut ws);
    ws.send(Message::text(format!(
        r#"{{"type":"res","id":"1","ok":true,"result":{{"sub":"0","snapshot":{}}}}}"#,
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
    let texts = [next_text(&mut ws), next_text(&mut ws)];
    let after = r#""params":{"session":"s1","after":{"instance_id":"i1","seq":4}}"#;
    assert!(texts.iter().any(|t| t.contains(after)), "{texts:?}");

    // The window is gone: the thread ends at the end of the connection.
    drop(commands);
    drop(ws);
    assert_eq!(thread.join().unwrap(), "reconnecting");
}
