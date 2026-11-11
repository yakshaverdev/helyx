//! The stub server of the tests of this layer, on the loopback. The tests of
//! the network crate and its bindings drive the same stub.

// Each test binary uses a part of the helpers.
#![allow(dead_code)]

use crate::Server;
use helyx_client_core::handshake::proof;
use std::net::{TcpListener, TcpStream};
use std::thread::JoinHandle;
use tungstenite::{Message, WebSocket, accept};

const NONCE: &str = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";

/// The reply of the server to `sessions.live`, the first request of a
/// connection: one session, `s1`.
pub const LIVE: &str = r#"{"type":"res","id":"0","ok":true,"result":{"sessions":[{"id":"s1","instance_id":"i1","cwd":"/r","model":"fake/echo","status":"idle"}]}}"#;

/// The next text frame of the client: a ping or a pong is passed over.
pub fn next_text(ws: &mut WebSocket<TcpStream>) -> String {
    loop {
        match ws.read().unwrap() {
            Message::Text(text) => return text.to_string(),
            _ => continue,
        }
    }
}

/// The `challenge` of the handshake, with the 32 bytes of `proof`.
pub fn challenge(ws: &mut WebSocket<TcpStream>) {
    ws.send(Message::text(format!(
        r#"{{"type":"challenge","nonce":"{NONCE}"}}"#
    )))
    .unwrap();
}

/// The handshake of the server: the `hello` must carry the proof of `token`.
pub fn welcome(ws: &mut WebSocket<TcpStream>, token: &str) {
    challenge(ws);
    let hello = next_text(ws);
    let expected = proof(token, &[0; 32]);
    assert_eq!(
        hello,
        format!(r#"{{"type":"hello","protocol":10,"proof":"{expected}"}}"#)
    );
    assert!(!hello.contains(token));
    ws.send(Message::text(r#"{"type":"welcome","protocol":10}"#))
        .unwrap();
}

/// The server on the loopback at `port`.
pub fn local(port: u16) -> Server {
    Server {
        address: "127.0.0.1".parse().unwrap(),
        port,
        token: "tok-q4".into(),
    }
}

/// A stub that takes one connection, upgrades it, and runs `serve` on it:
/// no listener remains for a reconnect.
pub fn one(serve: impl FnOnce(WebSocket<TcpStream>) + Send + 'static) -> (Server, JoinHandle<()>) {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let port = listener.local_addr().unwrap().port();
    let stub = std::thread::spawn(move || {
        let ws = accept(listener.accept().unwrap().0).unwrap();
        drop(listener);
        serve(ws);
    });
    (local(port), stub)
}
