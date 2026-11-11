//! The wire client over a scripted server: the folds of `folds.json` through
//! connections, closes, and reconnects; parts; and the rules of slice 3 of
//! `docs/features/client-kit.md`.

#[allow(unused)]
mod common;
use common::{at, load, matches, observe};
use helyx_client_core::Broken;
use helyx_client_core::client::{Client, Follow, Hold, MAX_IN_FLIGHT, Next, Output, Refusal, Wait};
use helyx_client_core::json::{Json, Limits, WIRE, decode};
use helyx_client_core::parts::{self, FRAME_BYTES, PART_BYTES, REQUEST_BYTES, TooLarge};
use serde_json::{Value, json};
use std::collections::HashMap;

const CHALLENGE: &str =
    r#"{"type":"challenge","nonce":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="}"#;
const WELCOME: &str = r#"{"type":"welcome","protocol":9}"#;

/// The frames that the client sends among `outputs`, decoded.
fn sent(outputs: &[Output]) -> Vec<Value> {
    outputs
        .iter()
        .filter_map(|o| match o {
            Output::Send(text) => Some(serde_json::from_str(text).unwrap()),
            _ => None,
        })
        .collect()
}

/// A client past the handshake of a new connection, and what the welcome gave.
fn welcomed(client: &mut Client) -> Vec<Output> {
    client.connect();
    let hello = client.receive(CHALLENGE).unwrap();
    assert_eq!(sent(&hello), [json!({"type": "hello", "protocol": 9})]);
    let outputs = client.receive(WELCOME).unwrap();
    assert_eq!(outputs[0], Output::Welcome);
    outputs
}

/// The frames that the client sends among `outputs`, decoded by the core, so
/// a `seq` past 2^64 - 1 keeps its digits.
fn sent_frames(outputs: &[Output]) -> Vec<Json> {
    outputs
        .iter()
        .filter_map(|o| match o {
            Output::Send(text) => Some(decode(text).unwrap()),
            _ => None,
        })
        .collect()
}

/// `frame` with the `id` that `ids` maps its `id` to, when it has one.
fn with_id(frame: &Json, ids: &HashMap<String, String>) -> Json {
    match frame {
        Json::Object(pairs) => Json::Object(
            pairs
                .iter()
                .map(|(key, value)| match (key.as_str(), value.as_str()) {
                    ("id", Some(id)) => (key.clone(), Json::String(ids[id].clone())),
                    _ => (key.clone(), value.clone()),
                })
                .collect(),
        ),
        other => other.clone(),
    }
}

/// Each fold of `folds.json` through the client: a connection up to each
/// close, a reconnect after it, and the subscribe with `after` that the
/// client sends at the welcome.
#[test]
fn the_folds_through_connections() {
    let fixture = load("folds.json");
    for case in at(&fixture, "cases").as_array().unwrap() {
        let name = at(case, "name").as_str().unwrap();
        let mut client = Client::new(None);
        // The frames that the client sent and the fixture has not named yet.
        let mut unsent = sent_frames(&welcomed(&mut client));
        let mut ids: HashMap<String, String> = HashMap::new();
        for step in at(case, "steps").as_array().unwrap() {
            if let Some(request) = step.get("client") {
                let params = at(request, "params");
                if unsent.is_empty() {
                    let frames = client.subscribe(at(params, "session").as_str().unwrap());
                    unsent = frames.unwrap().iter().map(|t| decode(t).unwrap()).collect();
                }
                let frame = unsent.remove(0);
                let sent_params = at(&frame, "params");
                assert!(
                    matches(params, sent_params) && matches(sent_params, params),
                    "{name}: {} against {}",
                    sent_params.encode(),
                    params.encode()
                );
                assert_eq!(at(&frame, "op"), at(request, "op"), "{name}");
                ids.insert(
                    at(request, "id").as_str().unwrap().into(),
                    at(&frame, "id").as_str().unwrap().into(),
                );
            } else if let Some(server) = step.get("server") {
                let outputs = client
                    .receive(&with_id(server, &ids).encode())
                    .unwrap_or_else(|broken| panic!("{name}: {broken:?}"));
                // An ack at most, of the seq that the client holds: only the
                // fold past 2^64 - 1 crosses a multiple of 1,024.
                let held = &observe(client.state("s1").unwrap());
                for frame in sent_frames(&outputs) {
                    assert_eq!(at(&frame, "type").as_str(), Some("ack"), "{name}");
                    assert_eq!(at(&frame, "seq"), at(held, "seq"), "{name}");
                }
            } else if let Some(close) = step.get("close") {
                let code = close.as_u64().map(|c| c as u16);
                assert_eq!(client.closed(code).next, Next::Reconnect, "{name}");
                unsent = sent_frames(&welcomed(&mut client));
            } else {
                let (expect, held) = (at(step, "expect"), observe(client.state("s1").unwrap()));
                assert!(
                    matches(expect, &held),
                    "{name}: {} against {}",
                    expect.encode(),
                    held.encode()
                );
            }
        }
        assert!(unsent.is_empty(), "{name}");
    }
}

fn snapshot(seq: u64) -> Value {
    json!({"instance_id": "i1", "seq": seq, "messages": [], "turn": null,
           "model": "fake/echo", "persisting": true, "context": null, "asks": [], "ui_blocks": [], "activated": [],
           "queue": {"steers": 0, "follow_ups": 0, "running": 0, "held": 0, "waiting": 0},
           "usage": {"input": 0, "output": 0, "cache_read": 0, "cache_write": 0,
                     "cost": null, "unknown": false, "list": false}})
}

fn notice(seq: u64) -> String {
    json!({"type": "event", "sub": "0", "event": {"type": "notice", "session_id": "s1",
           "instance_id": "i1", "turn_id": null, "seq": seq, "data": {"text": "n"}}})
    .to_string()
}

/// A client that follows `s1` at seq `seq` on sub "0".
fn following(seq: u64) -> Client {
    let mut client = Client::new(None);
    welcomed(&mut client);
    client.subscribe("s1").unwrap();
    let res = json!({"type": "res", "id": "0", "ok": true,
                     "result": {"sub": "0", "snapshot": snapshot(seq)}});
    let outputs = client.receive(&res.to_string()).unwrap();
    assert_eq!(outputs, [Output::Changed("s1".into())]);
    client
}

#[test]
fn an_event_that_passes_the_cadence_sends_an_ack() {
    let mut client = following(1_022);
    assert!(sent(&client.receive(&notice(1_023)).unwrap()).is_empty());
    let outputs = client.receive(&notice(1_024)).unwrap();
    assert_eq!(
        sent(&outputs),
        [json!({"type": "ack", "sub": "0", "seq": 1_024})]
    );
}

