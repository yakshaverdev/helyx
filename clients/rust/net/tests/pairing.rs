//! The pairing of a client over TLS with the pin, the paired connection, the
//! refusals, and the deadline of a TLS connection
//! (`docs/features/client-kit.md`, "A remote server").

use base64::Engine;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use helyx_client_core::key::Key;
use helyx_client_net as net;
use net::socket::{WAITS, Waits};
use net::state::{State, Store};
use net::{Server, Shared};
use std::io::Read;
use std::net::TcpListener;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::channel;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use tungstenite::protocol::CloseFrame;
use tungstenite::protocol::frame::coding::CloseCode;

/// A margin for load: other worktrees run tests on this machine.
const LOAD_MARGIN: Duration = Duration::from_secs(3);

/// A store that keeps the state in memory and records whether it saved.
#[derive(Default)]
struct Memory {
    state: Mutex<Option<State>>,
    saved: AtomicBool,
}

impl Store for Memory {
    fn save(&self, state: &State, _replace: bool) -> Result<(), String> {
        *self.state.lock().unwrap() = Some(state.clone());
        self.saved.store(true, Ordering::SeqCst);
        Ok(())
    }

    fn load(&self, name: &str) -> Result<Option<State>, String> {
        Ok((self.state.lock().unwrap().clone()).filter(|state| state.name == name))
    }
}

/// A paired server at `port` with `name` and `key`.
fn paired(port: u16, name: &str, key: Key) -> Server {
    Server::paired(net::stub::state(port, name, key))
}

/// A close of `code` on `ws`.
fn close(ws: &mut tungstenite::WebSocket<net::stub::TlsStream>, code: u16) {
    ws.close(Some(CloseFrame {
        code: CloseCode::from(code),
        reason: "".into(),
    }))
    .unwrap();
    let _ = ws.flush();
}

/// The waits of a test that reconnects at once.
fn fast() -> Waits {
    Waits {
        pause: Duration::from_millis(10),
        poll: Duration::from_millis(20),
        ..WAITS
    }
}

#[test]
fn a_pairing_saves_the_state_before_the_first_frame() {
    let token = "boot-1";
    let name = "phone";
    let pin = net::stub::pin();
    let store = Arc::new(Memory::default());
    let thread_store = store.clone();
    let read_store = store.clone();
    let stub_pin = pin.clone();
    let (at_public, public) = channel();
    let (port, stub) = net::stub::tls_one(move |mut ws| {
        let public = net::stub::pairing(&mut ws, token, &stub_pin, name);
        // The state is saved at the welcome, before any later frame.
        let live = net::stub::next_text(&mut ws);
        assert!(live.contains("sessions.live"), "{live}");
        assert!(
            thread_store.saved.load(Ordering::SeqCst),
            "the state is saved before the first request"
        );
        at_public.send(public).unwrap();
        let saved = net::stub::next_text(&mut ws);
        assert!(saved.contains("sessions.saved"), "{saved}");
    });
    let link = net::stub::link(port, name, token);
    let shared = Arc::new(Mutex::new(Shared::new()));
    let (commands, receive) = channel();
    let thread_shared = shared.clone();
    let thread = std::thread::spawn(move || {
        net::run_pair_with(
            &link,
            store.as_ref(),
            &thread_shared,
            &receive,
            &|| {},
            fast(),
        )
    });
    let public = public.recv().unwrap();
    // The host is gone: the thread ends at the end of the connection.
    drop(commands);
    let _ = thread.join().unwrap();
    stub.join().unwrap();
    let state = read_store
        .state
        .lock()
        .unwrap()
        .clone()
        .expect("the saved state");
    assert_eq!(
        (state.host.as_str(), state.port, state.pin.as_str()),
        ("127.0.0.1", port, pin.as_str())
    );
    assert_eq!(state.name, name);
    assert_eq!(state.key.public_key(), public);
    // The connection that paired is the one that lists: the state is not
    // used for a second connection here.
    assert!(read_store.saved.load(Ordering::SeqCst));
}

