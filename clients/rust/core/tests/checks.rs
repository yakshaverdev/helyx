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
    for (server_protocol, valid) in [(10, true), (11, true), (12, false), (13, true)] {
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

/// A UI block of protocol 5 as the TUI checks it: the envelope, at most
/// 65,536 bytes of JSON as the server encodes it, and integers of at most
/// 100 digits, also nested past the depth that the decoder keeps as text.
#[test]
fn a_ui_block_is_checked_as_the_tui_checks_it() {
    use helyx_client_core::json::decode;
    use helyx_client_core::ui_block::{MAX_BYTES, block, envelope};
    let ok = |text: &str| block(&decode(text).unwrap()).is_ok();
    // `{"kind":"k","text":""}` is 22 bytes; a control byte is 6 of JSON.
    let text = |n: usize| format!(r#"{{"kind":"k","text":"{}"}}"#, "a".repeat(n));
    assert!(ok(&text(MAX_BYTES - 22)));
    assert!(!ok(&text(MAX_BYTES - 21)));
    // A control byte is 6 bytes of JSON in the form of the server, `\n` 2.
    let escaped = |unit: &str, n: usize| format!(r#"{{"kind":"k","text":"{}"}}"#, unit.repeat(n));
    assert!(ok(&escaped(r"\u0001", (MAX_BYTES - 22) / 6)));
    assert!(!ok(&escaped(r"\u0001", (MAX_BYTES - 22) / 6 + 1)));
    assert!(ok(&escaped(r"\n", (MAX_BYTES - 22) / 2)));
    assert!(!ok(&escaped(r"\n", (MAX_BYTES - 22) / 2 + 1)));
    let digits = |n: usize| format!(r#"{{"kind":"k","text":"","n":{}}}"#, "9".repeat(n));
    assert!(ok(&digits(100)) && !ok(&digits(101)));
    assert!(ok(&format!(
        r#"{{"kind":"k","text":"","n":-{}}}"#,
        "9".repeat(100)
    )));
    assert!(ok(&format!(
        r#"{{"kind":"k","text":"","n":{}e5}}"#,
        "9".repeat(200)
    )));
    let deep = |n: usize| {
        format!(
            r#"{{"kind":"k","text":"","n":{}"x",{}{}}}"#,
            "[".repeat(80),
            "9".repeat(n),
            "]".repeat(80)
        )
    };
    assert!(ok(&deep(100)) && !ok(&deep(101)));
    for kind in ["", "A", "a-b", &"a".repeat(65)] {
        assert!(!ok(&format!(r#"{{"kind":"{kind}","text":""}}"#)), "{kind}");
    }
    assert!(ok(r#"{"kind":"a_1","text":"","cut":true}"#));
    assert!(!ok(r#"{"kind":"k","text":"","cut":null}"#));
    assert!(!ok(r#"{"kind":"k","text":1}"#));
    assert!(envelope(&decode(r#"{"kind":"form","text":"t","questions":[]}"#).unwrap()).is_ok());
}

/// The carriers of UI blocks: at most 8 on a tool result and none on
/// another role, a key of 1 to 64 bytes, the envelope of the request of an
/// ask with a kind, and the origin kind `hook` of protocol 4.
#[test]
fn the_carriers_of_ui_blocks_and_the_origin_of_a_hook() {
    use helyx_client_core::message::Ask;
    use helyx_client_core::ui_block::Shown;
    let block = json!({"kind": "progress", "text": "1 of 3"});
    let result = |n: usize, role: &str| {
        let message = json!({"id": "r1", "role": role, "content": [], "tool_call_id": "c1",
            "ui_blocks": vec![block.clone(); n]});
        Message::parse(&j(&message))
    };
    assert_eq!(result(8, "tool_result").unwrap().ui_blocks.len(), 8);
    assert!(result(9, "tool_result").is_err());
    assert!(result(1, "user").is_err());
    let none = json!({"id": "u1", "role": "user", "content": [], "ui_blocks": null});
    assert!(Message::parse(&j(&none)).unwrap().ui_blocks.is_empty());
    let shown =
        |key: String| Shown::parse(&j(&json!({"call_id": null, "key": key, "block": block})));
    assert!(shown("k".repeat(64)).is_ok());
    assert!(shown("k".repeat(65)).is_err() && shown(String::new()).is_err());
    let ask = |request: Value| {
        Ask::parse(&j(
            &json!({"ask_id": "k1", "call_id": "c1", "tool": "t", "request": request}),
        ))
    };
    assert!(ask(json!({"anything": 1})).is_ok());
    assert!(ask(json!({"kind": "form", "text": "t"})).is_ok());
    assert!(ask(json!({"kind": "Form", "text": "t"})).is_err());
    let hook = |id: Value| {
        let message = json!({"id": "u1", "role": "user", "content": [],
            "origin": {"kind": "hook", "id": id}});
        Message::parse(&j(&message)).is_ok()
    };
    assert!(hook(json!("Acme.Hook.Check")) && hook(Value::Null));
}
