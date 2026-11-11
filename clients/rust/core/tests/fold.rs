//! The rules of the fold that the fixtures do not pin down.

use helyx_client_core::Broken;
use helyx_client_core::event::{Event, parse_event};
use helyx_client_core::fold::{ACK_EVERY, State, ack};
use helyx_client_core::frame::Subscribed;
use helyx_client_core::message::{Block, Snapshot};
use serde_json::{Value, json};

mod common;
use common::{j, s, snapshot_json};

fn snapshot(instance_id: &str, turn: Value) -> Subscribed {
    Subscribed::Snapshot(Box::new(
        Snapshot::parse(&j(&snapshot_json(instance_id, turn))).unwrap(),
    ))
}

fn event(instance_id: &str, seq: u64, kind: &str, data: Value) -> Event {
    parse_event(&j(
        &json!({"type": kind, "session_id": "s1", "instance_id": instance_id,
                        "turn_id": "t1", "seq": seq, "data": data}),
    ))
    .unwrap()
}

fn subscribed(instance_id: &str, turn: Value) -> State {
    let mut state = State::default();
    state.subscribed(snapshot(instance_id, turn)).unwrap();
    state
}

#[test]
fn an_event_before_a_snapshot_or_of_another_instance_is_a_break() {
    let mut state = State::default();
    let broken = Err(Broken("event instance"));
    assert_eq!(state.apply(event("i1", 1, "turn_start", json!({}))), broken);
    assert_eq!(state, State::default());
    let mut state = subscribed("i1", Value::Null);
    let before = state.clone();
    assert_eq!(state.apply(event("i2", 5, "turn_start", json!({}))), broken);
    assert_eq!(state, before);
    // Inside a replay too.
    let replay = vec![event("i2", 5, "turn_start", json!({}))];
    assert_eq!(state.subscribed(Subscribed::Replay(replay)), broken);
    assert_eq!(state, before);
}

#[test]
fn a_replay_to_a_state_with_no_snapshot_is_a_break() {
    let mut state = State::default();
    assert_eq!(
        state.subscribed(Subscribed::Replay(vec![])),
        Err(Broken("replay"))
    );
    let replay = vec![event("i1", 1, "turn_start", json!({}))];
    assert_eq!(
        state.subscribed(Subscribed::Replay(replay)),
        Err(Broken("replay"))
    );
    assert_eq!(state, State::default());
}

#[test]
fn an_event_that_is_not_the_next_seq_is_a_break_and_changes_nothing() {
    let notice = |seq| event("i1", seq, "notice", json!({"text": "n"}));
    let mut state = subscribed("i1", Value::Null);
    let before = state.clone();
    // A duplicate of the snapshot seq, an older one, and a gap.
    for seq in [4, 3, 0, 6, u64::MAX] {
        assert_eq!(state.apply(notice(seq)), Err(Broken("event seq")), "{seq}");
        assert_eq!(state, before);
    }
    assert_eq!(state.apply(notice(5)), Ok(()));
    assert_eq!(state.apply(notice(5)), Err(Broken("event seq")));
    assert_eq!((state.seq.to_u64(), state.notices.len()), (Some(5), 1));
}

#[test]
fn a_replay_out_of_order_stops_at_the_broken_event() {
    let mut state = subscribed("i1", Value::Null);
    let replay = [5, 6, 6, 7].map(|seq| event("i1", seq, "notice", json!({"text": "n"})));
    let result = state.subscribed(Subscribed::Replay(replay.into()));
    assert_eq!(result, Err(Broken("event seq")));
    assert_eq!((state.seq.to_u64(), state.notices.len()), (Some(6), 2));
}

#[test]
fn deltas_stream_into_the_partial_of_the_snapshot() {
    let partial =
        json!({"id": "a2", "role": "assistant", "content": [{"type": "text", "text": "wor"}]});
    let mut state = subscribed(
        "i1",
        json!({"id": "t1", "partial": partial, "elapsed_ms": 0}),
    );
    let deltas = [json!({"text_delta": "ld"}), json!({"thinking_delta": "hm"})];
    for (seq, delta) in (5..).zip(deltas) {
        state
            .apply(event("i1", seq, "message_update", delta))
            .unwrap();
    }
    let content = &state.partial.as_ref().unwrap().content;
    assert_eq!(
        content,
        &[Block::Text("world".into()), Block::Thinking("hm".into())]
    );
    assert!(state.more && state.running);
}