#[test]
fn a_reconnect_after_a_slow_close_subscribes_with_after() {
    let mut client = following(4);
    client.receive(&notice(5)).unwrap();
    assert_eq!(client.closed(Some(4408)).next, Next::Reconnect);
    let resubscribe = sent(&welcomed(&mut client));
    assert_eq!(
        resubscribe,
        [json!({"type": "req", "id": "0", "op": "subscribe",
                "params": {"session": "s1", "after": {"instance_id": "i1", "seq": 5}}})]
    );
    // A replay that crosses 1,024 acks its last seq.
    let replay: Vec<Value> = (6..=1_030)
        .map(|seq| serde_json::from_str::<Value>(&notice(seq)).unwrap()["event"].clone())
        .collect();
    let res =
        json!({"type": "res", "id": "0", "ok": true, "result": {"sub": "0", "replay": replay}});
    let outputs = client.receive(&res.to_string()).unwrap();
    assert_eq!(
        sent(&outputs),
        [json!({"type": "ack", "sub": "0", "seq": 1_030})]
    );
    assert_eq!(client.state("s1").unwrap().seq, 1_030);
}

#[test]
fn a_close_before_the_welcome_or_after_a_break_stops() {
    let mut client = Client::new(None);
    client.connect();
    client.receive(CHALLENGE).unwrap();
    assert_eq!(client.closed(None).next, Next::Stop);

    let mut client = following(4);
    assert!(client.receive(&notice(9)).is_err());
    // A broken connection takes no frame and sends no request.
    assert_eq!(client.receive(&notice(5)), Err(Broken("no connection")));
    assert_eq!(
        client.request("abort", json_params()),
        Err(Refusal::NotReady)
    );
    assert_eq!(client.closed(Some(1000)).next, Next::Stop);

    let mut client = Client::new(None);
    client.connect();
    client.receive(CHALLENGE).unwrap();
    let refused = r#"{"type":"refused","code":"protocol","server_protocol":4}"#;
    assert_eq!(client.receive(refused).unwrap(), [Output::Refused(4)]);
    assert_eq!(client.closed(Some(4426)).next, Next::Stop);
    // Before any welcome, a failed open stops.
    assert_eq!(Client::new(None).closed(None).next, Next::Stop);
}

