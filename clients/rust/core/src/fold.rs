//! The fold of the frames of one subscription into the state that a client
//! shows (`test/fixtures/wire/README.md`, "folds.json"). A snapshot replaces
//! the whole state; a replay applies its events in order; an event applies to
//! the state. The state outlives a connection, so a reconnect subscribes with
//! `after` of the last event applied.

use crate::check::{Broken, Checked};
use crate::event::{Delta, Event, EventData, TurnOutcome};
use crate::frame::Subscribed;
use crate::message::{Ask, Block, Message, Queue, Role};
use serde_json::{Value, json};

/// The client acks each event whose `seq` is a multiple of this, as the TUI
/// does: far below the 16,384 unacked events that end a subscription (`4408`).
pub const ACK_EVERY: u64 = 1_024;

#[derive(Debug, Clone, Default, PartialEq)]
pub struct State {
    /// The instance of the last snapshot; `None` before the first one.
    pub instance_id: Option<String>,
    /// That of the last snapshot or of the last event applied after it.
    pub seq: u64,
    pub model: String,
    pub queue: Queue,
    /// The open asks, oldest first.
    pub asks: Vec<Ask>,
    /// True from a snapshot with a turn or a `turn_start`, until a `turn_end`.
    pub running: bool,
    /// The transcript, oldest first: each user and assistant message at its
    /// end, each tool result after the assistant message of its call.
    pub messages: Vec<Message>,
    /// True when the server holds older messages than the tail.
    pub more: bool,
    /// The assistant message that streams now.
    pub partial: Option<Message>,
    /// The notices and turn errors, for a person, oldest first.
    pub notices: Vec<String>,
}

impl State {
    /// The params of a `subscribe` for `session`: with `after` when the state
    /// holds a snapshot, so the server can replay the events after it.
    pub fn subscribe_params(&self, session: &str) -> Value {
        match &self.instance_id {
            None => json!({"session": session}),
            Some(instance_id) => json!({
                "session": session,
                "after": {"instance_id": instance_id, "seq": self.seq},
            }),
        }
    }

    /// Applies the result of a `subscribe`. A replayed event out of order is a
    /// break, as in `apply`; the events before it stay applied.
    pub fn subscribed(&mut self, subscribed: Subscribed) -> Checked<()> {
        match subscribed {
            Subscribed::Snapshot(snapshot) => {
                let snapshot = *snapshot;
                *self = State {
                    instance_id: Some(snapshot.instance_id),
                    seq: snapshot.seq,
                    model: snapshot.model,
                    queue: snapshot.queue,
                    asks: snapshot.asks,
                    running: snapshot.turn.is_some(),
                    messages: snapshot.messages,
                    more: snapshot.more,
                    partial: snapshot.turn.and_then(|turn| turn.partial),
                    notices: Vec::new(),
                };
                Ok(())
            }
            Subscribed::Replay(events) => {
                events.into_iter().try_for_each(|event| self.apply(event))
            }
        }
    }

    /// Applies one event. An event of a type that the client does not know
    /// moves `seq` only. An event of another instance than that of the last
    /// snapshot changes nothing, as in the TUI. An event of the instance whose
    /// `seq` is not the next one is a break of O4 (no gap, no duplicate), and
    /// changes nothing.
    pub fn apply(&mut self, event: Event) -> Checked<()> {
        if self.instance_id.as_deref() != Some(event.instance_id.as_str()) {
            return Ok(());
        }
        if self.seq.checked_add(1) != Some(event.seq) {
            return Err(Broken("event seq"));
        }
        self.seq = event.seq;
        let Some(data) = event.data else {
            return Ok(());
        };
        match data {
            EventData::TurnStart => self.running = true,
            // Only an assistant message streams, as in the TUI.
            EventData::MessageStart(message) if message.role == Role::Assistant => {
                self.partial = Some(message)
            }
            EventData::MessageStart(_) => {}
            EventData::MessageUpdate(delta) => self.stream(delta),
            // A tool result joins the transcript at `tool_execution_end`, and
            // the end of an assistant message ends the partial, as in the TUI.
            EventData::MessageEnd { message, .. } => match message.role {
                Role::ToolResult => {}
                Role::Assistant => {
                    self.partial = None;
                    self.messages.push(message);
                }
                Role::User => self.messages.push(message),
            },
            EventData::ToolExecutionEnd(message) => self.messages.push(message),
            EventData::TurnEnd(outcome) => {
                self.running = false;
                self.partial = None;
                if let TurnOutcome::Error(text) = outcome {
                    self.notices.push(text);
                }
            }
            EventData::QueueUpdate(queue) => self.queue = queue,
            EventData::ModelChange(model) => self.model = model,
            EventData::Notice(text) => self.notices.push(text),
            EventData::Ask(ask) => self.asks.push(ask),
            EventData::AskEnd { ask_id, .. } => self.asks.retain(|ask| ask.ask_id != ask_id),
            EventData::QueueDropped(_)
            | EventData::SteerUnconfirmed(_)
            | EventData::ResumeId
            | EventData::Compaction => {}
        }
        Ok(())
    }

    fn stream(&mut self, delta: Delta) {
        let Some(partial) = self.partial.as_mut() else {
            return;
        };
        match (delta, partial.content.last_mut()) {
            (Delta::Text(more), Some(Block::Text(text))) => text.push_str(&more),
            (Delta::Thinking(more), Some(Block::Thinking(text))) => text.push_str(&more),
            (Delta::Text(more), _) => partial.content.push(Block::Text(more)),
            (Delta::Thinking(more), _) => partial.content.push(Block::Thinking(more)),
            (Delta::ToolCall(call), _) => partial.content.push(call),
        }
    }
}

/// The `ack` frame that the client sends for `sub` after one frame moved the
/// `seq` of its state from `from` to `to`: an ack of `to` when the frame
/// passed a multiple of `ACK_EVERY`, so a replay that crosses one acks too.
/// `from` is the `seq` before the frame, or that of the snapshot, the credit
/// base of the server.
pub fn ack(sub: &str, from: u64, to: u64) -> Option<Value> {
    (to / ACK_EVERY > from / ACK_EVERY).then(|| json!({"type": "ack", "sub": sub, "seq": to}))
}
