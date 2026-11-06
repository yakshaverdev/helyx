//! Runs the wire conformance fixtures of `test/fixtures/wire/` against the
//! client core: `server_frames.json` against the frame checks and the
//! handshake, `folds.json` against the fold.

use helyx_client_core::Broken;
use helyx_client_core::fold::State;
use helyx_client_core::frame::{self, OPS, Reply, ServerFrame};
use helyx_client_core::handshake::{Handshake, PROTOCOL, Step};
use serde_json::{Value, json};
use std::path::PathBuf;
mod common;
use common::{j, s};

fn load(name: &str) -> Value {
    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../../test/fixtures/wire")
        .join(name);
    let fixture: Value = serde_json::from_str(&std::fs::read_to_string(&path).unwrap()).unwrap();
    // Each file names its protocol, so a protocol change fails here.
    assert_eq!(fixture["protocol"], json!(PROTOCOL), "{name}");
    fixture
}

fn cases<'a>(fixture: &'a Value, key: &str) -> &'a [Value] {
    let cases = fixture[key].as_array().unwrap();
    assert!(!cases.is_empty(), "{key}");
    cases
}

/// The match rule of the fixtures: an expected object matches an object that
/// holds each of its keys with a matching value; a list matches a list of the
/// same length, item by item; any other value matches an equal value.
fn matches(expected: &Value, actual: &Value) -> bool {
    match (expected, actual) {
        (Value::Object(e), Value::Object(a)) => e
            .iter()
            .all(|(key, value)| a.get(key).is_some_and(|got| matches(value, got))),
        (Value::Array(e), Value::Array(a)) => {
            e.len() == a.len() && e.iter().zip(a).all(|(e, a)| matches(e, a))
        }
        _ => expected == actual,
    }
}

fn op(name: &str) -> &'static str {
    OPS.iter().find(|op| **op == name).unwrap()
}

#[test]
fn handshake() {
    for case in cases(&load("server_frames.json"), "handshake") {
        let mut handshake = Handshake::new(None);
        let mut outcome = Ok(None);
        for frame in case["frames"].as_array().unwrap() {
            outcome = handshake.step(&j(frame)).map(Some);
            if !matches!(outcome, Ok(Some(Step::Send(_)))) {
                break;
            }
        }
        let got = match outcome {
            Ok(Some(Step::Welcome)) => json!("welcome"),
            Ok(Some(Step::Refused(n))) => json!({"refused": n}),
            Err(Broken(_)) => json!("broken"),
            other => panic!("{}: {other:?}", case["name"]),
        };
        assert_eq!(got, case["expect"], "{}", case["name"]);
    }
}