#[test]
fn a_paired_connection_signs_the_new_nonce() {
    let name = "phone";
    let key = Key::generate();
    let public = key.public_key();
    let pin = net::stub::pin();
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let port = listener.local_addr().unwrap().port();
    let stub_public = public.clone();
    let stub = std::thread::spawn(move || {
        let config = net::stub::tls_config(&[&rustls::version::TLS13]);
        let mut ws = net::stub::tls_accept(listener.accept().unwrap().0, config.clone()).unwrap();
        let first = net::stub::paired(&mut ws, &pin, name, &stub_public);
        // The server drops the connection: the client connects again.
        drop(ws);
        let mut ws = net::stub::tls_accept(listener.accept().unwrap().0, config).unwrap();
        let mut nonce = [0u8; 32];
        nonce[0] = 1;
        let second = net::stub::paired_with(&mut ws, &nonce, &pin, name, &stub_public);
        (first, second)
    });
    let server = paired(port, name, key);
    let shared = Arc::new(Mutex::new(Shared::new()));
    let (commands, receive) = channel();
    let thread_shared = shared.clone();
    let thread = std::thread::spawn(move || {
        net::run_with(&server, None, &thread_shared, &receive, &|| {}, fast())
    });
    let (first, second) = stub.join().unwrap();
    // The signature of a later connection is of its own nonce.
    assert_ne!(first, second);
    drop(commands);
    let _ = thread.join().unwrap();
}

#[test]
fn a_wrong_pin_fails_before_any_frame() {
    let name = "phone";
    let (port, stub) = net::stub::tcp_one(|mut stream| {
        // The TLS handshake of the server: the client aborts on the pin, so
        // the server gets its certificate out and then an alert.
        let config = net::stub::tls_config(&[&rustls::version::TLS13]);
        let mut tls = rustls::StreamOwned::new(
            rustls::ServerConnection::new(config).unwrap(),
            stream.try_clone().unwrap(),
        );
        while tls.conn.is_handshaking() {
            if tls.conn.complete_io(&mut tls.sock).is_err() {
                break;
            }
        }
        assert!(tls.conn.is_handshaking(), "the handshake failed");
        // No WebSocket frame came: the first byte of a text frame is 0x81.
        let mut first = [0u8; 1];
        stream
            .set_read_timeout(Some(Duration::from_millis(500)))
            .unwrap();
        let n = stream.read(&mut first).unwrap_or(0);
        assert_eq!(n, 0, "a frame reached the stub");
    });
    let mut state = net::stub::state(port, name, Key::generate());
    state.pin = "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB".into();
    let shared = Mutex::new(Shared::new());
    let (_commands, receive) = channel();
    let line = net::run_with(
        &Server::paired(state),
        None,
        &shared,
        &receive,
        &|| {},
        fast(),
    );
    stub.join().unwrap();
    assert!(
        line.contains("the certificate is not the paired one"),
        "{line}"
    );
}

#[test]
fn a_server_of_tls_12_only_is_refused() {
    let (port, stub) = net::stub::tcp_one(|stream| {
        let config = net::stub::tls_config(&[&rustls::version::TLS12]);
        let mut tls =
            rustls::StreamOwned::new(rustls::ServerConnection::new(config).unwrap(), stream);
        let mut failed = false;
        while tls.conn.is_handshaking() {
            if tls.conn.complete_io(&mut tls.sock).is_err() {
                failed = true;
                break;
            }
        }
        assert!(failed || tls.conn.is_handshaking(), "the handshake held");
    });
    let shared = Mutex::new(Shared::new());
    let (_commands, receive) = channel();
    let line = net::run_with(
        &paired(port, "phone", Key::generate()),
        None,
        &shared,
        &receive,
        &|| {},
        fast(),
    );
    stub.join().unwrap();
    assert!(line.starts_with("could not connect"), "{line}");
    assert!(
        !line.contains("the certificate is not the paired one"),
        "{line}"
    );
}

#[test]
fn a_pairing_keeps_the_state_of_another_server_of_the_name() {
    let old = net::stub::state(1, "phone", Key::generate());
    let store = Memory::default();
    *store.state.lock().unwrap() = Some(old.clone());
    // No server listens: the refusal comes before a connection.
    let link = net::stub::link(2, "phone", "boot-1");
    let shared = Mutex::new(Shared::new());
    let (_commands, receive) = channel();
    let line = net::run_pair_with(&link, &store, &shared, &receive, &|| {}, fast());
    assert!(line.starts_with("the name phone is paired with"), "{line}");
    assert!(!store.saved.load(Ordering::SeqCst));
    assert_eq!(*store.state.lock().unwrap(), Some(old));
}

