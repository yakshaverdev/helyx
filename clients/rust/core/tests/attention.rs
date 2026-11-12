//! The attention of a change of the followed session: an ask that blocks the
//! turn first, then a turn that ended badly, then one that ended well.

mod common;
use common::{j, snapshot_json};
use helyx_client_core::attention::{Attention, MAX_ATTENTION_BYTES, Seen, attention};
use helyx_client_core::event::{Event, parse_event};
use helyx_client_core::fold::State;
use helyx_client_core::frame::Subscribed;
use helyx_client_core::message::Snapshot;
use serde_json::{Value, json};

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

/// A state after its snapshot: a running turn when `running`.
fn subscribed(instance_id: &str, running: bool) -> State {
    let turn = match running {
        true => json!({"id": "t1", "partial": null, "elapsed_ms": 0}),
        false => Value::Null,
    };
    let mut state = State::default();
    state.subscribed(snapshot(instance_id, turn)).unwrap();
    state
}

/// The change that `events` make, as the window sees it in one frame: the
/// facts of the state before the first, and the state after the last.
fn change(state: &mut State, events: Vec<Event>) -> (Seen, State) {
    let before = Seen::of(state);
    for event in events {
        state.apply(event).unwrap();
    }
    (before, state.clone())
}

fn assistant(text: &str) -> Value {
    json!({"message": {"id": "a1", "role": "assistant",
                       "content": [{"type": "text", "text": text}]}})
}

fn form(ask_id: &str, text: &str) -> Value {
    json!({"ask_id": ask_id, "call_id": "c1", "tool": "question",
           "request": {"kind": "form", "text": text}})
}

#[test]
fn a_turn_end_of_done_gives_the_first_line_of_the_reply() {
    let mut state = subscribed("i1", false);
    state
        .apply(event("i1", 5, "turn_start", json!({})))
        .unwrap();
    state
        .apply(event(
            "i1",
            6,
            "message_end",
            assistant("first line\nsecond line"),
        ))
        .unwrap();
    let (before, after) = change(
        &mut state,
        vec![event("i1", 7, "turn_end", json!({"outcome": "done"}))],
    );
    let posted = attention(&before, &after).unwrap();
    assert_eq!(posted, Attention::Done("first line".into()));
    assert_eq!(posted.line(), "done: first line");
}

#[test]
fn a_reply_with_no_text_gives_turn_ended() {
    let mut state = subscribed("i1", true);
    let (before, after) = change(
        &mut state,
        vec![event("i1", 5, "turn_end", json!({"outcome": "done"}))],
    );
    assert_eq!(
        attention(&before, &after),
        Some(Attention::Done("turn ended".into()))
    );
}

#[test]
fn a_failed_turn_gives_failed_with_the_notice() {
    let mut state = subscribed("i1", true);
    let data = json!({"outcome": "error", "error": "the provider vanished"});
    let (before, after) = change(&mut state, vec![event("i1", 5, "turn_end", data)]);
    let posted = attention(&before, &after).unwrap();
    assert_eq!(posted, Attention::Failed("the provider vanished".into()));
    assert_eq!(posted.line(), "failed: the provider vanished");
}

#[test]
fn an_aborted_turn_gives_failed_with_the_newest_notice() {
    let mut state = subscribed("i1", true);
    let (before, after) = change(
        &mut state,
        vec![
            event(
                "i1",
                5,
                "notice",
                json!({"text": "stopped by another client"}),
            ),
            event("i1", 6, "turn_end", json!({"outcome": "aborted"})),
        ],
    );
    assert_eq!(
        attention(&before, &after),
        Some(Attention::Failed("stopped by another client".into()))
    );
}

#[test]
fn an_abort_with_no_notice_names_the_abort() {
    let mut state = subscribed("i1", true);
    let (before, after) = change(
        &mut state,
        vec![event("i1", 5, "turn_end", json!({"outcome": "aborted"}))],
    );
    assert_eq!(
        attention(&before, &after),
        Some(Attention::Failed("turn aborted".into()))
    );
}

#[test]
fn a_new_form_ask_gives_waiting_also_while_the_turn_runs() {
    let mut state = subscribed("i1", true);
    let (before, after) = change(
        &mut state,
        vec![event("i1", 5, "ask", form("k1", "which file?"))],
    );
    let posted = attention(&before, &after).unwrap();
    assert_eq!(posted, Attention::Waiting("which file?".into()));
    assert_eq!(posted.line(), "waiting for your answer: which file?");

    let mut idle = subscribed("i1", false);
    let (before, after) = change(
        &mut idle,
        vec![event("i1", 5, "ask", form("k1", "which file?"))],
    );
    assert_eq!(
        attention(&before, &after),
        Some(Attention::Waiting("which file?".into()))
    );
}

