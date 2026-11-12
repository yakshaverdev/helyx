//! The pairing of a client through the bindings: the link text, the storage
//! callback of the host, and a connection from the state that it saved
//! (`docs/features/client-kit.md`, "A remote server" and "Bindings for
//! Swift").

use helyx_client_core::key::Key;
use helyx_client_ffi::{Connection, NetError, NetListener, PairingStorage, Snapshot};
use helyx_client_net::state::State;
use helyx_client_net::stub;
use std::sync::mpsc::{Receiver, Sender, channel};
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tungstenite::{Message, WebSocket};

/// A margin for the reply of a stub on the loopback, in a test that other
/// worktrees load.
const LOAD_MARGIN: Duration = Duration::from_secs(10);

/// The listener of the test: it hands each snapshot to the test thread.
struct Collect {
    changes: Mutex<Sender<Snapshot>>,
}

impl NetListener for Collect {
    fn on_snapshot(&self, snapshot: Snapshot) -> Result<(), NetError> {
        let _ = self.changes.lock().unwrap().send(snapshot);
        Ok(())
    }
}

/// The storage of the test, as a host's keychain: the state as its bytes.
struct Storage {
    state: Mutex<Option<Vec<u8>>>,
    saved: Sender<()>,
}

impl PairingStorage for Storage {
    fn save(&self, state: Vec<u8>) -> Result<(), NetError> {
        *self.state.lock().unwrap() = Some(state);
        let _ = self.saved.send(());
        Ok(())
    }

    fn load(&self, _name: String) -> Result<Option<Vec<u8>>, NetError> {
        Ok(self.state.lock().unwrap().clone())
    }
}

/// The next snapshot that passes `done`.
fn until(changes: &Receiver<Snapshot>, done: impl Fn(&Snapshot) -> bool) -> Snapshot {
    loop {
        let snapshot = changes
            .recv_timeout(LOAD_MARGIN)
            .expect("the snapshot of the change");
        if done(&snapshot) {
            return snapshot;
        }
    }
}

/// The id of the request in `text`.
fn request_id(text: &str) -> String {
    let value = helyx_client_core::json::decode(text).expect("a request");
    value
        .get("id")
        .and_then(|id| id.as_str())
        .expect("an id")
        .to_owned()
}

/// Answers the requests of the welcome: the records subscription, refused on
/// a server with no Hub, the first page of the saved sessions, and the live
/// sessions that the refusal allows.
fn welcome_answers(ws: &mut WebSocket<stub::TlsStream>) {
    let records = stub::next_text(ws);
    assert!(records.contains("records.subscribe"), "{records}");
    let id = request_id(&records);
    ws.send(Message::text(format!(
        r#"{{"type":"res","id":"{id}","ok":false,"error":{{"code":"unknown_op","text":"no Hub"}}}}"#
    )))
    .unwrap();
    let saved = stub::next_text(ws);
    assert!(saved.contains("sessions.saved"), "{saved}");
    let id = request_id(&saved);
    ws.send(Message::text(format!(
        r#"{{"type":"res","id":"{id}","ok":true,"result":{{"items":[],"next":null}}}}"#
    )))
    .unwrap();
    let live = stub::next_text(ws);
    assert!(live.contains("sessions.live"), "{live}");
    let id = request_id(&live);
    ws.send(Message::text(format!(
        r#"{{"type":"res","id":"{id}","ok":true,"result":{{"sessions":[{{"id":"s1","instance_id":"i1","cwd":"/r","model":"fake/echo","status":"idle"}}]}}}}"#
    )))
    .unwrap();
}

#[test]
fn a_pairing_saves_the_state_through_the_callback() {
    let token = "boot-4c";
    let name = "phone";
    let pin = stub::pin();
    let stub_pin = pin.clone();
    let (changes, snapshots) = channel();
    let listener = Arc::new(Collect {
        changes: Mutex::new(changes),
    });
    let (saved, at_save) = channel();
    let storage = Arc::new(Storage {
        state: Mutex::new(None),
        saved,
    });
    let read_storage = storage.clone();
    let (port, stub_thread) = stub::tls_one(move |mut ws| {
        stub::pairing(&mut ws, token, &stub_pin, name);
        welcome_answers(&mut ws);
        // The drop of the object ends the connection: the socket goes.
        assert!(ws.read().is_err());
    });
    let connection = Connection::pair(
        stub::link_text(port, name, token),
        storage,
        listener.clone(),
    )
    .unwrap();
    at_save.recv_timeout(LOAD_MARGIN).expect("the save");
    let bytes = read_storage.state.lock().unwrap().clone().unwrap();
    let state = State::from_bytes(&String::from_utf8(bytes).unwrap()).unwrap();
    assert_eq!(
        (state.host.as_str(), state.port, state.pin.as_str()),
        ("127.0.0.1", port, pin.as_str())
    );
    assert_eq!(state.name, name);
    // The same connection lists the live sessions.
    let first = until(&snapshots, |snapshot| !snapshot.live.is_empty());
    assert_eq!(first.live[0].id, "s1");
    assert_eq!(first.line, "connected");
    drop(connection);
    stub_thread.join().unwrap();
}

#[test]
fn a_paired_connection_starts_from_the_saved_state() {
    let name = "phone";
    let key = Key::generate();
    let public = key.public_key();
    let pin = stub::pin();
    let (changes, snapshots) = channel();
    let listener = Arc::new(Collect {
        changes: Mutex::new(changes),
    });
    let (port, stub_thread) = stub::tls_one(move |mut ws| {
        stub::paired(&mut ws, &pin, name, &public);
        welcome_answers(&mut ws);
        assert!(ws.read().is_err());
    });
    let state = stub::state(port, name, key);
    let connection = Connection::paired(state.to_bytes(), listener.clone()).unwrap();
    let first = until(&snapshots, |snapshot| !snapshot.live.is_empty());
    assert_eq!(first.live[0].id, "s1");
    drop(connection);
    stub_thread.join().unwrap();
}

#[test]
fn a_link_that_does_not_parse_and_a_state_that_is_not_valid_are_refused() {
    let (changes, _snapshots) = channel();
    let listener = Arc::new(Collect {
        changes: Mutex::new(changes),
    });
    let storage = Arc::new(Storage {
        state: Mutex::new(None),
        saved: channel().0,
    });
    let refused = Connection::pair("helyx-pair:1:!!!!".into(), storage, listener.clone())
        .err()
        .unwrap();
    assert_eq!(refused.to_string(), "the link body is not base64url");
    let refused = Connection::paired(b"not json".to_vec(), listener)
        .err()
        .unwrap();
    assert_eq!(refused.to_string(), "the state is not valid");
}