#[test]
fn only_an_assistant_message_streams() {
    let mut state = subscribed("i1", Value::Null);
    let user = json!({"id": "u2", "role": "user", "content": [{"type": "text", "text": "hi"}]});
    state
        .apply(event("i1", 5, "message_start", json!({"message": user})))
        .unwrap();
    state
        .apply(event("i1", 6, "message_update", json!({"text_delta": "x"})))
        .unwrap();
    assert_eq!(state.partial, None);
}

#[test]
fn a_block_of_an_unknown_kind_keeps_its_kind() {
    let mut state = subscribed("i1", Value::Null);
    let message = json!({"id": "a1", "role": "assistant", "content": [{"type": "chart", "x": 1}]});
    state
        .apply(event("i1", 5, "message_end", json!({"message": message})))
        .unwrap();
    assert_eq!(state.messages[0].content, [Block::Unknown("chart".into())]);
}

#[test]
fn an_ack_goes_when_a_frame_passes_a_multiple_of_the_cadence() {
    let frame = |seq| Some(json!({"type": "ack", "sub": "0", "seq": seq}));
    let ack = |sub, from: u64, to: u64| ack(sub, &from.into(), &to.into()).map(|frame| s(&frame));
    assert_eq!(ack("0", 0, 0), None);
    assert_eq!(ack("0", 0, ACK_EVERY - 1), None);
    assert_eq!(ack("0", ACK_EVERY - 1, ACK_EVERY), frame(ACK_EVERY));
    assert_eq!(ack("0", ACK_EVERY, ACK_EVERY + 1), None);
    // A replay from 1,020 to 1,029 passes 1,024: it acks its last seq.
    assert_eq!(ack("0", 1_020, 1_029), frame(1_029));
    // A snapshot is the credit base: no ack for it.
    assert_eq!(ack("0", 2 * ACK_EVERY, 2 * ACK_EVERY), None);
}

/// A `seq` of any size: the fold counts on past 2^64 - 1 exactly.
#[test]
fn a_seq_past_the_largest_u64_counts_on() {
    let mut state = State::default();
    let snap = json!({"instance_id": "i1", "seq": u64::MAX, "messages": [],
        "turn": null, "model": "fake/echo", "persisting": true, "context": null, "asks": [], "ui_blocks": [], "activated": [],
        "queue": {"steers": 0, "follow_ups": 0, "running": 0, "held": 0, "waiting": 0},
        "usage": {"input": 0, "output": 0, "cache_read": 0, "cache_write": 0,
                  "cost": null, "unknown": false, "list": false}});
    let snapshot = Snapshot::parse(&j(&snap)).unwrap();
    state
        .subscribed(Subscribed::Snapshot(Box::new(snapshot)))
        .unwrap();
    let past = |seq: &str| {
        let text = format!(
            r#"{{"type":"notice","session_id":"s1","instance_id":"i1","turn_id":null,"seq":{seq},"data":{{"text":"n"}}}}"#
        );
        parse_event(&helyx_client_core::json::decode(&text).unwrap()).unwrap()
    };
    state.apply(past("18446744073709551616")).unwrap();
    assert_eq!(state.seq.to_string(), "18446744073709551616");
    assert!(state.apply(past("18446744073709551618")).is_err());
    let after = state.subscribe_params("s1").encode();
    assert!(after.contains(r#""seq":18446744073709551616"#), "{after}");
    // 2^64 is a multiple of 1,024: the ack of it carries every digit.
    let from = u64::MAX.into();
    let acked = ack("0", &from, &state.seq).unwrap().encode();
    assert_eq!(
        acked,
        r#"{"type":"ack","sub":"0","seq":18446744073709551616}"#
    );
    assert_eq!(
        ack("0", &state.seq, &past("18446744073709551617").seq),
        None
    );
}

#[test]
fn message_end_adds_a_user_or_assistant_message_and_not_a_tool_result() {
    let partial = json!({"id": "a2", "role": "assistant", "content": []});
    let mut state = subscribed(
        "i1",
        json!({"id": "t1", "partial": partial, "elapsed_ms": 0}),
    );
    let message =
        |id: &str, role: &str| json!({"message": {"id": id, "role": role, "content": []}});
    state
        .apply(event("i1", 5, "message_end", message("u2", "user")))
        .unwrap();
    assert!(state.partial.is_some());
    let result = json!({"message": {"id": "r1", "role": "tool_result", "content": [],
                                    "tool_call_id": "c1", "is_error": false}});
    state.apply(event("i1", 6, "message_end", result)).unwrap();
    state
        .apply(event("i1", 7, "message_end", message("a3", "assistant")))
        .unwrap();
    let ids: Vec<_> = state.messages.iter().map(|m| m.id.as_str()).collect();
    assert_eq!(ids, ["u2", "a3"]);
    assert_eq!(state.partial, None);
}
