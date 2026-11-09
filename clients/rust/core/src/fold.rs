//! The fold of the frames of one subscription into the state that a client
//! shows (`test/fixtures/wire/README.md`, "folds.json"). A snapshot replaces
//! the whole state; a replay applies its events in order; an event applies to
//! the state. The state outlives a connection, so a reconnect subscribes with
//! `after` of the last event applied.

use crate::check::{Broken, Checked};
use crate::event::{Delta, Event, EventData, TurnOutcome};
use crate::frame::Subscribed;
use crate::json::{Json, object as obj};
use crate::message::{Ask, Block, Message, Queue, Role};
use crate::seq::Seq;
use crate::ui_block::Shown;

/// The client acks each event whose `seq` is a multiple of this, as the TUI
/// does: far below the 16,384 unacked events that end a subscription (`4408`).
pub const ACK_EVERY: u64 = 1_024;

#[derive(Debug, Clone, Default, PartialEq)]
pub struct State {
    /// The instance of the last snapshot; `None` before the first one.
    pub instance_id: Option<String>,
    /// That of the last snapshot or of the last event applied after it.
    pub seq: Seq,
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
    /// The UI blocks that the session shows, in the order of the first of
    /// each pair of call id and key; the server holds at most 72 in a turn
    /// (`docs/features/ui-blocks.md`).
    pub ui_blocks: Vec<Shown>,
}

impl State {
    /// The params of a `subscribe` for `session`: with `after` when the state
    /// holds a snapshot, so the server can replay the events after it.
    pub fn subscribe_params(&self, session: &str) -> Json {
        match &self.instance_id {
            None => obj([("session", session.into())]),
            Some(instance_id) => obj([
                ("session", session.into()),
                (
                    "after",
                    obj([
                        ("instance_id", instance_id.as_str().into()),
                        ("seq", (&self.seq).into()),
                    ]),
                ),
            ]),
        }
    }

    /// Applies the result of a `subscribe`. A replay answers only a subscribe
    /// with `after`, which the state sends when it holds a snapshot, so a
    /// replay to a state with no snapshot is a break. A replayed event that
    /// `apply` refuses is a break; the events before it stay applied.
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
                    ui_blocks: snapshot.ui_blocks,
                };
                Ok(())
            }
            Subscribed::Replay(_) if self.instance_id.is_none() => Err(Broken("replay")),
            Subscribed::Replay(events) => {
                events.into_iter().try_for_each(|event| self.apply(event))
            }
        }
    }

    /// Applies one event of the subscription. An event of a type that the
    /// client does not know moves `seq` only. Every event of a subscription
    /// comes after its snapshot or its replay and is of that instance: a
    /// restart ends the subscription with `session_end`, and a replay comes
    /// from the ring of the instance of `after`. So an event before a
    /// snapshot, of another instance, or whose `seq` is not the next one (O4:
    /// no gap, no duplicate) is a break, and changes nothing.
    pub fn apply(&mut self, event: Event) -> Checked<()> {
        if self.instance_id.as_deref() != Some(event.instance_id.as_str()) {
            return Err(Broken("event instance"));
        }
        if event.seq != self.seq.next() {
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
            // The result of a call drops the blocks of its call id.
            EventData::ToolExecutionEnd(message) => {
                self.ui_blocks.retain(|b| b.call_id != message.tool_call_id);
                self.messages.push(message);
            }
            EventData::TurnEnd(outcome) => {
                self.running = false;
                self.partial = None;
                self.ui_blocks.clear();
                if let TurnOutcome::Error(text) = outcome {
                    self.notices.push(text);
                }
            }
            EventData::QueueUpdate(queue) => self.queue = queue,
            EventData::ModelChange(model) => self.model = model,
            EventData::Notice(text) => self.notices.push(text),
            EventData::Ask(ask) => self.asks.push(ask),
            EventData::AskEnd { ask_id, .. } => self.asks.retain(|ask| ask.ask_id != ask_id),
            // A block of the same call id and key replaces it in its place.
            EventData::UiBlock(shown) => {
                let same = |b: &Shown| b.call_id == shown.call_id && b.key == shown.key;
                match self.ui_blocks.iter_mut().find(|b| same(b)) {
                    Some(old) => *old = shown,
                    None => self.ui_blocks.push(shown),
                }
            }
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
pub fn ack(sub: &str, from: &Seq, to: &Seq) -> Option<Json> {
    Seq::passes(from, to, ACK_EVERY).then(|| {
        obj([
            ("type", "ack".into()),
            ("sub", sub.into()),
            ("seq", to.into()),
        ])
    })
}
