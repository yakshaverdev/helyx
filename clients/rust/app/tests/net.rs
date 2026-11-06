//! The network thread against a stub server on the loopback: the handshake
//! with the proof of the token, `sessions.live`, a follow, the `4408` slow
//! close, and the reconnect with `after`.

use helyx_client_core::handshake::proof;
use helyx_desktop::net::{self, Command, Shared};
use helyx_desktop::settings::Server;
use std::net::TcpListener;
use std::sync::mpsc::channel;
use std::sync::{Arc, Mutex};
use tungstenite::protocol::CloseFrame;
use tungstenite::protocol::frame::coding::CloseCode;
use tungstenite::{Message, WebSocket, accept};

const NONCE: &str = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";

fn next_text(ws: &mut WebSocket<std::net::TcpStream>) -> String {
    loop {
        match ws.read().unwrap() {
            Message::Text(text) => return text.to_string(),
            _ => continue,
        }
    }
}

fn challenge(ws: &mut WebSocket<std::net::TcpStream>) {
    ws.send(Message::text(format!(
        r#"{{"type":"challenge","nonce":"{NONCE}"}}"#
    )))
    .unwrap();
}

/// The handshake of the server: the `hello` must carry the proof of `token`.
fn welcome(ws: &mut WebSocket<std::net::TcpStream>, token: &str) {
    challenge(ws);
    let hello = next_text(ws);
    let expected = proof(token, &[0; 32]);
    assert_eq!(
        hello,
        format!(r#"{{"type":"hello","protocol":3,"proof":"{expected}"}}"#)
    );
    assert!(!hello.contains(token));
    ws.send(Message::text(r#"{"type":"welcome","protocol":3}"#))
        .unwrap();
}

fn snapshot(seq: u64) -> String {
    format!(
        r#"{{"instance_id":"i1","seq":{seq},"messages":[{{"id":"u1","role":"user","content":[{{"type":"text","text":"hi"}}]}}],"more":false,"turn":null,"model":"fake/echo","persisting":true,"context":null,"asks":[],"queue":{{"steers":0,"follow_ups":0,"running":0,"held":0,"waiting":0}},"usage":{{"input":0,"output":0,"cache_read":0,"cache_write":0,"cost":null,"unknown":false,"list":false}}}}"#
    )
}

#[test]
fn a_follow_survives_a_slow_close() {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let port = listener.local_addr().unwrap().port();
    let token = "secret-token";
    let server = Server {
        address: "127.0.0.1".parse().unwrap(),
        port,
        token: token.into(),
    };
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
    ws.send(Message::text(
        r#"{"type":"res","id":"0","ok":true,"result":{"sessions":[{"id":"s1","instance_id":"i1","cwd":"/r","model":"fake/echo","status":"idle"}]}}"#,
    ))
    .unwrap();
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
    drop(ws);
    drop(listener);

    // The third connect is refused: the thread stops with its line.
    let line = thread.join().unwrap();
    assert!(
        line.starts_with("could not connect to ws://127.0.0.1:"),
        "{line}"
    );
    let shared = shared.lock().unwrap();
    let state = shared.client.state("s1").unwrap();
    assert_eq!((state.seq, state.notices.len()), (5, 1));
}

/// Runs the network thread against one stub connection, `serve`, and gives
/// the line that the thread ends with: no listener remains for a reconnect.
fn against(serve: impl FnOnce(WebSocket<std::net::TcpStream>) + Send + 'static) -> String {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let port = listener.local_addr().unwrap().port();
    let server = Server {
        address: "127.0.0.1".parse().unwrap(),
        port,
        token: "t".into(),
    };
    let stub = std::thread::spawn(move || {
        let ws = accept(listener.accept().unwrap().0).unwrap();
        drop(listener);
        serve(ws);
    });
    let shared = Mutex::new(Shared::new("tok-q4".into()));
    let (_commands, receive) = channel();
    let line = net::run(&server, &shared, &receive, &|| {});
    stub.join().unwrap();
    line
}

#[test]
fn pings_do_not_hold_the_welcome_wait_open() {
    let started = std::time::Instant::now();
    let line = against(|mut ws| {
        challenge(&mut ws);
        let until = std::time::Instant::now() + net::WAIT + std::time::Duration::from_secs(3);
        while std::time::Instant::now() < until {
            if ws.send(Message::Ping(vec![].into())).is_err() {
                return;
            }
            std::thread::sleep(std::time::Duration::from_millis(50));
        }
    });
    assert_eq!(line, "the server did not answer in 5000 ms");
    // Ends at the wait, not when the stub stops at 8 s; the margin is for load.
    assert!(started.elapsed() >= net::WAIT);
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
        address: "127.0.0.1".parse().unwrap(),
        port: 1,
        token: "tok-5b1e".into(),
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
            std::thread::sleep(std::time::Duration::from_millis(400));
        }
    });
    let server = Server {
        address: "127.0.0.1".parse().unwrap(),
        port,
        token: "tok-q4".into(),
    };
    let shared = Mutex::new(Shared::new("tok-q4".into()));
    let (_commands, receive) = channel();
    let line = net::run(&server, &shared, &receive, &|| {});
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
            std::thread::sleep(std::time::Duration::from_millis(50));
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
