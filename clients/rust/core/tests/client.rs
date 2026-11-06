//! The wire client over a scripted server: the folds of `folds.json` through
//! connections, closes, and reconnects; parts; and the rules of slice 3 of
//! `docs/features/client-kit.md`.

#[allow(unused)]
mod common;
use helyx_client_core::Broken;
use helyx_client_core::client::{Client, MAX_IN_FLIGHT, Next, Output, Refusal};
use helyx_client_core::json::{Limits, WIRE, decode};
use helyx_client_core::parts::{self, FRAME_BYTES, PART_BYTES, REQUEST_BYTES, TooLarge};
use serde_json::{Value, json};
use std::collections::HashMap;
use std::path::PathBuf;

const CHALLENGE: &str =
    r#"{"type":"challenge","nonce":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="}"#;
const WELCOME: &str = r#"{"type":"welcome","protocol":3}"#;

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
    assert_eq!(sent(&hello), [json!({"type": "hello", "protocol": 3})]);
    let outputs = client.receive(WELCOME).unwrap();
    assert_eq!(outputs[0], Output::Welcome);
    outputs
}

fn observe(client: &Client) -> Value {
    let state = client.state("s1").unwrap();
    json!({
        "instance_id": state.instance_id, "seq": state.seq, "model": state.model,
        "running": state.running,
        "queue": {"steers": state.queue.steers, "follow_ups": state.queue.follow_ups,
                  "running": state.queue.running, "held": state.queue.held,
                  "waiting": state.queue.waiting},
        "asks": state.asks.iter().map(|a| a.ask_id.clone()).collect::<Vec<_>>(),
        "messages": state.messages.iter().map(|m| m.id.clone()).collect::<Vec<_>>(),
    })
}

fn matches(expected: &Value, actual: &Value) -> bool {
    match (expected, actual) {
        (Value::Object(e), Value::Object(a)) => e
            .iter()
            .all(|(k, v)| a.get(k).is_some_and(|got| matches(v, got))),
        (Value::Array(e), Value::Array(a)) => {
            e.len() == a.len() && e.iter().zip(a).all(|(e, a)| matches(e, a))
        }
        _ => expected == actual,
    }
}

/// Each fold of `folds.json` through the client: a connection up to each
/// close, a reconnect after it, and the subscribe with `after` that the
/// client sends at the welcome.
#[test]
fn the_folds_through_connections() {
    let path =
        PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../../test/fixtures/wire/folds.json");
    let fixture: Value = serde_json::from_str(&std::fs::read_to_string(path).unwrap()).unwrap();
    for case in fixture["cases"].as_array().unwrap() {
        let name = &case["name"];
        let mut client = Client::new(None);
        // The frames that the client sent and the fixture has not named yet.
        let mut unsent = sent(&welcomed(&mut client));
        let mut ids: HashMap<String, String> = HashMap::new();
        for step in case["steps"].as_array().unwrap() {
            if let Some(request) = step.get("client") {
                if unsent.is_empty() {
                    let session = request["params"]["session"].as_str().unwrap();
                    let frames = client.subscribe(session).unwrap();
                    unsent = frames
                        .iter()
                        .map(|t| serde_json::from_str(t).unwrap())
                        .collect();
                }
                let frame = unsent.remove(0);
                assert_eq!(frame["params"], request["params"], "{name}");
                assert_eq!(frame["op"], request["op"], "{name}");
                ids.insert(
                    request["id"].as_str().unwrap().into(),
                    frame["id"].as_str().unwrap().into(),
                );
            } else if let Some(server) = step.get("server") {
                let mut server = server.clone();
                if let Some(id) = server["id"].as_str() {
                    server["id"] = json!(ids[id]);
                }
                let outputs = client
                    .receive(&server.to_string())
                    .unwrap_or_else(|broken| panic!("{name}: {broken:?}"));
                // No ack in these folds: their seqs stay below 1,024.
                assert!(sent(&outputs).is_empty(), "{name}");
            } else if let Some(close) = step.get("close") {
                let code = close.as_u64().map(|c| c as u16);
                assert_eq!(client.closed(code), Next::Reconnect, "{name}");
                unsent = sent(&welcomed(&mut client));
            } else {
                let expect = &step["expect"];
                assert!(
                    matches(expect, &observe(&client)),
                    "{name}: {expect} against {}",
                    observe(&client)
                );
            }
        }
        assert!(unsent.is_empty(), "{name}");
    }
}