#[test]
fn a_refused_link_saves_nothing() {
    let token = "boot-1";
    let name = "phone";
    let (port, stub) = net::stub::tls_one(move |mut ws| {
        net::stub::challenge(&mut ws);
        let _hello = net::stub::next_text(&mut ws);
        close(&mut ws, 4401);
        let _ = ws.read();
    });
    let store = Memory::default();
    let link = net::stub::link(port, name, token);
    let shared = Mutex::new(Shared::new());
    let (_commands, receive) = channel();
    let line = net::run_pair_with(&link, &store, &shared, &receive, &|| {}, fast());
    stub.join().unwrap();
    assert_eq!(line, "the server refused the link");
    assert!(!store.saved.load(Ordering::SeqCst));
    assert!(store.state.lock().unwrap().is_none());
}

#[test]
fn a_revoked_app_stops_with_the_pair_again_line() {
    let name = "phone";
    let (port, stub) = net::stub::tls_one(move |mut ws| {
        net::stub::challenge(&mut ws);
        let _hello = net::stub::next_text(&mut ws);
        close(&mut ws, 4401);
        let _ = ws.read();
    });
    let shared = Mutex::new(Shared::new());
    let (_commands, receive) = channel();
    let line = net::run_with(
        &paired(port, name, Key::generate()),
        None,
        &shared,
        &receive,
        &|| {},
        fast(),
    );
    stub.join().unwrap();
    assert_eq!(
        line,
        "the server closed this app: another connection uses its name, or it was revoked"
    );
}

#[test]
fn the_welcome_deadline_covers_the_tls_handshake_and_the_upgrade() {
    // A server that completes the TLS handshake and then says nothing.
    let (port, stub) =
        net::stub::tls_one_with(net::stub::tls_config(&[&rustls::version::TLS13]), |_tls| {
            std::thread::sleep(Duration::from_secs(2))
        });
    let waits = Waits {
        welcome: Duration::from_millis(500),
        poll: Duration::from_millis(50),
        pause: Duration::ZERO,
        ..WAITS
    };
    let shared = Mutex::new(Shared::new());
    let (_commands, receive) = channel();
    let started = Instant::now();
    let line = net::run_with(
        &paired(port, "phone", Key::generate()),
        None,
        &shared,
        &receive,
        &|| {},
        waits,
    );
    stub.join().unwrap();
    assert!(line.ends_with("the upgrade took over 500 ms"), "{line}");
    assert!(
        started.elapsed() >= waits.welcome,
        "{:?}",
        started.elapsed()
    );
    assert!(
        started.elapsed() < waits.welcome + LOAD_MARGIN,
        "{:?}",
        started.elapsed()
    );

    // A server that sends no ClientHello answer: the same deadline ends the
    // TLS handshake.
    let (port, stub) = net::stub::tcp_one(|mut stream| {
        stream
            .set_read_timeout(Some(Duration::from_secs(2)))
            .unwrap();
        let mut buf = [0u8; 1_024];
        let _ = stream.read(&mut buf);
        std::thread::sleep(Duration::from_secs(1));
    });
    let started = Instant::now();
    let line = net::run_with(
        &paired(port, "phone", Key::generate()),
        None,
        &shared,
        &receive,
        &|| {},
        waits,
    );
    stub.join().unwrap();
    assert!(line.ends_with("the upgrade took over 500 ms"), "{line}");
    assert!(
        started.elapsed() >= waits.welcome,
        "{:?}",
        started.elapsed()
    );
}

#[test]
fn no_debug_form_holds_the_token_or_the_key() {
    let token = "boot-9d2c";
    let key = Key::generate();
    let link = net::stub::link(1, "phone", token);
    let server = Server::pairing(&link, key.clone());
    let state = net::stub::state(1, "phone", key.clone());
    let shared = Shared::new();
    let seed = URL_SAFE_NO_PAD.encode(key.seed());
    for shown in [
        format!("{server:?}"),
        format!("{state:?}"),
        format!("{shared:?}"),
        format!("{link:?}"),
    ] {
        assert!(!shown.contains(token), "{shown}");
        assert!(!shown.contains(&seed), "{shown}");
        assert!(!shown.contains(&key.public_key()), "{shown}");
    }
    // A local server shows no token either.
    let local = Server::local("127.0.0.1".parse().unwrap(), 1, token);
    assert!(!format!("{local:?}").contains(token));
}