#[test]
fn hello_carries_the_proof_of_the_token_and_not_the_token() {
    let mut handshake = Handshake::new(Some("secret".to_owned()));
    let challenge =
        json!({"type": "challenge", "nonce": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="});
    let Ok(Step::Send(hello)) = handshake.step(&j(&challenge)) else {
        panic!()
    };
    // base64(HMAC-SHA256(SHA-256("secret"), 32 zero bytes)), computed with Python.
    let proof = "4S4uSYUrpAhYdX9/8bK9oHO08/6IFKJIHMUaRdEiUyQ=";
    assert_eq!(
        s(&hello),
        json!({"type": "hello", "protocol": 3, "proof": proof})
    );
    assert!(!hello.encode().contains("secret"));
    // A second challenge is a break of O1.
    assert!(handshake.step(&j(&challenge)).is_err());
}

#[test]
fn hello_with_no_token_has_no_proof() {
    let mut handshake = Handshake::new(None);
    let challenge =
        json!({"type": "challenge", "nonce": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="});
    let Ok(Step::Send(hello)) = handshake.step(&j(&challenge)) else {
        panic!()
    };
    assert_eq!(s(&hello), json!({"type": "hello", "protocol": 3}));
}

#[test]
fn res() {
    for case in cases(&load("server_frames.json"), "res") {
        let request_op = op(case["op"].as_str().unwrap());
        let parsed = frame::parse(&j(&case["frame"]), |id| (id == "1").then_some(request_op));
        let got = if parsed.is_ok() { "valid" } else { "broken" };
        assert_eq!(json!(got), case["expect"], "{}: {parsed:?}", case["name"]);
    }
}

#[test]
fn a_res_of_no_request_is_a_break() {
    let res = json!({"type": "res", "id": "9", "ok": true, "result": {}});
    assert!(frame::parse(&j(&res), |_| None).is_err());
}

#[test]
fn event() {
    for case in cases(&load("server_frames.json"), "event") {
        let got = match frame::parse(&j(&case["frame"]), |_| None) {
            Ok(ServerFrame::Event { event, .. }) if event.data.is_none() => "ignored",
            Ok(ServerFrame::Event { .. }) => "valid",
            Ok(other) => panic!("{}: {other:?}", case["name"]),
            Err(_) => "broken",
        };
        assert_eq!(json!(got), case["expect"], "{}", case["name"]);
    }
}

#[test]
fn session_end() {
    for case in cases(&load("server_frames.json"), "session_end") {
        let got = match frame::parse(&j(&case["frame"]), |_| None) {
            Ok(ServerFrame::SessionEnd { .. }) => "valid",
            Ok(other) => panic!("{}: {other:?}", case["name"]),
            Err(_) => "broken",
        };
        assert_eq!(json!(got), case["expect"], "{}", case["name"]);
    }
}

/// The state of the fold in the shape of an `expect` step.
fn observe(state: &State) -> Value {
    json!({
        "instance_id": state.instance_id,
        "seq": state.seq,
        "model": state.model,
        "running": state.running,
        "queue": {
            "steers": state.queue.steers, "follow_ups": state.queue.follow_ups,
            "running": state.queue.running, "held": state.queue.held, "waiting": state.queue.waiting,
        },
        "asks": state.asks.iter().map(|ask| ask.ask_id.clone()).collect::<Vec<_>>(),
        "messages": state.messages.iter().map(|m| m.id.clone()).collect::<Vec<_>>(),
    })
}

#[test]
fn folds() {
    for case in cases(&load("folds.json"), "cases") {
        let name = &case["name"];
        let mut state = State::default();
        let mut in_flight: Option<(String, &'static str)> = None;
        for step in case["steps"].as_array().unwrap() {
            if let Some(request) = step.get("client") {
                // The client sends the subscribe that the step names, with
                // `after` of the state that it holds.
                let session = request["params"]["session"].as_str().unwrap();
                assert_eq!(
                    s(&state.subscribe_params(session)),
                    request["params"],
                    "{name}"
                );
                in_flight = Some((
                    request["id"].as_str().unwrap().to_owned(),
                    op(request["op"].as_str().unwrap()),
                ));
            } else if let Some(server) = step.get("server") {
                let parsed = frame::parse(&j(server), |id| {
                    in_flight
                        .as_ref()
                        .filter(|(req, _)| req == id)
                        .map(|(_, op)| *op)
                });
                let applied = match parsed.unwrap_or_else(|broken| panic!("{name}: {broken:?}")) {
                    ServerFrame::Res {
                        result: Ok(Reply::Subscribe { subscribed, .. }),
                        ..
                    } => state.subscribed(subscribed),
                    ServerFrame::Event { event, .. } => state.apply(event),
                    ServerFrame::Res { .. } | ServerFrame::SessionEnd { .. } => Ok(()),
                };
                applied.unwrap_or_else(|broken| panic!("{name}: {broken:?}"));
            } else if let Some(expect) = step.get("expect") {
                assert!(
                    matches(expect, &observe(&state)),
                    "{name}: {expect} against {}",
                    observe(&state)
                );
            } else {
                assert!(step.get("close").is_some(), "{name}: {step}");
            }
        }
    }
}
