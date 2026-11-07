//! The checks of the schema at their bounds, which the fixtures do not hold.

use helyx_client_core::event::{EventData, parse_event};
use helyx_client_core::frame::{self, ServerFrame};
use helyx_client_core::handshake::{Handshake, Step};
use helyx_client_core::message::{Block, Message};
use serde_json::{Value, json};

mod common;
use common::{j, snapshot_json};

fn challenge(bytes: usize) -> Value {
    use base64::Engine;
    let nonce = base64::engine::general_purpose::STANDARD.encode(vec![0u8; bytes]);
    json!({"type": "challenge", "nonce": nonce})
}

#[test]
fn a_nonce_has_exactly_32_bytes() {
    for (bytes, valid) in [(31, false), (32, true), (33, false), (0, false)] {
        let step = Handshake::new(None).step(&j(&challenge(bytes)));
        assert_eq!(matches!(step, Ok(Step::Send(_))), valid, "{bytes}");
    }
}

#[test]
fn no_frame_of_the_handshake_follows_its_answer() {
    for answer in [
        json!({"type": "welcome", "protocol": 3}),
        json!({"type": "refused", "code": "protocol", "server_protocol": 4}),
    ] {
        let mut handshake = Handshake::new(None);
        handshake.step(&j(&challenge(32))).unwrap();
        assert!(handshake.step(&j(&answer)).is_ok());
        assert!(handshake.step(&j(&answer)).is_err(), "{answer}");
        assert!(handshake.step(&j(&challenge(32))).is_err(), "{answer}");
    }
}

fn steer_res(id: &str) -> Result<ServerFrame, helyx_client_core::Broken> {
    let frame = json!({"type": "res", "id": id, "ok": true, "result": {}});
    frame::parse(&j(&frame), |_| Some("steer"))
}

#[test]
fn a_res_id_has_1_to_64_bytes() {
    assert!(steer_res("").is_err());
    assert!(steer_res(&"a".repeat(64)).is_ok());
    assert!(steer_res(&"a".repeat(65)).is_err());
    // 32 two-byte characters are 64 bytes; one more byte is over.
    assert!(steer_res(&"é".repeat(32)).is_ok());
    assert!(steer_res(&format!("{}a", "é".repeat(32))).is_err());
}

fn notice_seq(seq: &str) -> bool {
    let text = format!(
        r#"{{"type":"notice","session_id":"s1","instance_id":"i1","turn_id":null,"seq":{seq},"data":{{"text":"n"}}}}"#
    );
    parse_event(&helyx_client_core::json::decode(&text).unwrap()).is_ok()
}

#[test]
fn an_int_is_any_integer_from_0() {
    assert!(notice_seq("0"));
    // `-0` is zero, as Elixir decodes it.
    assert!(notice_seq("-0"));
    assert!(notice_seq("18446744073709551615"));
    // Past 2^64 - 1 too: the schema has no upper bound.
    assert!(notice_seq("18446744073709551616"));
    assert!(notice_seq(&"9".repeat(1_024)));
    assert!(!notice_seq("-1"));
    assert!(!notice_seq("1.0"));
    assert!(!notice_seq("1e3"));
}

#[test]
fn an_int_past_the_largest_u64_reads_as_the_largest_u64() {
    let text = r#"{"type":"queue_update","session_id":"s1","instance_id":"i1","turn_id":null,"seq":1,
        "data":{"steers":18446744073709551616,"follow_ups":-0,"running":0,"held":1,"waiting":0}}"#;
    let event = parse_event(&helyx_client_core::json::decode(text).unwrap()).unwrap();
    let Some(EventData::QueueUpdate(queue)) = event.data else {
        panic!("{event:?}")
    };
    assert_eq!(
        (queue.steers, queue.follow_ups, queue.held),
        (u64::MAX, 0, 1)
    );
}

#[test]
fn a_subscribe_result_has_exactly_one_of_snapshot_and_replay() {
    for result in [
        json!({"sub": "0", "snapshot": null, "replay": []}),
        json!({"sub": "0", "snapshot": null}),
        json!({"sub": "0", "replay": null}),
        json!({"sub": "0"}),
    ] {
        let frame = json!({"type": "res", "id": "1", "ok": true, "result": result});
        assert!(
            frame::parse(&j(&frame), |_| Some("subscribe")).is_err(),
            "{result}"
        );
    }
}

