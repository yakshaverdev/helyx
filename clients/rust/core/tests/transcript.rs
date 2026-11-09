//! The rows of a transcript: each result with its call, derived on read.

mod common;
use common::j;
use helyx_client_core::message::Message;
use helyx_client_core::transcript::{Row, rows};
use serde_json::json;

fn message(value: serde_json::Value) -> Message {
    Message::parse(&j(&value)).unwrap()
}

fn call(id: &str) -> serde_json::Value {
    json!({"type": "tool_call", "id": id, "name": "bash", "arguments": {}})
}

fn result(id: &str, call_id: Option<&str>) -> Message {
    let mut value = json!({"id": id, "role": "tool_result", "content": [], "is_error": false});
    if let Some(call_id) = call_id {
        value["tool_call_id"] = json!(call_id);
    }
    message(value)
}

/// Each row as text: `m:<id>`, `c:<call id>=<result id or ->`, `o:<id>`.
fn shape(messages: &[Message]) -> Vec<String> {
    rows(messages)
        .iter()
        .map(|row| match row {
            Row::Message(m) => format!("m:{}", m.id),
            Row::Call { call, result } => {
                let helyx_client_core::message::Block::ToolCall { id, .. } = call else {
                    panic!()
                };
                format!("c:{id}={}", result.map_or("-", |r| r.id.as_str()))
            }
            Row::Orphan(m) => format!("o:{}", m.id),
        })
        .collect()
}

#[test]
fn a_result_closes_the_oldest_open_call_of_its_id() {
    let assistant = |id: &str| {
        message(json!({"id": id, "role": "assistant", "content": [call("c1"), call("c2")]}))
    };
    let messages = [
        assistant("a1"),
        assistant("a2"),
        result("r1", Some("c1")),
        result("r2", Some("c1")),
        result("r3", Some("c2")),
    ];
    assert_eq!(
        shape(&messages),
        ["m:a1", "c:c1=r1", "c:c2=r3", "m:a2", "c:c1=r2", "c:c2=-"]
    );
}

#[test]
fn a_tool_call_block_of_a_user_message_opens_no_call() {
    let user = message(json!({"id": "u1", "role": "user", "content": [call("c1")]}));
    let assistant = message(json!({"id": "a1", "role": "assistant", "content": [call("c1")]}));
    let messages = [user, assistant, result("r1", Some("c1"))];
    assert_eq!(shape(&messages), ["m:u1", "m:a1", "c:c1=r1"]);
}

#[test]
fn a_result_with_no_open_call_is_an_orphan() {
    let assistant = message(json!({"id": "a1", "role": "assistant", "content": [call("c1")]}));
    let messages = [
        result("r0", Some("c1")),
        assistant,
        result("r1", Some("c1")),
        result("r2", Some("c1")),
        result("r3", None),
        result("r4", Some("c9")),
    ];
    assert_eq!(
        shape(&messages),
        ["o:r0", "m:a1", "c:c1=r1", "o:r2", "o:r3", "o:r4"]
    );
}
