//! The events of protocol 15, the `event` of an `event` frame and of a replay:
//! the envelope of every event, and the data of each type that the client
//! knows, each checked by the schema of `docs/features/wire-protocol.md`.

use crate::check::{
    Broken, Checked, boolean, field, int_key, int_or_null, list_of, object, one_of, optional,
    optional_one_of, seq_key, string, string_or_null, strings,
};
use crate::json::Json;
use crate::message::{Ask, Block, Message, Queue, Role, parse_tool_call};
use crate::seq::Seq;
use crate::ui_block::Shown;

/// What `message_end` says of a turn that did not end well.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum MessageError {
    Aborted,
    Failed(String),
}

#[derive(Debug, Clone, PartialEq)]
pub enum Delta {
    Text(String),
    Thinking(String),
    ToolCall(Block),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TurnOutcome {
    Done,
    Aborted,
    Error(String),
}

/// The data of an event of a type that the client knows.
#[derive(Debug, Clone, PartialEq)]
pub enum EventData {
    TurnStart,
    MessageStart(Message),
    MessageUpdate(Delta),
    MessageEnd {
        message: Message,
        error: Option<MessageError>,
    },
    ToolExecutionEnd(Message),
    TurnEnd(TurnOutcome),
    QueueUpdate(Queue),
    QueueDropped(Vec<Message>),
    ModelChange(String),
    ResumeId,
    SteerUnconfirmed(Message),
    /// A compaction of the session: `tokens_after` is the context estimate
    /// that the server set, `None` when it is unknown.
    Compaction {
        tokens_after: Option<u64>,
    },
    Notice(String),
    Ask(Ask),
    AskEnd {
        ask_id: String,
        answered: bool,
    },
    UiBlock(Shown),
    /// The activated deferred tool names, in drop order.
    ToolsChange(Vec<String>),
}

#[derive(Debug, Clone, PartialEq)]
pub struct Event {
    pub session_id: String,
    pub instance_id: String,
    pub turn_id: Option<String>,
    pub seq: Seq,
    /// `None` for an event of a type that the client does not know: it skips
    /// the event, and the event still moves `seq`.
    pub data: Option<EventData>,
}

/// Checks an event. The envelope is checked for every event, so an event of
/// a type that the client does not know still has a valid `seq`.
pub fn parse_event(value: &Json) -> Checked<Event> {
    let map = object(value, "event")?;
    let kind = string(map, "type", "event type")?;
    let data = object(field(map, "data", "event data")?, "event data")?;
    Ok(Event {
        session_id: string(map, "session_id", "event session_id")?.to_owned(),
        instance_id: string(map, "instance_id", "event instance_id")?.to_owned(),
        turn_id: string_or_null(map, "turn_id", "event turn_id")?.map(str::to_owned),
        seq: seq_key(map, "seq", "event seq")?,
        data: parse_data(kind, data)?,
    })
}

fn message(data: &Json, what: &'static str) -> Checked<Message> {
    Message::parse(field(data, "message", what)?)
}

/// `message` of `data`, which must have `role`.
fn message_with(data: &Json, role: Role, what: &'static str) -> Checked<Message> {
    has_role(message(data, what)?, role, what)
}

fn has_role(message: Message, role: Role, what: &'static str) -> Checked<Message> {
    (message.role == role)
        .then_some(message)
        .ok_or(Broken(what))
}

fn parse_message_error(value: &Json) -> Checked<MessageError> {
    let error = object(value, "message_end error")?;
    let kind = one_of(error, "kind", &["aborted", "failed"], "message_end error")?;
    Ok(match kind {
        "aborted" => MessageError::Aborted,
        _ => MessageError::Failed(string(error, "text", "message_end error")?.to_owned()),
    })
}

/// The delta of a `message_update`: exactly one of its three keys.
fn parse_delta(data: &Json) -> Checked<Delta> {
    let mut keys = ["text_delta", "thinking_delta", "tool_call"]
        .into_iter()
        .filter(|key| data.get(key).is_some());
    Ok(match (keys.next(), keys.next()) {
        (Some("text_delta"), None) => {
            Delta::Text(string(data, "text_delta", "text_delta")?.to_owned())
        }
        (Some("thinking_delta"), None) => {
            Delta::Thinking(string(data, "thinking_delta", "thinking_delta")?.to_owned())
        }
        (Some(_), None) => Delta::ToolCall(parse_tool_call(object(
            field(data, "tool_call", "tool_call")?,
            "tool_call",
        )?)?),
        _ => return Err(Broken("message_update")),
    })
}

/// The data of an event of type `kind`; `None` for a type that the client
/// does not know.
fn parse_data(kind: &str, data: &Json) -> Checked<Option<EventData>> {
    Ok(Some(match kind {
        "turn_start" => {
            let origins = &["provider", "compaction"];
            optional_one_of(data, "origin", origins, "turn_start origin")?;
            EventData::TurnStart
        }
        "message_start" => EventData::MessageStart(message(data, "message_start")?),
        "message_update" => EventData::MessageUpdate(parse_delta(data)?),
        "message_end" => EventData::MessageEnd {
            message: message(data, "message_end")?,
            error: optional(data, "error")
                .map(parse_message_error)
                .transpose()?,
        },
        "tool_execution_end" => {
            EventData::ToolExecutionEnd(message_with(data, Role::ToolResult, "tool_execution_end")?)
        }
        "turn_end" => EventData::TurnEnd(
            match one_of(data, "outcome", &["done", "aborted", "error"], "turn_end")? {
                "done" => TurnOutcome::Done,
                "aborted" => TurnOutcome::Aborted,
                _ => TurnOutcome::Error(string(data, "error", "turn_end error")?.to_owned()),
            },
        ),
        "queue_update" => EventData::QueueUpdate(Queue::from_map(data)?),
        "queue_dropped" => {
            EventData::QueueDropped(list_of(data, "messages", "queue_dropped", |value| {
                has_role(Message::parse(value)?, Role::User, "queue_dropped")
            })?)
        }
        "model_change" => EventData::ModelChange(string(data, "model", "model_change")?.to_owned()),
        "resume_id" => {
            string(data, "provider", "resume_id")?;
            string(data, "resume_id", "resume_id")?;
            boolean(data, "lost", "resume_id")?;
            int_key(data, "cut", "resume_id")?;
            EventData::ResumeId
        }
        "steer_unconfirmed" => {
            EventData::SteerUnconfirmed(message_with(data, Role::User, "steer_unconfirmed")?)
        }
        "compaction" => {
            one_of(data, "trigger", &["manual", "auto"], "compaction")?;
            int_or_null(data, "tokens_before", "compaction")?;
            let tokens_after = int_or_null(data, "tokens_after", "compaction")?;
            EventData::Compaction { tokens_after }
        }
        "notice" => EventData::Notice(string(data, "text", "notice")?.to_owned()),
        "ask" => EventData::Ask(Ask::from_map(data)?),
        "ask_end" => EventData::AskEnd {
            ask_id: string(data, "ask_id", "ask_end")?.to_owned(),
            answered: one_of(data, "outcome", &["answered", "ended"], "ask_end")? == "answered",
        },
        "ui_block" => EventData::UiBlock(Shown::parse(data)?),
        "tools_change" => EventData::ToolsChange(strings(data, "activated", "tools_change")?),
        _ => return Ok(None),
    }))
}
