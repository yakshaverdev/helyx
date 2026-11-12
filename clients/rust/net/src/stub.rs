//! The stub server of the tests of this layer, on the loopback: the plain
//! WebSocket of a local server, and the TLS 1.3 server of a remote one, with
//! a certificate of the test. The tests of the network crate and its bindings
//! drive the same stub.

// Each test binary uses a part of the helpers.
#![allow(dead_code)]

use crate::Server;
use crate::state::State;
use base64::Engine;
use base64::engine::general_purpose::STANDARD;
use helyx_client_core::handshake::{Token, proof, signature_text};
use helyx_client_core::json::{Json, decode};
use helyx_client_core::key::{Key, verify};
use helyx_client_core::link::Link;
use rustls::pki_types::{CertificateDer, PrivateKeyDer, PrivatePkcs8KeyDer};
use rustls::{ServerConfig, ServerConnection, StreamOwned};
use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::sync::Arc;
use std::thread::JoinHandle;
use tungstenite::{Message, WebSocket, accept};

/// The 32 bytes of the nonce of a handshake.
pub const NONCE: [u8; 32] = [0; 32];

/// The certificate of the TLS stub. It is a test certificate, made once with
/// `openssl req -new -x509` on an ECDSA P-256 key, with the name
/// `helyx-test`; its key is in `KEY_PEM`, and it protects nothing.
pub const CERT_PEM: &str = "-----BEGIN CERTIFICATE-----
MIIBYDCCAQagAwIBAgIURwFNLylxOIumN0UdoqG360C+lekwCgYIKoZIzj0EAwIw
FTETMBEGA1UEAwwKaGVseXgtdGVzdDAgFw0yNjExMTIwNjA4MTVaGA8yMTI2MTAx
OTA2MDgxNVowFTETMBEGA1UEAwwKaGVseXgtdGVzdDBZMBMGByqGSM49AgEGCCqG
SM49AwEHA0IABNNd/2ljKYNxmgt4wNowuNk/gnML/v3FeRwYvNpLrg/wpUaOL4Q7
JihLYtQSK/lI/xoprls77/f1OzSw4w/J/7OjMjAwMB0GA1UdDgQWBBQwrEDJIFFV
aB50RmvVSlUMeuAtlTAPBgNVHRMBAf8EBTADAQH/MAoGCCqGSM49BAMCA0gAMEUC
IBtA54t/fABCE84H2Y7LOTU2TsgjHZncl/BuvmAq0D0rAiEA9EIa91EO+WQlP0tz
FNOwWfl3gju+JeeKlRyCknInlYQ=
-----END CERTIFICATE-----";

/// The key of the test certificate, in PKCS#8.
pub const KEY_PEM: &str = "-----BEGIN PRIVATE KEY-----
MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgIMYcpQX/8mPb9WxY
CWMMEJulYXkNbh+QdirwxOYtxjuhRANCAATTXf9pYymDcZoLeMDaMLjZP4JzC/79
xXkcGLzaS64P8KVGji+EOyYoS2LUEiv5SP8aKa5bO+/39Ts0sOMPyf+z
-----END PRIVATE KEY-----";

/// The reply of the server to `sessions.live`, the first request of a
/// connection: one session, `s1`.
pub const LIVE: &str = r#"{"type":"res","id":"0","ok":true,"result":{"sessions":[{"id":"s1","instance_id":"i1","cwd":"/r","model":"fake/echo","status":"idle"}]}}"#;

/// The next text frame of the client: a ping or a pong is passed over.
pub fn next_text<S: Read + Write>(ws: &mut WebSocket<S>) -> String {
    loop {
        match ws.read().unwrap() {
            Message::Text(text) => return text.to_string(),
            _ => continue,
        }
    }
}

/// The `challenge` of the handshake, with the 32 bytes of `nonce`.
pub fn challenge_with<S: Read + Write>(ws: &mut WebSocket<S>, nonce: &[u8; 32]) {
    ws.send(Message::text(format!(
        r#"{{"type":"challenge","nonce":"{}"}}"#,
        STANDARD.encode(nonce)
    )))
    .unwrap();
}

