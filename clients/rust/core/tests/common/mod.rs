//! Test helpers shared by the test files.

use helyx_client_core::json::{Json, decode};
use serde_json::{Value, json};

/// A snapshot of `instance_id` at seq 4, with `turn`, no messages, and older
/// messages on the server.
#[allow(dead_code)]
pub fn snapshot_json(instance_id: &str, turn: Value) -> Value {
    json!({
        "instance_id": instance_id, "seq": 4, "messages": [], "more": true, "turn": turn,
        "model": "fake/echo", "persisting": true, "context": null, "asks": [],
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