/// O1: one `challenge`, then one `welcome` or `refused`, then no more
/// handshake frame. A connection leaves the handshake at its answer, and a
/// frame after the answer is a frame of the link that follows.
#[test]
fn no_handshake_frame_follows_its_answer() {
    // After the welcome, a handshake frame is a frame after the handshake.
    let mut client = following(4);
    assert_eq!(client.receive(WELCOME), Err(Broken("frame type")));
    // A refused handshake ends the connection.
    let mut client = Client::new(None);
    client.connect();
    client.receive(CHALLENGE).unwrap();
    let refused = r#"{"type":"refused","code":"protocol","server_protocol":10}"#;
    assert_eq!(client.receive(refused).unwrap(), [Output::Refused(10)]);
    assert_eq!(client.receive(WELCOME), Err(Broken("no connection")));
    // A second challenge ends the handshake, and so does a nonce of the
    // wrong size.
    let mut client = Client::new(None);
    client.connect();
    client.receive(CHALLENGE).unwrap();
    assert!(client.receive(CHALLENGE).is_err());
    assert_eq!(client.receive(WELCOME), Err(Broken("no connection")));
    let mut client = Client::new(None);
    client.connect();
    assert!(
        client
            .receive(r#"{"type":"challenge","nonce":"AAAA"}"#)
            .is_err()
    );
    assert_eq!(client.receive(WELCOME), Err(Broken("no connection")));
}

/// After a welcome, every end reconnects but a break and a refusal: a
/// failed open, with no connection, and a reconnect that ends before its
/// own welcome; the welcome of an earlier connection is a fact that stays.
#[test]
fn after_a_welcome_a_failed_open_reconnects() {
    let mut client = following(4);
    assert_eq!(client.closed(None).next, Next::Reconnect);
    for _ in 0..2 {
        assert_eq!(client.closed(None).next, Next::Reconnect);
    }
    client.connect();
    client.receive(CHALLENGE).unwrap();
    assert_eq!(client.closed(None).next, Next::Reconnect);
    client.connect();
    client.receive(CHALLENGE).unwrap();
    let refused = r#"{"type":"refused","code":"protocol","server_protocol":10}"#;
    assert_eq!(client.receive(refused).unwrap(), [Output::Refused(10)]);
    assert_eq!(client.closed(Some(4426)).next, Next::Stop);
    let mut client = following(4);
    assert!(client.receive(&notice(9)).is_err());
    assert_eq!(client.closed(None).next, Next::Stop);
}

fn json_params() -> helyx_client_core::json::Json {
    decode(r#"{"session":"s1"}"#).unwrap()
}

#[test]
fn a_session_end_ends_the_following() {
    let mut client = following(4);
    let end = r#"{"type":"session_end","sub":"0","reason":"crashed"}"#;
    let outputs = client.receive(end).unwrap();
    assert_eq!(
        outputs,
        [Output::Ended {
            session: "s1".into(),
            crashed: true
        }]
    );
    // Held on this connection: no subscribe at the next input.
    let other = id_of(&client.subscribe("s2").unwrap());
    let outputs = client
        .receive(&res(&other, json!({"sub": "1", "snapshot": snapshot(1)})))
        .unwrap();
    assert!(sent(&outputs).is_empty());
    // The intent stays: a new connection subscribes it again, and the state
    // stays until the host forgets an unwanted session.
    assert_eq!(client.closed(None).next, Next::Reconnect);
    let again = sent(&welcomed(&mut client));
    assert_eq!(again[0]["params"]["session"], json!("s1"));
    assert_eq!(client.state("s1").unwrap().seq, 4);
    assert!(!client.forget("s1"));
    let refused = res_error(&again[0]["id"], "session_not_found");
    client.receive(&refused).unwrap();
    client.unsubscribe("s1");
    assert!(client.forget("s1"));
    assert_eq!(client.state("s1"), None);
    // An event of an ended sub is a break.
    let mut client = following(4);
    client.receive(&stopped("0")).unwrap();
    assert!(client.receive(&notice(5)).is_err());
    // A followed session is not forgotten.
    let mut client = following(4);
    assert!(!client.forget("s1"));
    assert!(client.state("s1").is_some());
}

#[test]
fn instance_changed_of_history_subscribes_again() {
    let history = |id: &str| {
        json!({"type": "res", "id": id, "ok": false,
               "error": {"code": "instance_changed", "text": "x"}})
        .to_string()
    };
    let params = || decode(r#"{"session":"s1","instance_id":"i1","before":"m1"}"#).unwrap();
    // The old subscription is live: subscribe again at its end.
    let mut client = following(4);
    let (id, _) = client.request("history", params()).unwrap();
    let outputs = client.receive(&history(&id)).unwrap();
    assert!(sent(&outputs).is_empty());
    let outputs = client
        .receive(r#"{"type":"session_end","sub":"0","reason":"stopped"}"#)
        .unwrap();
    let again = json!({"session": "s1", "after": {"instance_id": "i1", "seq": 4}});
    assert_eq!(sent(&outputs)[0]["params"], again);
    // The subscription has ended, and the wanted session is held: a page of
    // the instance of its state renews it, and the subscribe goes at once.
    let mut client = following(4);
    client
        .receive(r#"{"type":"session_end","sub":"0","reason":"stopped"}"#)
        .unwrap();
    let (id, _) = client.request("history", params()).unwrap();
    let outputs = client.receive(&history(&id)).unwrap();
    assert_eq!(sent(&outputs)[0]["params"], again);
    // A page of a session that the host does not follow renews nothing.
    let mut client = following(4);
    client.unsubscribe("s1");
    client.receive(&stopped("0")).unwrap();
    let (id, _) = client.request("history", params()).unwrap();
    let outputs = client.receive(&history(&id)).unwrap();
    assert!(sent(&outputs).is_empty());
    // A page of another instance than that of the state renews nothing.
    let mut client = following(4);
    let other = decode(r#"{"session":"s1","instance_id":"i0","before":"m1"}"#).unwrap();
    let (id, _) = client.request("history", other).unwrap();
    client.receive(&history(&id)).unwrap();
    let outputs = client
        .receive(r#"{"type":"session_end","sub":"0","reason":"stopped"}"#)
        .unwrap();
    assert!(sent(&outputs).is_empty());
}

#[test]
fn the_requests_in_flight_are_bounded() {
    let mut client = Client::new(None);
    // Before a welcome, the subscribe waits for it.
    assert_eq!(client.subscribe("s1"), Ok(vec![]));
    assert_eq!(sent(&welcomed(&mut client))[0]["op"], json!("subscribe"));
    // A statement again of the same intent changes nothing.
    assert_eq!(client.subscribe("s1"), Ok(vec![]));
    assert_eq!(
        client.request("subscribe", json_params()),
        Err(Refusal::Subscription)
    );
    for _ in 1..MAX_IN_FLIGHT {
        client.request("abort", json_params()).unwrap();
    }
    assert_eq!(client.request("abort", json_params()), Err(Refusal::Busy));
    // With no free place, a subscribe waits for a reply.
    assert_eq!(client.subscribe("s2"), Ok(vec![]));
    // A reply frees its place, and the waiting subscribe takes it.
    let outputs = client
        .receive(r#"{"type":"res","id":"1","ok":true,"result":{}}"#)
        .unwrap();
    assert_eq!(sent(&outputs)[0]["params"], json!({"session": "s2"}));
    assert_eq!(client.request("abort", json_params()), Err(Refusal::Busy));
    // A reply of no request in flight is a break.
    assert!(
        client
            .receive(r#"{"type":"res","id":"1","ok":true,"result":{}}"#)
            .is_err()
    );
}

#[test]
fn unsubscribe_ends_the_subscription_at_its_reply() {
    let mut client = following(4);
    let frames = client.unsubscribe("s1");
    let frame: Value = serde_json::from_str(&frames[0]).unwrap();
    assert_eq!(frame["params"], json!({"sub": "0"}));
    let id = frame["id"].as_str().unwrap().to_owned();
    client.receive(&notice(5)).unwrap();
    client
        .receive(&json!({"type": "res", "id": id, "ok": true, "result": {}}).to_string())
        .unwrap();
    assert!(client.receive(&notice(6)).is_err());
    assert_eq!(client.state("s1").unwrap().seq, 5);
}

/// The parts of `text` as the server sends them, of any size.
fn parts_of(text: String) -> Vec<String> {
    let pieces: Vec<&[u8]> = text.as_bytes().chunks(PART_BYTES).collect();
    let last = pieces.len() - 1;
    pieces
        .iter()
        .enumerate()
        .map(|(n, piece)| {
            json!({"type": "part", "n": n, "last": n == last, "data": base64_bytes(piece)})
                .to_string()
        })
        .collect()
}

#[test]
fn a_frame_in_parts_is_joined() {
    let mut client = following(4);
    let big = "x".repeat(2 * FRAME_BYTES);
    let event = json!({"type": "event", "sub": "0", "event": {"type": "notice", "session_id": "s1",
                       "instance_id": "i1", "turn_id": null, "seq": 5, "data": {"text": big}}});
    let parts = parts_of(event.to_string());
    assert_eq!(parts.len(), (event.to_string().len()).div_ceil(PART_BYTES));
    for part in &parts[..parts.len() - 1] {
        assert_eq!(client.receive(part).unwrap(), []);
    }
    let outputs = client.receive(parts.last().unwrap()).unwrap();
    assert_eq!(outputs, [Output::Changed("s1".into())]);
    assert_eq!(
        client.state("s1").unwrap().notices[0].len(),
        2 * FRAME_BYTES
    );
}

#[test]
fn a_broken_part_is_a_break() {
    let part = |n: u64, last: bool, data: &str| {
        json!({"type": "part", "n": n, "last": last, "data": data}).to_string()
    };
    let ok = "eyJ0eXBlIjoic2Vzc2lvbl9lbmQiLCJzdWIiOiIwIiwicmVhc29uIjoic3RvcHBlZCJ9";
    let cases: Vec<Vec<String>> = vec![
        vec![part(1, true, ok)],
        vec![part(0, false, "e30="), part(2, true, "e30=")],
        vec![part(0, true, "!!")],
        vec![json!({"type": "part", "n": 0, "last": true, "data": ok, "x": 1}).to_string()],
        vec![part(0, false, "e30="), notice(5)],
        vec![part(0, true, &base64(&part(0, true, ok)))],
        vec![part(0, true, &base64_bytes(&[0xff, 0xfe]))],
    ];
    for frames in cases {
        let mut client = following(4);
        let last = frames.len() - 1;
        for frame in &frames[..last] {
            client.receive(frame).unwrap();
        }
        assert!(client.receive(&frames[last]).is_err(), "{frames:?}");
    }
    let mut client = following(4);
    assert_eq!(client.receive(&part(0, true, ok)).unwrap().len(), 1);
}

#[test]
fn the_joined_bytes_are_bounded() {
    // Each frame fits 1,000 bytes; two parts of 600 bytes do not.
    let small = Limits {
        frame_bytes: 1_000,
        ..WIRE
    };
    let piece = base64(&"a".repeat(600));
    for (second, joined_ok) in [(400, true), (401, false)] {
        let mut client = Client::with_limits(None, small);
        welcomed(&mut client);
        let first = json!({"type": "part", "n": 0, "last": false, "data": piece}).to_string();
        let rest = base64(&"a".repeat(second));
        let last = json!({"type": "part", "n": 1, "last": true, "data": rest}).to_string();
        client.receive(&first).unwrap();
        let result = client.receive(&last);
        // 1,000 joined bytes of `a` are not JSON, so a join within the bound
        // breaks later, at the decode of the joined text.
        let broken = if joined_ok {
            Broken("json")
        } else {
            Broken("parts size")
        };
        assert_eq!(result, Err(broken), "{second}");
    }
}

fn base64(text: &str) -> String {
    base64_bytes(text.as_bytes())
}

fn base64_bytes(bytes: &[u8]) -> String {
    use base64::Engine;
    base64::engine::general_purpose::STANDARD.encode(bytes)
}

#[test]
fn a_request_goes_in_parts_over_one_frame() {
    assert_eq!(parts::split("a".repeat(FRAME_BYTES)).unwrap().len(), 1);
    let text = format!("\"{}\"", "a".repeat(FRAME_BYTES));
    let pieces = parts::split(text.clone()).unwrap();
    assert_eq!(pieces.len(), text.len().div_ceil(PART_BYTES));
    let joined: Vec<u8> = pieces
        .iter()
        .enumerate()
        .flat_map(|(n, part)| {
            let part: Value = serde_json::from_str(part).unwrap();
            assert_eq!(part["n"], json!(n));
            assert_eq!(part["last"], json!(n == pieces.len() - 1));
            use base64::Engine;
            base64::engine::general_purpose::STANDARD
                .decode(part["data"].as_str().unwrap())
                .unwrap()
        })
        .collect();
    assert_eq!(String::from_utf8(joined).unwrap(), text);
    assert!(parts::split("a".repeat(REQUEST_BYTES)).is_ok());
    assert_eq!(parts::split("a".repeat(REQUEST_BYTES + 1)), Err(TooLarge));
}

#[test]
fn at_most_16_sessions_are_followed_and_each_resubscribes() {
    let mut client = Client::new(None);
    welcomed(&mut client);
    for n in 0..MAX_IN_FLIGHT {
        client.subscribe(&format!("s{n}")).unwrap();
    }
    assert_eq!(client.subscribe("s99"), Err(Refusal::TooManySubscriptions));
    assert_eq!(client.closed(None).next, Next::Reconnect);
    let frames = sent(&welcomed(&mut client));
    assert_eq!(frames.len(), MAX_IN_FLIGHT);
    // A refused subscribe keeps its place; the host's unsubscribe frees it.
    client
        .receive(&res_error(&json!("0"), "session_not_found"))
        .unwrap();
    assert_eq!(client.subscribe("s99"), Err(Refusal::TooManySubscriptions));
    client.unsubscribe("s0");
    assert!(client.subscribe("s99").is_ok());
}

/// An error reply of `code` to the request `id`.
fn res_error(id: &Value, code: &str) -> String {
    json!({"type": "res", "id": id, "ok": false, "error": {"code": code, "text": "x"}}).to_string()
}

/// A `session_end` of `sub`, stopped.
fn stopped(sub: &str) -> String {
    json!({"type": "session_end", "sub": sub, "reason": "stopped"}).to_string()
}

/// The `instance_changed` error reply to the request `id`.
fn instance_changed(id: &str) -> String {
    json!({"type": "res", "id": id, "ok": false,
           "error": {"code": "instance_changed", "text": "x"}})
    .to_string()
}

/// The params of a `history` page of `s1` in instance `i1`.
fn history_params() -> helyx_client_core::json::Json {
    decode(r#"{"session":"s1","instance_id":"i1","before":"m1"}"#).unwrap()
}

fn res(id: &Value, result: Value) -> String {
    json!({"type": "res", "id": id, "ok": true, "result": result}).to_string()
}

/// The id of the one request among `frames`.
fn id_of(frames: &[String]) -> Value {
    let frame: Value = serde_json::from_str(&frames[0]).unwrap();
    frame["id"].clone()
}

/// An unsubscribe whose reply comes after the `session_end` of its sub: a
/// new subscribe of the session waits for that reply, which ends only the
/// sub that it named.
#[test]
fn a_late_unsubscribe_reply_ends_only_its_own_sub() {
    let mut client = following(4);
    let unsubscribe = id_of(&client.unsubscribe("s1"));
    client.receive(&stopped("0")).unwrap();
    // One request of a session in flight at a time.
    assert_eq!(client.subscribe("s1"), Ok(vec![]));
    let outputs = client.receive(&res(&unsubscribe, json!({}))).unwrap();
    let subscribe = sent(&outputs)[0]["id"].clone();
    client
        .receive(&res(
            &subscribe,
            json!({"sub": "1", "snapshot": snapshot(10)}),
        ))
        .unwrap();
    assert!(client.subscribed("s1"));
    let event = notice(11).replace(r#""sub":"0""#, r#""sub":"1""#);
    assert!(client.receive(&event).is_ok());
    assert!(!client.forget("s1"));
}

#[test]
fn forget_keeps_a_session_with_a_subscribe_on_the_way() {
    let mut client = following(4);
    let unsubscribe = id_of(&client.unsubscribe("s1"));
    client.receive(&stopped("0")).unwrap();
    client
        .receive(&res_error(&unsubscribe, "unknown_sub"))
        .unwrap();
    let subscribe = id_of(&client.subscribe("s1").unwrap());
    // With the subscribe in flight, the unsubscribe waits for its reply.
    assert!(client.unsubscribe("s1").is_empty());
    assert!(!client.forget("s1"));
    let outputs = client
        .receive(&res(
            &subscribe,
            json!({"sub": "1", "snapshot": snapshot(10)}),
        ))
        .unwrap();
    assert_eq!(client.state("s1").unwrap().seq, 10);
    // The reply gives a live sub of an unwanted session: it is unsubscribed.
    assert_eq!(sent(&outputs)[0]["params"], json!({"sub": "1"}));
}

/// A renewal lifts only the end of the instance that it names: the next
/// subscription is of a new instance, and its end holds, after a reconnect
/// and after an unsubscribe and a subscribe again.
#[test]
fn a_renewal_ends_with_its_subscribe() {
    let history = |client: &mut Client| {
        let (id, _) = client.request("history", history_params()).unwrap();
        client.receive(&instance_changed(&id)).unwrap();
    };
    let of_i2 = |seq: u64| {
        let mut snapshot = snapshot(seq);
        snapshot["instance_id"] = json!("i2");
        snapshot
    };
    // A reconnect: the subscribe of the welcome gets the new instance, and
    // its end holds.
    let mut client = following(4);
    history(&mut client);
    assert_eq!(client.closed(None).next, Next::Reconnect);
    let subscribe = sent(&welcomed(&mut client));
    let snap = json!({"sub": "0", "snapshot": of_i2(1)});
    client.receive(&res(&subscribe[0]["id"], snap)).unwrap();
    let outputs = client.receive(&stopped("0")).unwrap();
    assert!(sent(&outputs).is_empty());
    // An unsubscribe and a subscribe again: the same.
    let mut client = following(4);
    history(&mut client);
    let unsubscribe = id_of(&client.unsubscribe("s1"));
    client.receive(&res(&unsubscribe, json!({}))).unwrap();
    let subscribe = id_of(&client.subscribe("s1").unwrap());
    client
        .receive(&res(&subscribe, json!({"sub": "1", "snapshot": of_i2(8)})))
        .unwrap();
    let outputs = client.receive(&stopped("1")).unwrap();
    assert!(sent(&outputs).is_empty());
}

/// A renewal that finds 16 requests waiting subscribes at the next reply.
#[test]
fn a_renewal_waits_for_a_free_place() {
    let mut client = following(4);
    let (history, _) = client.request("history", history_params()).unwrap();
    for _ in 1..MAX_IN_FLIGHT {
        client.request("abort", json_params()).unwrap();
    }
    client.receive(&instance_changed(&history)).unwrap();
    client.request("abort", json_params()).unwrap();
    let outputs = client.receive(&stopped("0")).unwrap();
    assert!(sent(&outputs).is_empty());
    let outputs = client
        .receive(r#"{"type":"res","id":"2","ok":true,"result":{}}"#)
        .unwrap();
    let again = json!({"session": "s1", "after": {"instance_id": "i1", "seq": 4}});
    assert_eq!(sent(&outputs)[0]["params"], again);
}

/// An `instance_id` that takes a subscribe with `after` over the request
/// size: the client subscribes with no `after`, for a snapshot.
#[test]
fn a_huge_instance_id_subscribes_with_no_after() {
    let mut client = following(4);
    let mut big = snapshot(4);
    big["instance_id"] = json!("i".repeat(REQUEST_BYTES));
    let end = &stopped("0");
    client.receive(end).unwrap();
    let subscribe = id_of(&client.subscribe("s1").unwrap());
    for part in parts_of(res(&subscribe, json!({"sub": "1", "snapshot": big}))) {
        client.receive(&part).unwrap();
    }
    assert_eq!(client.closed(None).next, Next::Reconnect);
    let frames = sent(&welcomed(&mut client));
    assert_eq!(frames[0]["params"], json!({"session": "s1"}));
}

#[test]
fn the_frame_and_subscription_breaks() {
    // A frame over 1,048,576 bytes.
    let mut client = following(4);
    let text = format!("[\"{}\"]", "a".repeat(FRAME_BYTES - 4));
    // At the bound, the frame decodes; an array is not a frame.
    assert_eq!(client.receive(&text), Err(Broken("frame")));
    let mut client = following(4);
    let over = format!("[\"{}\"]", "a".repeat(FRAME_BYTES - 3));
    assert_eq!(client.receive(&over), Err(Broken("frame size")));
    // A subscribe reply with a sub that the connection holds.
    let mut client = following(4);
    let id = id_of(&client.subscribe("s2").unwrap());
    let reused = res(&id, json!({"sub": "0", "snapshot": snapshot(1)}));
    assert_eq!(client.receive(&reused), Err(Broken("subscribe sub")));
    // A session_end of a sub that the connection does not hold.
    let mut client = following(4);
    let end = &stopped("7");
    assert_eq!(client.receive(end), Err(Broken("end of no subscription")));
    // A request that is over the request size sends nothing.
    let mut client = following(4);
    let params = decode(&format!(
        r#"{{"session":"s1","text":"{}"}}"#,
        "a".repeat(REQUEST_BYTES)
    ))
    .unwrap();
    assert_eq!(client.request("prompt", params), Err(Refusal::TooLarge));
    for _ in 0..MAX_IN_FLIGHT {
        client.request("abort", json_params()).unwrap();
    }
    // A request goes only after the welcome.
    let mut client = Client::new(None);
    client.connect();
    client.receive(CHALLENGE).unwrap();
    assert_eq!(
        client.request("abort", json_params()),
        Err(Refusal::NotReady)
    );
    assert!(client.unsubscribe("s1").is_empty());
}

/// A snapshot is the credit base: no ack, also at a multiple of 1,024.
#[test]
fn no_debug_form_holds_the_token() {
    let mut client = Client::new(Some("tok-7f3a9".into()));
    assert!(!format!("{client:?}").contains("tok-7f3a9"));
    client.connect();
    assert!(!format!("{client:?}").contains("tok-7f3a9"));
}

#[test]
fn a_snapshot_is_not_acked() {
    let mut client = Client::new(None);
    welcomed(&mut client);
    let id = id_of(&client.subscribe("s1").unwrap());
    let outputs = client
        .receive(&res(&id, json!({"sub": "0", "snapshot": snapshot(2_048)})))
        .unwrap();
    assert!(sent(&outputs).is_empty());
}

/// A `history` reply of `instance_changed` after the host unsubscribed does
/// not follow the session again.
#[test]
fn a_late_instance_changed_keeps_an_unsubscribe() {
    let mut client = following(4);
    let (history, _) = client.request("history", history_params()).unwrap();
    let unsubscribe = id_of(&client.unsubscribe("s1"));
    client.receive(&res(&unsubscribe, json!({}))).unwrap();
    let outputs = client.receive(&instance_changed(&history)).unwrap();
    assert!(sent(&outputs).is_empty());
    assert!(client.forget("s1"));
}

/// A subscribe of the host that waits for its old subscription goes at the
/// `unsubscribe` reply; a `session_end` instead holds it until the host
/// states it again.
#[test]
fn a_subscribe_waiting_for_its_old_subscription() {
    let mut client = following(4);
    let unsubscribe = id_of(&client.unsubscribe("s1"));
    assert_eq!(client.subscribe("s1"), Ok(vec![]));
    let outputs = client.receive(&res(&unsubscribe, json!({}))).unwrap();
    let again = json!({"session": "s1", "after": {"instance_id": "i1", "seq": 4}});
    assert_eq!(sent(&outputs)[0]["params"], again);

    let mut client = following(4);
    let unsubscribe = id_of(&client.unsubscribe("s1"));
    assert_eq!(client.subscribe("s1"), Ok(vec![]));
    let end = r#"{"type":"session_end","sub":"0","reason":"crashed"}"#;
    let outputs = client.receive(end).unwrap();
    assert_eq!(
        outputs,
        [Output::Ended {
            session: "s1".into(),
            crashed: true
        }]
    );
    // Held: the host states it again, and it goes at the reply of the
    // unsubscribe, which the server answers `unknown_sub`.
    assert_eq!(client.subscribe("s1"), Ok(vec![]));
    let outputs = client
        .receive(&res_error(&unsubscribe, "unknown_sub"))
        .unwrap();
    assert_eq!(sent(&outputs)[0]["params"], again);
}

/// A refused subscribe leaves the intent, tells the host, and holds the
/// session until the host states it again: no request loop.
#[test]
fn a_refused_subscribe_keeps_the_intent_and_waits_for_the_host() {
    let mut client = Client::new(None);
    welcomed(&mut client);
    let id = id_of(&client.subscribe("s1").unwrap());
    let outputs = client.receive(&res_error(&id, "busy")).unwrap();
    let failed = Output::Failed {
        session: "s1".into(),
        op: "subscribe",
        code: "busy".into(),
        text: "x".into(),
    };
    assert_eq!(outputs, [failed]);
    // No retry at the next input.
    let other = id_of(&client.subscribe("s2").unwrap());
    let outputs = client
        .receive(&res(&other, json!({"sub": "0", "snapshot": snapshot(1)})))
        .unwrap();
    assert!(sent(&outputs).is_empty());
    // The host states it again: the subscribe goes.
    assert_eq!(client.subscribe("s1").unwrap().len(), 1);
    // A new connection reconciles every wanted session.
    assert_eq!(client.closed(None).next, Next::Reconnect);
    assert_eq!(sent(&welcomed(&mut client)).len(), 2);
}

/// An `unsubscribe` answered with an error leaves the subscription live:
/// the host is told, `subscribed` says so, and the events still apply.
#[test]
fn a_refused_unsubscribe_reports_the_live_subscription() {
    let mut client = following(4);
    let id = id_of(&client.unsubscribe("s1"));
    let outputs = client.receive(&res_error(&id, "busy")).unwrap();
    let failed = Output::Failed {
        session: "s1".into(),
        op: "unsubscribe",
        code: "busy".into(),
        text: "x".into(),
    };
    assert_eq!(outputs, [failed]);
    assert!(client.subscribed("s1"));
    assert!(!client.forget("s1"));
    let outputs = client.receive(&notice(5)).unwrap();
    assert!(sent(&outputs).is_empty());
    assert_eq!(client.state("s1").unwrap().seq, 5);
    // The host states it again: the unsubscribe goes.
    assert_eq!(client.unsubscribe("s1").len(), 1);
    // `unknown_sub`: the server holds the sub no more; a frame of it still
    // on the way is dropped, and nothing goes again.
    let mut client = following(4);
    let id = id_of(&client.unsubscribe("s1"));
    let gone = res_error(&id, "unknown_sub");
    assert_eq!(client.receive(&gone).unwrap(), []);
    assert!(!client.subscribed("s1"));
    assert!(client.forget("s1"));
    assert_eq!(client.receive(&notice(5)).unwrap(), []);
    assert_eq!(client.receive(&stopped("0")).unwrap(), []);
}

/// The host stops following a session with no live subscription: before a
/// welcome, nothing goes, and the next connection subscribes none.
#[test]
fn an_unsubscribe_with_no_live_subscription_is_kept() {
    let mut client = following(4);
    assert_eq!(client.closed(None).next, Next::Reconnect);
    assert!(client.unsubscribe("s1").is_empty());
    assert!(sent(&welcomed(&mut client)).is_empty());
    assert!(client.forget("s1"));
}

/// A renewal ends only the hold of an ended subscription, not that of a
/// refused subscribe.
#[test]
fn a_renewal_does_not_lift_a_refused_hold() {
    let mut client = following(4);
    assert_eq!(client.closed(None).next, Next::Reconnect);
    let again = sent(&welcomed(&mut client));
    let (history, _) = client.request("history", history_params()).unwrap();
    client.receive(&res_error(&again[0]["id"], "busy")).unwrap();
    let outputs = client.receive(&instance_changed(&history)).unwrap();
    assert!(sent(&outputs).is_empty());
    assert_eq!(client.follow("s1"), Some(Follow::Held(Hold::Refused)));
}

/// The server holds 16 subscriptions of a connection: a subscribe waits while
/// 16 live, an unsubscribed one among them, until a reply frees a place.
#[test]
fn a_subscribe_waits_for_a_place_among_the_live_subscriptions() {
    let mut client = Client::new(None);
    welcomed(&mut client);
    for n in 0..MAX_IN_FLIGHT {
        let session = format!("s{n:02}");
        let id = id_of(&client.subscribe(&session).unwrap());
        let reply = json!({"sub": format!("{n}"), "snapshot": snapshot(1)});
        client.receive(&res(&id, reply)).unwrap();
    }
    let unsubscribe = id_of(&client.unsubscribe("s05"));
    assert_eq!(client.subscribe("a"), Ok(vec![]));
    let outputs = client.receive(&res(&unsubscribe, json!({}))).unwrap();
    assert_eq!(sent(&outputs)[0]["params"], json!({"session": "a"}));
}

/// A statement again at the cap is taken; a 17th session is not.
#[test]
fn a_restatement_at_the_cap_is_taken() {
    let mut client = Client::new(None);
    welcomed(&mut client);
    for n in 0..MAX_IN_FLIGHT {
        client.subscribe(&format!("s{n}")).unwrap();
    }
    assert_eq!(client.subscribe("s0"), Ok(vec![]));
    assert_eq!(client.subscribe("s16"), Err(Refusal::TooManySubscriptions));
}

/// A subscribe reply with a sub id that the server ended (`unknown_sub`) is a
/// break: a sub id is unique on the connection.
#[test]
fn a_reused_gone_sub_id_is_a_break() {
    let mut client = following(4);
    let unsubscribe = id_of(&client.unsubscribe("s1"));
    client
        .receive(&res_error(&unsubscribe, "unknown_sub"))
        .unwrap();
    let subscribe = id_of(&client.subscribe("s1").unwrap());
    let reused = res(&subscribe, json!({"sub": "0", "snapshot": snapshot(10)}));
    assert_eq!(client.receive(&reused), Err(Broken("subscribe sub")));
}

/// A session id whose subscribe cannot fit a request is refused at once.
#[test]
fn a_session_id_over_the_request_size_is_refused() {
    let mut client = Client::new(None);
    welcomed(&mut client);
    let huge = "s".repeat(REQUEST_BYTES);
    assert_eq!(client.subscribe(&huge), Err(Refusal::TooLarge));
    assert_eq!(client.state(&huge), None);
}

/// An error answer to a statement that the host made again since holds
/// nothing and is not told: the `busy` of an `unsubscribe` that comes after
/// the `session_end` of its sub, and after the host followed the session
/// again, lets the subscribe go (the judgement of 2026-11-07, item 1).
#[test]
fn a_late_refusal_holds_no_follow_stated_after_it() {
    let mut client = following(4);
    let unsubscribe = id_of(&client.unsubscribe("s1"));
    client.receive(&stopped("0")).unwrap();
    assert_eq!(client.subscribe("s1"), Ok(vec![]));
    assert_eq!(client.follow("s1"), Some(Follow::Waiting(Wait::Ending)));
    let outputs = client.receive(&res_error(&unsubscribe, "busy")).unwrap();
    assert!(!outputs.iter().any(|o| matches!(o, Output::Failed { .. })));
    let again = json!({"session": "s1", "after": {"instance_id": "i1", "seq": 4}});
    assert_eq!(sent(&outputs)[0]["params"], again);
    assert_eq!(client.follow("s1"), Some(Follow::Subscribing));
    // The same `busy` with the sub still live: the follow stated after it
    // goes on with that sub, and its end holds as any end.
    let mut client = following(4);
    let unsubscribe = id_of(&client.unsubscribe("s1"));
    assert_eq!(client.subscribe("s1"), Ok(vec![]));
    let (history, _) = client.request("history", history_params()).unwrap();
    let outputs = client.receive(&res_error(&unsubscribe, "busy")).unwrap();
    assert!(outputs.is_empty());
    assert_eq!(client.follow("s1"), Some(Follow::Live));
    client.receive(&stopped("0")).unwrap();
    assert_eq!(client.follow("s1"), Some(Follow::Held(Hold::Ended)));
    let outputs = client.receive(&instance_changed(&history)).unwrap();
    assert_eq!(sent(&outputs)[0]["params"], again);
}

/// A refused `unsubscribe` of a session that the host forgot meanwhile holds
/// nothing and is not told: its sub had ended.
#[test]
fn a_forgotten_session_gets_no_hold() {
    let mut client = following(4);
    let unsubscribe = id_of(&client.unsubscribe("s1"));
    client.receive(&stopped("0")).unwrap();
    assert!(client.forget("s1"));
    let outputs = client.receive(&res_error(&unsubscribe, "busy")).unwrap();
    assert_eq!(outputs, []);
    assert!(format!("{client:?}").contains("answers: {}"));
}

/// A server never gives a sub id again on a connection (its `next_sub` only
/// grows), so the client takes each reply as of its own sub: a server that
/// gives one again breaks the contract, and the next frame of the sub is a
/// break.
#[test]
fn a_sub_id_given_again_is_a_contract_break() {
    let mut client = following(4);
    let unsubscribe = id_of(&client.unsubscribe("s1"));
    client.receive(&stopped("0")).unwrap();
    let s2 = id_of(&client.subscribe("s2").unwrap());
    client
        .receive(&res(&s2, json!({"sub": "0", "snapshot": snapshot(1)})))
        .unwrap();
    client.receive(&res(&unsubscribe, json!({}))).unwrap();
    assert!(!client.subscribed("s2"));
    assert_eq!(
        client.receive(&notice(2)),
        Err(Broken("event of no subscription"))
    );
}

/// The state of a follow, derived on read: each reason why no subscription
/// of a followed session lives, and the sessions that hold a place of the
/// 16 that the host does not want (the judgement of 2026-11-07, item 2).
#[test]
fn follow_tells_why_a_followed_session_has_no_subscription() {
    let mut client = Client::new(None);
    assert_eq!(client.follow("s00"), None);
    assert_eq!(client.subscribe("s00"), Ok(vec![]));
    assert_eq!(
        client.follow("s00"),
        Some(Follow::Waiting(Wait::Connection))
    );
    let subscribe = sent(&welcomed(&mut client));
    assert_eq!(client.follow("s00"), Some(Follow::Subscribing));
    let reply = json!({"sub": "0", "snapshot": snapshot(1)});
    client.receive(&res(&subscribe[0]["id"], reply)).unwrap();
    assert_eq!(client.follow("s00"), Some(Follow::Live));
    for n in 1..MAX_IN_FLIGHT {
        let session = format!("s{n:02}");
        let id = id_of(&client.subscribe(&session).unwrap());
        let reply = json!({"sub": format!("{n}"), "snapshot": snapshot(1)});
        client.receive(&res(&id, reply)).unwrap();
    }
    // The server refuses the unsubscribe of s05: its sub lives on, and a
    // new session waits for its place.
    let unsubscribe = id_of(&client.unsubscribe("s05"));
    assert_eq!(client.follow("s05"), Some(Follow::Unwanted));
    let outputs = client.receive(&res_error(&unsubscribe, "busy")).unwrap();
    assert!(matches!(&outputs[..], [Output::Failed { .. }]));
    assert_eq!(client.subscribe("a"), Ok(vec![]));
    let unwanted = vec!["s05".to_owned()];
    assert_eq!(
        client.follow("a"),
        Some(Follow::Waiting(Wait::Places { unwanted }))
    );
    // The host states it again: the place frees at the reply.
    let unsubscribe = id_of(&client.unsubscribe("s05"));
    let outputs = client.receive(&res(&unsubscribe, json!({}))).unwrap();
    let subscribe = sent(&outputs).remove(0);
    assert_eq!(subscribe["params"], json!({"session": "a"}));
    // A refused subscribe holds; 16 requests in flight make a wait.
    client
        .receive(&res_error(&subscribe["id"], "session_not_found"))
        .unwrap();
    assert_eq!(client.follow("a"), Some(Follow::Held(Hold::Refused)));
    client.unsubscribe("s01");
    for _ in 1..MAX_IN_FLIGHT {
        client.request("abort", json_params()).unwrap();
    }
    assert_eq!(client.subscribe("a"), Ok(vec![]));
    assert_eq!(client.follow("a"), Some(Follow::Waiting(Wait::Requests)));
}

/// `forget` and a new follow do not reuse the number of a statement: a late
/// answer to a request of the forgotten session holds nothing.
#[test]
fn a_late_answer_to_a_forgotten_session_holds_no_new_follow() {
    let mut client = following(4);
    assert_eq!(client.subscribe("s1"), Ok(vec![]));
    let unsubscribe = id_of(&client.unsubscribe("s1"));
    client.receive(&stopped("0")).unwrap();
    assert!(client.forget("s1"));
    for _ in 0..3 {
        assert_eq!(client.subscribe("s1"), Ok(vec![]));
    }
    let outputs = client.receive(&res_error(&unsubscribe, "busy")).unwrap();
    assert!(!outputs.iter().any(|o| matches!(o, Output::Failed { .. })));
    assert_eq!(sent(&outputs)[0]["params"], json!({"session": "s1"}));
    assert_eq!(client.follow("s1"), Some(Follow::Subscribing));
}

/// The subscribe reply after a renewal is the last answer of the server: the
/// end that the renewal lifted does not hold the live follow again.
#[test]
fn a_subscription_after_a_renewal_is_live() {
    let mut client = following(4);
    let (history, _) = client.request("history", history_params()).unwrap();
    client.receive(&stopped("0")).unwrap();
    assert_eq!(client.follow("s1"), Some(Follow::Held(Hold::Ended)));
    let outputs = client.receive(&instance_changed(&history)).unwrap();
    let subscribe = &sent(&outputs)[0]["id"];
    let snap = json!({"instance_id": "i2", "seq": 1, "messages": [],
        "turn": null, "model": "fake/echo", "persisting": true, "context": null, "asks": [], "ui_blocks": [], "activated": [],
        "queue": {"steers": 0, "follow_ups": 0, "running": 0, "held": 0, "waiting": 0},
        "usage": {"input": 0, "output": 0, "cache_read": 0, "cache_write": 0,
                  "cost": null, "unknown": false, "list": false}});
    let reply = json!({"sub": "1", "snapshot": snap});
    client.receive(&res(subscribe, reply)).unwrap();
    assert_eq!(client.follow("s1"), Some(Follow::Live));
    // An end of the new instance holds, and `forget` drops what is kept.
    client.receive(&stopped("1")).unwrap();
    assert_eq!(client.follow("s1"), Some(Follow::Held(Hold::Ended)));
    client.unsubscribe("s1");
    assert!(client.forget("s1"));
    let kept = format!("{client:?}");
    assert!(
        kept.contains("answers: {}") && kept.contains("replaced: {}"),
        "{kept}"
    );
}

/// The places of the 16 count the subscribes in flight: a session that the
/// host does not follow any more is named while its subscribe is on the way.
#[test]
fn a_wait_for_a_place_names_the_unfollowed_subscribes_in_flight() {
    let mut client = Client::new(None);
    welcomed(&mut client);
    for n in 0..MAX_IN_FLIGHT - 2 {
        let session = format!("s{n:02}");
        let id = id_of(&client.subscribe(&session).unwrap());
        let reply = json!({"sub": format!("{n}"), "snapshot": snapshot(1)});
        client.receive(&res(&id, reply)).unwrap();
    }
    for session in ["y", "x"] {
        assert_eq!(client.subscribe(session).unwrap().len(), 1);
        assert_eq!(client.unsubscribe(session), Vec::<String>::new());
    }
    assert_eq!(client.subscribe("a"), Ok(vec![]));
    let unwanted = vec!["x".to_owned(), "y".to_owned()];
    assert_eq!(
        client.follow("a"),
        Some(Follow::Waiting(Wait::Places { unwanted }))
    );
}

/// A refused subscribe of an older statement holds nothing: the subscribe of
/// the last statement goes.
#[test]
fn a_late_refused_subscribe_holds_no_later_follow() {
    let mut client = Client::new(None);
    welcomed(&mut client);
    let first = id_of(&client.subscribe("s1").unwrap());
    assert_eq!(client.unsubscribe("s1"), Vec::<String>::new());
    assert_eq!(client.subscribe("s1"), Ok(vec![]));
    let outputs = client.receive(&res_error(&first, "busy")).unwrap();
    assert!(!outputs.iter().any(|o| matches!(o, Output::Failed { .. })));
    assert_eq!(sent(&outputs)[0]["params"], json!({"session": "s1"}));
}

/// A sub id of the server over the request size, which no `unsubscribe` can
/// carry: the session is held with no report and no frame, once for each
/// statement of the host.
#[test]
fn a_sub_id_over_the_request_size_holds_with_no_frame() {
    let mut client = Client::new(None);
    welcomed(&mut client);
    let id = id_of(&client.subscribe("s1").unwrap());
    let sub = "s".repeat(REQUEST_BYTES);
    let reply = res(&id, json!({"sub": sub, "snapshot": snapshot(1)}));
    let mut outputs = vec![];
    for part in parts_of(reply) {
        outputs = client.receive(&part).unwrap();
    }
    assert_eq!(outputs, [Output::Changed("s1".into())]);
    for _ in 0..2 {
        assert_eq!(client.unsubscribe("s1"), Vec::<String>::new());
        assert!(client.subscribed("s1"));
        assert_eq!(client.follow("s1"), Some(Follow::Unwanted));
    }
}

/// A `history` reply of an older instance does not erase the replaced one:
/// the end of the replaced instance holds nothing, in both orders.
#[test]
fn a_page_of_an_older_instance_keeps_the_replaced_one() {
    let older = || decode(r#"{"session":"s1","instance_id":"i0","before":"m1"}"#).unwrap();
    let again = json!({"session": "s1", "after": {"instance_id": "i1", "seq": 4}});
    // The replies, then the end.
    let mut client = following(4);
    let (current, _) = client.request("history", history_params()).unwrap();
    let (old, _) = client.request("history", older()).unwrap();
    client.receive(&instance_changed(&current)).unwrap();
    client.receive(&instance_changed(&old)).unwrap();
    let outputs = client.receive(&stopped("0")).unwrap();
    assert_eq!(sent(&outputs)[0]["params"], again);
    assert_eq!(client.follow("s1"), Some(Follow::Subscribing));
    // The end, then the replies.
    let mut client = following(4);
    let (current, _) = client.request("history", history_params()).unwrap();
    let (old, _) = client.request("history", older()).unwrap();
    client.receive(&stopped("0")).unwrap();
    let outputs = client.receive(&instance_changed(&current)).unwrap();
    assert_eq!(sent(&outputs)[0]["params"], again);
    client.receive(&instance_changed(&old)).unwrap();
    assert_eq!(client.follow("s1"), Some(Follow::Subscribing));
}

/// A replay reply of the instance that a `history` reply named replaced
/// keeps it replaced: its end holds nothing.
#[test]
fn a_replay_of_a_replaced_instance_keeps_it_replaced() {
    let mut client = following(4);
    assert_eq!(client.closed(None).next, Next::Reconnect);
    let subscribe = sent(&welcomed(&mut client));
    let (history, _) = client.request("history", history_params()).unwrap();
    client.receive(&instance_changed(&history)).unwrap();
    let replay = json!({"sub": "1", "replay": []});
    client.receive(&res(&subscribe[0]["id"], replay)).unwrap();
    let outputs = client.receive(&stopped("1")).unwrap();
    assert_eq!(sent(&outputs)[0]["op"], json!("subscribe"));
}