/// The `challenge` of the handshake, with the 32 bytes of `proof`.
pub fn challenge<S: Read + Write>(ws: &mut WebSocket<S>) {
    challenge_with(ws, &NONCE);
}

/// The handshake of the server: the `hello` must carry the proof of `token`.
pub fn welcome<S: Read + Write>(ws: &mut WebSocket<S>, token: &str) {
    challenge(ws);
    let hello = next_text(ws);
    let expected = proof(token, &NONCE);
    assert_eq!(
        hello,
        format!(r#"{{"type":"hello","protocol":13,"proof":"{expected}"}}"#)
    );
    assert!(!hello.contains(token));
    welcome_frame(ws);
}

/// The `welcome` frame of the server.
pub fn welcome_frame<S: Read + Write>(ws: &mut WebSocket<S>) {
    ws.send(Message::text(r#"{"type":"welcome","protocol":13}"#))
        .unwrap();
}

/// The pairing handshake of the server: the `hello` must carry the proof of
/// `token` and the signature of the signature text with the public key that
/// it carries. Gives that public key.
pub fn pairing<S: Read + Write>(
    ws: &mut WebSocket<S>,
    token: &str,
    pin: &str,
    name: &str,
) -> String {
    pairing_with(ws, &NONCE, token, pin, name)
}

/// `pairing` with the 32 bytes of `nonce`, so a test holds the signature
/// text that it signs.
pub fn pairing_with<S: Read + Write>(
    ws: &mut WebSocket<S>,
    nonce: &[u8; 32],
    token: &str,
    pin: &str,
    name: &str,
) -> String {
    challenge_with(ws, nonce);
    let hello = decode(&next_text(ws)).unwrap();
    assert_eq!(text(&hello, "type"), "hello");
    assert_eq!(text(&hello, "role"), "client");
    assert_eq!(text(&hello, "client"), name);
    let pair = hello.get("pair").expect("a pairing hello has a pair");
    assert_eq!(text(pair, "proof"), proof(token, nonce));
    let public_key = text(pair, "public_key").to_owned();
    let signature = text(pair, "signature");
    assert!(
        verify(
            &public_key,
            &signature_text(pin, "client", name, nonce),
            signature
        ),
        "the signature of the pairing"
    );
    welcome_frame(ws);
    public_key
}

/// The handshake of a paired client: the `hello` must carry the signature of
/// the signature text with `public_key`. Gives the signature, so a test can
/// see that a later connection signs another nonce.
pub fn paired<S: Read + Write>(
    ws: &mut WebSocket<S>,
    pin: &str,
    name: &str,
    public_key: &str,
) -> String {
    paired_with(ws, &NONCE, pin, name, public_key)
}

/// `paired` with the 32 bytes of `nonce`.
pub fn paired_with<S: Read + Write>(
    ws: &mut WebSocket<S>,
    nonce: &[u8; 32],
    pin: &str,
    name: &str,
    public_key: &str,
) -> String {
    challenge_with(ws, nonce);
    let hello = decode(&next_text(ws)).unwrap();
    assert_eq!(text(&hello, "type"), "hello");
    assert_eq!(text(&hello, "role"), "client");
    assert_eq!(text(&hello, "client"), name);
    assert!(hello.get("pair").is_none(), "a paired hello has no pair");
    let signature = text(&hello, "signature").to_owned();
    assert!(
        verify(
            public_key,
            &signature_text(pin, "client", name, nonce),
            &signature
        ),
        "the signature of the paired client"
    );
    welcome_frame(ws);
    signature
}

fn text<'a>(value: &'a Json, key: &str) -> &'a str {
    value.get(key).and_then(Json::as_str).expect(key)
}

/// The server on the loopback at `port`.
pub fn local(port: u16) -> Server {
    Server::local("127.0.0.1".parse().unwrap(), port, "tok-q4")
}

/// The pin of the certificate of the TLS stub.
pub fn pin() -> String {
    crate::tls::pin(&cert()).expect("the DER of the test certificate")
}

/// The state of a paired client of the TLS stub at `port`.
pub fn state(port: u16, name: &str, key: Key) -> State {
    State {
        host: "127.0.0.1".into(),
        port,
        pin: pin(),
        name: name.into(),
        key,
    }
}

/// The link of a pairing with the TLS stub at `port`.
pub fn link(port: u16, name: &str, token: &str) -> Link {
    Link {
        host: "127.0.0.1".into(),
        port,
        token: Token::new(token.into()),
        pin: pin(),
        name: name.into(),
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

/// The TLS stream of the stub.
pub type TlsStream = StreamOwned<ServerConnection, TcpStream>;

/// The DER of a PEM of the test.
fn der(pem: &str) -> Vec<u8> {
    let body: String = (pem.lines())
        .filter(|line| !line.starts_with("-----"))
        .collect();
    STANDARD.decode(body).expect("the PEM of the test")
}

fn cert() -> Vec<u8> {
    der(CERT_PEM)
}

/// The server config of the TLS stub, with `versions` and the test
/// certificate.
pub fn tls_config(versions: &[&'static rustls::SupportedProtocolVersion]) -> Arc<ServerConfig> {
    let provider = Arc::new(rustls::crypto::ring::default_provider());
    let config = ServerConfig::builder_with_provider(provider)
        .with_protocol_versions(versions)
        .expect("the versions of the stub")
        .with_no_client_auth()
        .with_single_cert(
            vec![CertificateDer::from(cert())],
            PrivateKeyDer::Pkcs8(PrivatePkcs8KeyDer::from(der(KEY_PEM))),
        )
        .expect("the test certificate and key");
    Arc::new(config)
}

/// A stub that takes one TLS connection with `config`, completes the TLS
/// handshake, and runs `serve` on the stream: no listener remains for a
/// reconnect.
pub fn tls_one_with(
    config: Arc<ServerConfig>,
    serve: impl FnOnce(TlsStream) + Send + 'static,
) -> (u16, JoinHandle<()>) {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let port = listener.local_addr().unwrap().port();
    let stub = std::thread::spawn(move || {
        let stream = listener.accept().unwrap().0;
        drop(listener);
        let mut tls = StreamOwned::new(ServerConnection::new(config).unwrap(), stream);
        while tls.conn.is_handshaking() {
            tls.conn.complete_io(&mut tls.sock).unwrap();
        }
        serve(tls);
    });
    (port, stub)
}

/// A stub that takes one TLS 1.3 connection and runs `serve` on its
/// WebSocket.
pub fn tls_one(serve: impl FnOnce(WebSocket<TlsStream>) + Send + 'static) -> (u16, JoinHandle<()>) {
    tls_one_with(tls_config(&[&rustls::version::TLS13]), move |tls| {
        serve(accept(tls).unwrap())
    })
}

/// The text of a link of a pairing with the TLS stub at `port`, as the
/// server's `pair.create` writes it.
pub fn link_text(port: u16, name: &str, token: &str) -> String {
    use base64::engine::general_purpose::URL_SAFE_NO_PAD;
    let json = format!(
        r#"{{"a":"127.0.0.1:{port}","k":"client","n":"{name}","p":"{}","t":"{token}"}}"#,
        pin()
    );
    format!("helyx-pair:1:{}", URL_SAFE_NO_PAD.encode(json))
}

/// The TLS stream of `stream` with `config`, upgraded, and its WebSocket.
pub fn tls_accept(
    stream: TcpStream,
    config: Arc<ServerConfig>,
) -> Result<WebSocket<TlsStream>, String> {
    let mut tls = StreamOwned::new(
        ServerConnection::new(config).map_err(|e| e.to_string())?,
        stream,
    );
    while tls.conn.is_handshaking() {
        tls.conn
            .complete_io(&mut tls.sock)
            .map_err(|e| e.to_string())?;
    }
    accept(tls).map_err(|e| e.to_string())
}

/// A stub that takes one TCP connection and runs `serve` on it: for a test
/// whose TLS handshake must fail.
pub fn tcp_one(serve: impl FnOnce(TcpStream) + Send + 'static) -> (u16, JoinHandle<()>) {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let port = listener.local_addr().unwrap().port();
    let stub = std::thread::spawn(move || {
        let stream = listener.accept().unwrap().0;
        drop(listener);
        serve(stream);
    });
    (port, stub)
}
