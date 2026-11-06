//! Test helpers shared by the test files.

use serde_json::{Value, json};

/// A snapshot of `instance_id` at seq 4, with `turn`, no messages, and older
/// messages on the server.
pub fn snapshot_json(instance_id: &str, turn: Value) -> Value {
    json!({
        "instance_id": instance_id, "seq": 4, "messages": [], "more": true, "turn": turn,
        "model": "fake/echo", "persisting": true, "context": null, "asks": [],
        "queue": {"steers": 0, "follow_ups": 0, "running": 0, "held": 0, "waiting": 0},
        "usage": {"input": 0, "output": 0, "cache_read": 0, "cache_write": 0,
                  "cost": null, "unknown": false, "list": false},
    })
}