fn snapshot(seq: u64) -> Value {
    json!({"instance_id": "i1", "seq": seq, "messages": [], "more": false, "turn": null,
           "model": "fake/echo", "persisting": true, "context": null, "asks": [],
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
    assert_eq!(client.closed(Some(4408)), Next::Reconnect);
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
    assert_eq!(client.closed(None), Next::Stop);

    let mut client = following(4);
    assert!(client.receive(&notice(9)).is_err());
    // A broken connection takes no frame and sends no request.
    assert_eq!(client.receive(&notice(5)), Err(Broken("no connection")));
    assert_eq!(
        client.request("abort", json_params()),
        Err(Refusal::NotReady)
    );
    assert_eq!(client.closed(Some(1000)), Next::Stop);

    let mut client = Client::new(None);
    client.connect();
    client.receive(CHALLENGE).unwrap();
    let refused = r#"{"type":"refused","code":"protocol","server_protocol":4}"#;
    assert_eq!(client.receive(refused).unwrap(), [Output::Refused(4)]);
    assert_eq!(client.closed(Some(4426)), Next::Stop);
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
    // No resubscribe after a reconnect; the state stays.
    assert_eq!(client.closed(None), Next::Reconnect);
    assert_eq!(sent(&welcomed(&mut client)), Vec::<Value>::new());
    assert_eq!(client.state("s1").unwrap().seq, 4);
    // An event of the ended sub is a break.
    assert!(client.receive(&notice(5)).is_err());
    assert!(client.forget("s1"));
    assert_eq!(client.state("s1"), None);
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
    // The subscription has ended: the session is not followed, and a page
    // of it renews nothing; the host follows it again if it wants to.
    let mut client = following(4);
    client
        .receive(r#"{"type":"session_end","sub":"0","reason":"stopped"}"#)
        .unwrap();
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
    assert_eq!(client.subscribe("s1"), Err(Refusal::Subscribed));
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
    let frames = client.unsubscribe("s1").unwrap();
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
    assert_eq!(client.closed(None), Next::Reconnect);
    let frames = sent(&welcomed(&mut client));
    assert_eq!(frames.len(), MAX_IN_FLIGHT);
    // A refused subscribe ends the following and frees its place.
    let refused =
        r#"{"type":"res","id":"0","ok":false,"error":{"code":"session_not_found","text":"x"}}"#;
    client.receive(refused).unwrap();
    assert!(client.subscribe("s99").is_ok());
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

/// An unsubscribe whose reply comes after the `session_end` of its sub, and
/// after a new subscribe of the session: it ends only the sub that it named.
#[test]
fn a_late_unsubscribe_reply_ends_only_its_own_sub() {
    for new_reply_first in [false, true] {
        let mut client = following(4);
        let unsubscribe = id_of(&client.unsubscribe("s1").unwrap());
        client.receive(&stopped("0")).unwrap();
        let subscribe = id_of(&client.subscribe("s1").unwrap());
        let new = res(&subscribe, json!({"sub": "1", "snapshot": snapshot(10)}));
        let old = res(&unsubscribe, json!({}));
        let order = if new_reply_first {
            [new, old]
        } else {
            [old, new]
        };
        for frame in order {
            client.receive(&frame).unwrap();
        }
        // The new sub stays live and followed.
        assert_eq!(
            client.unsubscribe("s1").map(|_| ()),
            Ok(()),
            "{new_reply_first}"
        );
        let event = notice(11).replace(r#""sub":"0""#, r#""sub":"1""#);
        assert!(client.receive(&event).is_ok(), "{new_reply_first}");
        assert!(!client.forget("s1"), "{new_reply_first}");
    }
}

#[test]
fn forget_keeps_a_session_with_a_subscribe_on_the_way() {
    let mut client = following(4);
    client.unsubscribe("s1").unwrap();
    client.receive(&stopped("0")).unwrap();
    let subscribe = id_of(&client.subscribe("s1").unwrap());
    client.unsubscribe("s1").unwrap_err();
    assert!(!client.forget("s1"));
    client
        .receive(&res(
            &subscribe,
            json!({"sub": "1", "snapshot": snapshot(10)}),
        ))
        .unwrap();
    assert_eq!(client.state("s1").unwrap().seq, 10);
}

/// `instance_changed` renews the following once: a reconnect or an
/// unsubscribe in between does not leave it to a later `session_end`.
#[test]
fn a_renewal_ends_with_its_subscribe() {
    let history = |client: &mut Client| {
        let (id, _) = client.request("history", history_params()).unwrap();
        client.receive(&instance_changed(&id)).unwrap();
    };
    // A reconnect: the subscribe of the welcome renews; a later end stops.
    let mut client = following(4);
    history(&mut client);
    assert_eq!(client.closed(None), Next::Reconnect);
    let subscribe = sent(&welcomed(&mut client));
    let snap = json!({"sub": "0", "snapshot": snapshot(1)});
    client.receive(&res(&subscribe[0]["id"], snap)).unwrap();
    let outputs = client.receive(&stopped("0")).unwrap();
    assert!(sent(&outputs).is_empty());
    // An unsubscribe ends the renewal.
    let mut client = following(4);
    history(&mut client);
    let unsubscribe = id_of(&client.unsubscribe("s1").unwrap());
    client.receive(&res(&unsubscribe, json!({}))).unwrap();
    let subscribe = id_of(&client.subscribe("s1").unwrap());
    client
        .receive(&res(
            &subscribe,
            json!({"sub": "1", "snapshot": snapshot(8)}),
        ))
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
    assert_eq!(client.closed(None), Next::Reconnect);
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
    assert_eq!(client.unsubscribe("s1"), Err(Refusal::NotSubscribed));
}

/// A snapshot is the credit base: no ack, also at a multiple of 1,024.
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
    let unsubscribe = id_of(&client.unsubscribe("s1").unwrap());
    client.receive(&res(&unsubscribe, json!({}))).unwrap();
    let outputs = client.receive(&instance_changed(&history)).unwrap();
    assert!(sent(&outputs).is_empty());
    assert!(client.forget("s1"));
}

/// A subscribe of the host that waits for the end of the old subscription,
/// which it unsubscribed, goes at that end.
#[test]
fn a_subscribe_waiting_for_an_unsubscribed_end_goes_at_the_end() {
    let mut client = following(4);
    client.unsubscribe("s1").unwrap();
    assert_eq!(client.subscribe("s1"), Ok(vec![]));
    let end = r#"{"type":"session_end","sub":"0","reason":"crashed"}"#;
    let outputs = client.receive(end).unwrap();
    let again = json!({"session": "s1", "after": {"instance_id": "i1", "seq": 4}});
    assert_eq!(sent(&outputs)[0]["params"], again);
}

/// A refused subscribe ends the following and tells the host which session.
#[test]
fn a_refused_subscribe_unfollows_its_session() {
    let mut client = Client::new(None);
    welcomed(&mut client);
    let id = id_of(&client.subscribe("s1").unwrap());
    let busy = json!({"type": "res", "id": id, "ok": false,
                      "error": {"code": "busy", "text": "busy"}});
    let outputs = client.receive(&busy.to_string()).unwrap();
    let unfollowed = Output::Unfollowed {
        session: "s1".into(),
        code: "busy".into(),
        text: "busy".into(),
    };
    assert_eq!(outputs, [unfollowed]);
    assert!(client.subscribe("s1").is_ok());
}
