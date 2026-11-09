//! Test helpers shared by the test files.

use helyx_client_core::fold::State;
use helyx_client_core::json::{Json, decode, object};
use serde_json::{Value, json};
use std::path::PathBuf;

/// A snapshot of `instance_id` at seq 4, with `turn`, no messages, and older
/// messages on the server.
#[allow(dead_code)]
pub fn snapshot_json(instance_id: &str, turn: Value) -> Value {
    json!({
        "instance_id": instance_id, "seq": 4, "messages": [], "more": true, "turn": turn,
        "model": "fake/echo", "persisting": true, "context": null, "asks": [], "ui_blocks": [], "activated": [],
        "queue": {"steers": 0, "follow_ups": 0, "running": 0, "held": 0, "waiting": 0},
        "usage": {"input": 0, "output": 0, "cache_read": 0, "cache_write": 0,
                  "cost": null, "unknown": false, "list": false},
    })
}

/// `value` decoded by the decoder of the core from its JSON text.
#[allow(dead_code)]
pub fn j(value: &Value) -> Json {
    decode(&value.to_string()).unwrap()
}

/// `json` as a `serde_json` value, to compare with `json!`.
#[allow(dead_code)]
pub fn s(json: &Json) -> Value {
    serde_json::from_str(&json.encode()).unwrap()
}

static NULL: Json = Json::Null;

/// The fixture file `name` of `test/fixtures/wire/`, read with the decoder of
/// the core, so an integer past 2^64 - 1 keeps its digits, and a frame keeps
/// its nesting.
#[allow(dead_code)]
pub fn load(name: &str) -> Json {
    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../../test/fixtures/wire")
        .join(name);
    let fixture = decode(&std::fs::read_to_string(&path).unwrap()).unwrap();
    // Each file names its protocol, so a protocol change fails here.
    let protocol = at(&fixture, "protocol").as_u64();
    assert_eq!(
        protocol,
        Some(helyx_client_core::handshake::PROTOCOL),
        "{name}"
    );
    fixture
}

/// The value of `key` in `value`, null when it has none.
#[allow(dead_code)]
pub fn at<'a>(value: &'a Json, key: &str) -> &'a Json {
    value.get(key).unwrap_or(&NULL)
}

/// The match rule of the fixtures: an expected object matches an object that
/// holds each of its keys with a matching value; a list matches a list of the
/// same length, item by item; any other value matches an equal value.
#[allow(dead_code)]
pub fn matches(expected: &Json, actual: &Json) -> bool {
    match (expected, actual) {
        (Json::Object(e), Json::Object(_)) => e
            .iter()
            .all(|(key, value)| actual.get(key).is_some_and(|got| matches(value, got))),
        (Json::Array(e), Json::Array(a)) => {
            e.len() == a.len() && e.iter().zip(a).all(|(e, a)| matches(e, a))
        }
        _ => expected == actual,
    }
}

/// The state of the fold in the shape of an `expect` step of `folds.json`.
#[allow(dead_code)]
pub fn observe(state: &State) -> Json {
    let strings = |items: Vec<String>| Json::Array(items.into_iter().map(Json::String).collect());
    let queue = &state.queue;
    object([
        (
            "instance_id",
            state.instance_id.clone().map_or(Json::Null, Json::String),
        ),
        ("seq", (&state.seq).into()),
        ("model", Json::String(state.model.clone())),
        ("running", Json::Bool(state.running)),
        (
            "queue",
            object([
                ("steers", queue.steers.into()),
                ("follow_ups", queue.follow_ups.into()),
                ("running", queue.running.into()),
                ("held", queue.held.into()),
                ("waiting", queue.waiting.into()),
            ]),
        ),
        (
            "asks",
            strings(state.asks.iter().map(|a| a.ask_id.clone()).collect()),
        ),
        (
            "messages",
            strings(state.messages.iter().map(|m| m.id.clone()).collect()),
        ),
        (
            "ui_blocks",
            Json::Array(
                (state.ui_blocks.iter())
                    .map(|b| {
                        object([
                            (
                                "call_id",
                                b.call_id.clone().map_or(Json::Null, Json::String),
                            ),
                            ("key", Json::String(b.key.clone())),
                            ("block", b.block.clone()),
                        ])
                    })
                    .collect(),
            ),
        ),
    ])
}