// The schema has `tool_call_id` optional; the transcript shows an orphan.
#[test]
fn a_tool_result_may_have_no_call_id() {
    let event = |message: Value| {
        parse_event(&j(
            &json!({"type": "tool_execution_end", "session_id": "s1",
            "instance_id": "i1", "turn_id": "t1", "seq": 1, "data": {"message": message}}),
        ))
    };
    let result = json!({"id": "r1", "role": "tool_result", "content": [], "is_error": false});
    assert!(event(result.clone()).is_ok());
    let mut with_id = result;
    with_id["tool_call_id"] = json!("c1");
    assert!(event(with_id).is_ok());
}

#[test]
fn a_cost_of_signed_zero_is_zero() {
    let message = |cost: &str| {
        let text = format!(
            r#"{{"id":"a1","role":"assistant","content":[],"usage":{{"input":0,"output":0,"cache_read":0,"cache_write":0,"cost":{cost},"cost_kind":"billed"}}}}"#
        );
        Message::parse(&helyx_client_core::json::decode(&text).unwrap())
    };
    assert!(message("-0.0").is_ok());
    assert!(message("0.0").is_ok());
    assert!(message("-0.5").is_err());
    assert!(message("-1e-400").is_ok());
}

#[test]
fn refused_names_another_protocol() {
    for (server_protocol, valid) in [(2, true), (3, false), (4, true)] {
        let mut handshake = Handshake::new(None);
        handshake.step(&j(&challenge(32))).unwrap();
        let refused =
            json!({"type": "refused", "code": "protocol", "server_protocol": server_protocol});
        assert_eq!(
            handshake.step(&j(&refused)).is_ok(),
            valid,
            "{server_protocol}"
        );
    }
}

#[test]
fn a_tool_call_keeps_an_object_with_the_key_of_serde_json() {
    // The key that `serde_json` with `arbitrary_precision` reads as a number.
    let key = r#"{"$serde_json::private::Number":"123"}"#;
    for arguments in [format!(r#"{{"n":{key}}}"#), key.to_owned()] {
        let text = format!(
            r#"{{"id":"a1","role":"assistant","content":[{{"type":"tool_call","id":"c1","name":"bash","arguments":{arguments}}}]}}"#
        );
        let message = Message::parse(&helyx_client_core::json::decode(&text).unwrap()).unwrap();
        let Block::ToolCall { arguments: got, .. } = &message.content[0] else {
            panic!()
        };
        assert_eq!(got.encode(), arguments);
    }
}

#[test]
fn a_tool_call_keeps_an_integer_of_100_digits() {
    let digits = "9".repeat(100);
    let text = format!(
        r#"{{"id":"a1","role":"assistant","content":[{{"type":"tool_call","id":"c1","name":"bash","arguments":{{"n":{digits}}}}}]}}"#
    );
    let message = Message::parse(&helyx_client_core::json::decode(&text).unwrap()).unwrap();
    let Block::ToolCall { arguments, .. } = &message.content[0] else {
        panic!()
    };
    assert_eq!(arguments.get("n").unwrap().encode(), digits);
}

#[test]
fn a_broken_handshake_frame_ends_the_handshake() {
    let broken_then_good = [
        (challenge(3), challenge(32)),
        (
            json!({"type": "welcome", "protocol": 2}),
            json!({"type": "welcome", "protocol": 3}),
        ),
        (
            json!({"type": "refused", "code": "x", "server_protocol": 4}),
            json!({"type": "refused", "code": "protocol", "server_protocol": 4}),
        ),
    ];
    for (broken, good) in broken_then_good {
        let mut handshake = Handshake::new(None);
        // An answer is taken only after a challenge.
        if broken["type"] != "challenge" {
            handshake.step(&j(&challenge(32))).unwrap();
        }
        assert!(handshake.step(&j(&broken)).is_err(), "{broken}");
        assert!(handshake.step(&j(&good)).is_err(), "{good}");
    }
}

#[test]
fn the_partial_of_a_snapshot_is_an_assistant_message() {
    use helyx_client_core::message::Snapshot;
    let snapshot = |role: &str| {
        let partial = json!({"id": "m1", "role": role, "content": []});
        Snapshot::parse(&j(&snapshot_json(
            "i1",
            json!({"id": "t1", "partial": partial, "elapsed_ms": 0}),
        )))
    };
    assert!(snapshot("assistant").is_ok());
    assert!(snapshot("user").is_err());
    assert!(snapshot("tool_result").is_err());
}
