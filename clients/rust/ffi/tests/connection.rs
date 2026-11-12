//! The surface of the bindings, proven without Swift: the object of the
//! bindings against the stub server of the network layer, with a listener
//! implemented in Rust. It connects, lists the live sessions and the records
//! of the feed, sends a prompt and takes its reply, and ends the connection at
//! its drop.

use helyx_client_core::json::{Json, decode};
use helyx_client_ffi::{Connection, NetError, NetListener, RequestState, Snapshot, Status};
use helyx_client_net::stub;
use std::net::TcpStream;
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

/// The `id` of a request of the client.
fn id_of(frame: &Json) -> String {
    frame.get("id").and_then(Json::as_str).unwrap().to_owned()
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

/// One `record` of the records feed, as the server sends it.
fn record(session: &str, title: &str, status: &str, parent: Option<&str>) -> String {
    let parent = match parent {
        None => "null".to_owned(),
        Some(id) => format!(r#"{{"session":"{id}","kind":"child"}}"#),
    };
    format!(
        r#"{{"session":"{session}","owner":{{"id":"u1","name":"ada"}},"project":null,"title":"{title}","labels":[],"visibility":"private","archived":false,"created_at":1,"updated_at":1,"cwd":"/r/{session}","model":"fake/echo","prompt":"the prompt","active_at":1,"parent":{parent},"status":"{status}"}}"#
    )
}

/// The reply of the server to `sessions.live`: one session, `s1`.
fn live(id: &str) -> String {
    format!(
        r#"{{"type":"res","id":"{id}","ok":true,"result":{{"sessions":[{{"id":"s1","instance_id":"i1","cwd":"/r","model":"fake/echo","status":"idle"}}]}}}}"#
    )
}

/// The request of the client, as its frame.
fn request(ws: &mut WebSocket<TcpStream>) -> Json {
    let text = stub::next_text(ws);
    decode(&text).unwrap()
}

#[test]
fn the_surface_connects_lists_and_takes_a_result() {
    let (changes, snapshots) = channel();
    let listener = Arc::new(Collect {
        changes: Mutex::new(changes),
    });
    let (server, stub) = stub::one(|mut ws| {
        stub::welcome(&mut ws, "tok-q4");
        // The requests of the welcome: the records subscription, refused on
        // a server with no Hub, then the first page of the saved sessions,
        // and the live sessions that the refusal allows.
        let records = request(&mut ws);
        assert_eq!(
            records.get("op").and_then(Json::as_str),
            Some("records.subscribe")
        );
        error(&mut ws, &id_of(&records), "unknown_op");
        let saved = request(&mut ws);
        assert_eq!(
            saved.get("op").and_then(Json::as_str),
            Some("sessions.saved")
        );
        ok(&mut ws, &id_of(&saved), r#"{"items":[],"next":null}"#);
        let asked = request(&mut ws);
        assert_eq!(
            asked.get("op").and_then(Json::as_str),
            Some("sessions.live")
        );
        ws.send(Message::text(live(&id_of(&asked)))).unwrap();
        // The live list that the host asks for again.
        let asked = request(&mut ws);
        assert_eq!(
            asked.get("op").and_then(Json::as_str),
            Some("sessions.live")
        );
        ws.send(Message::text(live(&id_of(&asked)))).unwrap();
        // The prompt of the host, answered `ok`.
        let prompt = request(&mut ws);
        assert_eq!(prompt.get("op").and_then(Json::as_str), Some("prompt"));
        assert_eq!(
            prompt.get("params"),
            Some(&decode(r#"{"session":"s1","text":"a text"}"#).unwrap())
        );
        ok(&mut ws, &id_of(&prompt), "{}");
        // The drop of the object ends the connection: the socket goes.
        assert!(ws.read().is_err());
    });
    let connection = Connection::new(
        server.address.to_string(),
        server.port,
        server.token.clone(),
        listener.clone(),
    )
    .unwrap();
    // Connect and list the live sessions: the reply of the welcome. The
    // server has no Hub, so its list is the live one.
    let first = until(&snapshots, |snapshot| !snapshot.live.is_empty());
    assert_eq!(first.live[0].id, "s1");
    assert_eq!(first.line, "connected");
    assert!(!first.records_feed);
    assert!(first.records.is_empty());
    assert!(!first.records_more);
    // The method of the live list, and its result.
    connection.live_sessions().unwrap();
    until(&snapshots, |snapshot| {
        (snapshot.requests.iter())
            .filter(|line| line.op == "sessions.live" && line.state == RequestState::Ok)
            .count()
            >= 2
    });
    // An operation of the host, with its reply.
    connection.prompt("s1".into(), "a text".into()).unwrap();
    let answered = until(&snapshots, |snapshot| {
        (snapshot.requests.iter()).any(|line| line.op == "prompt" && line.state == RequestState::Ok)
    });
    let line = (answered.requests.iter())
        .find(|line| line.op == "prompt")
        .unwrap();
    assert_eq!(line.label, "prompt \"a text\"");
    // A prompt over its bound is refused before it goes.
    let over = "a".repeat(helyx_client_core::operation::MAX_TEXT_BYTES + 1);
    let refused = connection.prompt("s1".into(), over).unwrap_err();
    assert_eq!(refused.to_string(), "the text is over 4 MiB");
    // A model ref that is not one is refused before it goes.
    let refused = connection
        .set_model("s1".into(), "nope".into())
        .unwrap_err();
    assert_eq!(refused.to_string(), "not a model ref: use provider/model");
    // The drop ends the network thread, and the stub sees the end.
    drop(connection);
    stub.join().unwrap();
}

#[test]
fn the_snapshot_carries_the_records_feed() {
    let (changes, snapshots) = channel();
    let listener = Arc::new(Collect {
        changes: Mutex::new(changes),
    });
    let (server, stub) = stub::one(|mut ws| {
        stub::welcome(&mut ws, "tok-q4");
        let records = request(&mut ws);
        assert_eq!(
            records.get("op").and_then(Json::as_str),
            Some("records.subscribe")
        );
        let waiting = record("s1", "fix the build", "waiting", Some("p0"));
        let idle = record("s2", "", "idle", None);
        ok(
            &mut ws,
            &id_of(&records),
            &format!(r#"{{"records":[{waiting}],"more":true}}"#),
        );
        // A change: the idle session joins the list after the waiting one.
        ws.send(Message::text(format!(
            r#"{{"type":"record","change":{{"kind":"new","record":{idle}}}}}"#
        )))
        .unwrap();
        // The drop of the object ends the connection: the socket goes. The
        // saved page of the welcome is still on its way, so read until the
        // socket ends.
        while ws.read().is_ok() {}
    });
    let connection = Connection::new(
        server.address.to_string(),
        server.port,
        server.token.clone(),
        listener.clone(),
    )
    .unwrap();
    let snapshot = until(&snapshots, |snapshot| snapshot.records.len() == 2);
    assert!(snapshot.records_feed);
    assert!(snapshot.records_more);
    assert_eq!(snapshot.records[0].session, "s1");
    assert_eq!(snapshot.records[0].title, "fix the build");
    assert_eq!(snapshot.records[0].prompt, "the prompt");
    assert_eq!(snapshot.records[0].cwd, "/r/s1");
    assert_eq!(snapshot.records[0].model, "fake/echo");
    assert_eq!(snapshot.records[0].status, Status::Waiting);
    assert_eq!(snapshot.records[0].parent, Some("p0".into()));
    assert_eq!(snapshot.records[0].active_at, 1);
    assert_eq!(snapshot.records[1].session, "s2");
    assert_eq!(snapshot.records[1].status, Status::Idle);
    assert_eq!(snapshot.records[1].parent, None);
    drop(connection);
    stub.join().unwrap();
}
