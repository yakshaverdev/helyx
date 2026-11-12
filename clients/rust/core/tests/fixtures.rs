//! Runs the wire conformance fixtures of `test/fixtures/wire/` against the
//! client core: `server_frames.json` against the frame checks and the
//! handshake, `folds.json` against the fold. The files are read with the
//! decoder of the core, so an integer past 2^64 - 1 keeps its digits, and a
//! frame keeps its nesting.

use helyx_client_core::Broken;
use helyx_client_core::fold::State;
use helyx_client_core::frame::{self, OPS, Reply, ServerFrame};
use helyx_client_core::handshake::{Handshake, Step};
use helyx_client_core::json::{self, Json, object};
use serde_json::json;
mod common;
use common::{at, j, load, matches, observe, s};

fn text(value: &Json) -> &str {
    value.as_str().unwrap()
}

/// `value` as the server sends it: its text, decoded as a frame.
fn frame(value: &Json) -> Json {
    json::decode(&value.encode()).unwrap()
}

fn cases<'a>(fixture: &'a Json, key: &str) -> &'a [Json] {
    let cases = at(fixture, key).as_array().unwrap();
    assert!(!cases.is_empty(), "{key}");
    cases
}

fn op(name: &str) -> &'static str {
    OPS.iter().find(|op| **op == name).unwrap()
}

#[test]
fn handshake() {
    for case in cases(&load("server_frames.json"), "handshake") {
        let mut handshake = Handshake::new(None);
        let mut outcome = Ok(None);
        for sent in at(case, "frames").as_array().unwrap() {
            outcome = handshake.step(&frame(sent)).map(Some);
            if !matches!(outcome, Ok(Some(Step::Send(_)))) {
                break;
            }
        }
        let got = match outcome {
            Ok(Some(Step::Welcome)) => "welcome".into(),
            Ok(Some(Step::Refused(n))) => object([("refused", n.into())]),
            Err(Broken(_)) => "broken".into(),
            other => panic!("{}: {other:?}", text(at(case, "name"))),
        };
        assert_eq!(&got, at(case, "expect"), "{}", text(at(case, "name")));
    }
}

#[test]
fn hello_carries_the_proof_of_the_token_and_not_the_token() {
    let mut handshake = Handshake::new(Some(helyx_client_core::handshake::Token::new(
        "secret".to_owned(),
    )));
    let challenge =
        json!({"type": "challenge", "nonce": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="});
    let Ok(Step::Send(hello)) = handshake.step(&j(&challenge)) else {
        panic!()
    };
    // base64(HMAC-SHA256(SHA-256("secret"), 32 zero bytes)), computed with Python.
    let proof = "4S4uSYUrpAhYdX9/8bK9oHO08/6IFKJIHMUaRdEiUyQ=";
    assert_eq!(
        s(&hello),
        json!({"type": "hello", "protocol": 13, "proof": proof})
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
    assert_eq!(s(&hello), json!({"type": "hello", "protocol": 13}));
}

#[test]
fn res() {
    for case in cases(&load("server_frames.json"), "res") {
        let request_op = op(text(at(case, "op")));
        let parsed = frame::parse(&frame(at(case, "frame")), |id| {
            (id == "1").then_some(request_op)
        });
        let got = if parsed.is_ok() { "valid" } else { "broken" };
        let name = text(at(case, "name"));
        assert_eq!(&Json::from(got), at(case, "expect"), "{name}: {parsed:?}");
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
        let name = text(at(case, "name"));
        let got = match frame::parse(&frame(at(case, "frame")), |_| None) {
            Ok(ServerFrame::Event { event, .. }) if event.data.is_none() => "ignored",
            Ok(ServerFrame::Event { .. }) => "valid",
            Ok(other) => panic!("{name}: {other:?}"),
            Err(_) => "broken",
        };
        assert_eq!(&Json::from(got), at(case, "expect"), "{name}");
    }
}

#[test]
fn session_end() {
    for case in cases(&load("server_frames.json"), "session_end") {
        let name = text(at(case, "name"));
        let got = match frame::parse(&frame(at(case, "frame")), |_| None) {
            Ok(ServerFrame::SessionEnd { .. }) => "valid",
            Ok(other) => panic!("{name}: {other:?}"),
            Err(_) => "broken",
        };
        assert_eq!(&Json::from(got), at(case, "expect"), "{name}");
    }
}

#[test]
fn folds() {
    for case in cases(&load("folds.json"), "cases") {
        let name = text(at(case, "name"));
        let mut state = State::default();
        let mut in_flight: Option<(String, &'static str)> = None;
        for step in at(case, "steps").as_array().unwrap() {
            if let Some(request) = step.get("client") {
                // The client sends the subscribe that the step names, with
                // `after` of the state that it holds.
                let params = at(request, "params");
                let sent = state.subscribe_params(text(at(params, "session")));
                assert!(
                    matches(params, &sent) && matches(&sent, params),
                    "{name}: {} against {}",
                    sent.encode(),
                    params.encode()
                );
                in_flight = Some((
                    text(at(request, "id")).to_owned(),
                    op(text(at(request, "op"))),
                ));
            } else if let Some(server) = step.get("server") {
                let parsed = frame::parse(&frame(server), |id| {
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
                    ServerFrame::Event { event, .. } => state.apply(*event),
                    ServerFrame::Res { .. }
                    | ServerFrame::SessionEnd { .. }
                    | ServerFrame::Record(_)
                    | ServerFrame::RecordsEnd => Ok(()),
                };
                applied.unwrap_or_else(|broken| panic!("{name}: {broken:?}"));
            } else if let Some(expect) = step.get("expect") {
                let held = observe(&state);
                assert!(
                    matches(expect, &held),
                    "{name}: {} against {}",
                    expect.encode(),
                    held.encode()
                );
            } else {
                assert!(step.get("close").is_some(), "{name}: {}", step.encode());
            }
        }
    }
}