#[test]
fn a_new_approval_ask_gives_waiting_with_its_title() {
    let mut state = subscribed("i1", true);
    let ask = json!({"ask_id": "k1", "call_id": "c1", "tool": "bash",
                     "request": {"kind": "approval", "text": "allow bash?", "tool": "bash",
                                 "provider": null, "arguments": "{}"}});
    let (before, after) = change(&mut state, vec![event("i1", 5, "ask", ask)]);
    assert_eq!(
        attention(&before, &after),
        Some(Attention::Waiting("allow bash?".into()))
    );
}

#[test]
fn a_new_ask_of_another_kind_gives_none() {
    let mut state = subscribed("i1", true);
    let ask = json!({"ask_id": "k1", "call_id": "c1", "tool": "question",
                     "request": {"kind": "question", "text": "Go?"}});
    let (before, after) = change(&mut state, vec![event("i1", 5, "ask", ask)]);
    assert_eq!(attention(&before, &after), None);
}

#[test]
fn a_new_ask_with_no_kind_gives_none() {
    let mut state = subscribed("i1", true);
    let ask = json!({"ask_id": "k1", "call_id": "c1", "tool": "question",
                     "request": {"question": "Go?"}});
    let (before, after) = change(&mut state, vec![event("i1", 5, "ask", ask)]);
    assert_eq!(attention(&before, &after), None);
}

#[test]
fn an_ask_and_a_turn_end_in_one_change_give_waiting() {
    let mut state = subscribed("i1", true);
    let (before, after) = change(
        &mut state,
        vec![
            event("i1", 5, "ask", form("k1", "which file?")),
            event("i1", 6, "turn_end", json!({"outcome": "done"})),
        ],
    );
    assert_eq!(
        attention(&before, &after),
        Some(Attention::Waiting("which file?".into()))
    );
}

#[test]
fn a_snapshot_gives_none() {
    let mut state = subscribed("i1", true);
    state
        .apply(event("i1", 5, "notice", json!({"text": "n"})))
        .unwrap();
    let before = Seen::of(&state);
    // The next snapshot of the same instance says that the turn ended, but a
    // snapshot is history.
    state.subscribed(snapshot("i1", Value::Null)).unwrap();
    assert_eq!(attention(&before, &state), None);
    // The first snapshot has no state before it, so no change to post.
    assert_eq!(attention(&Seen::of(&State::default()), &state), None);
}

#[test]
fn a_state_of_another_instance_gives_none() {
    let mut first = subscribed("i1", true);
    let mut second = subscribed("i2", true);
    first
        .apply(event("i1", 5, "notice", json!({"text": "n"})))
        .unwrap();
    second
        .apply(event("i2", 5, "notice", json!({"text": "n"})))
        .unwrap();
    assert_eq!(attention(&Seen::of(&first), &second), None);
}

#[test]
fn a_text_of_the_bound_stays_and_one_byte_more_is_cut() {
    let full = "a".repeat(MAX_ATTENTION_BYTES);
    let mut state = subscribed("i1", true);
    let (before, after) = change(&mut state, vec![event("i1", 5, "ask", form("k1", &full))]);
    assert_eq!(
        attention(&before, &after),
        Some(Attention::Waiting(full.clone()))
    );

    // 199 bytes and a two-byte character: the cut falls inside it, so the
    // cut goes back to the boundary and the mark follows.
    let mut over = "a".repeat(MAX_ATTENTION_BYTES - 1);
    over.push('é');
    let mut state = subscribed("i1", true);
    let (before, after) = change(&mut state, vec![event("i1", 5, "ask", form("k1", &over))]);
    assert_eq!(
        attention(&before, &after),
        Some(Attention::Waiting(format!(
            "{}…",
            "a".repeat(MAX_ATTENTION_BYTES - 1)
        )))
    );
}

#[test]
fn control_characters_are_cleaned() {
    let mut state = subscribed("i1", true);
    let text = "  a\u{7}\u{7}b\nc\t d  ";
    let (before, after) = change(&mut state, vec![event("i1", 5, "ask", form("k1", text))]);
    assert_eq!(
        attention(&before, &after),
        Some(Attention::Waiting("a b c d".into()))
    );
}
