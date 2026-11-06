//! The data shapes of protocol 3 that the fold keeps: messages, blocks, asks,
//! the queue, the snapshot. Each `parse` checks a value by the schema.

use crate::check::{
    Broken, Checked, boolean, field, int, int_key, int_or_null, list_of, number, object, one_of,
    optional, optional_bool, optional_one_of, string, string_or_null,
};
use serde_json::{Map, Value};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Role {
    User,
    Assistant,
    ToolResult,
}

/// A block of a message. A block kind that the client does not know keeps its
/// kind, and a renderer shows a placeholder for it (ADR 0006, the tolerant reader).
#[derive(Debug, Clone, PartialEq)]
pub enum Block {
    Text(String),
    Thinking(String),
    ToolCall {
        id: String,
        name: String,
        arguments: Map<String, Value>,
    },
    Unknown(String),
}

#[derive(Debug, Clone, PartialEq)]
pub struct Message {
    pub id: String,
    pub role: Role,
    pub content: Vec<Block>,
    pub model: Option<String>,
    pub stop_reason: Option<String>,
    pub tool_call_id: Option<String>,
    pub tool_name: Option<String>,
    pub is_error: bool,
}

const STOP_REASONS: &[&str] = &[
    "end_turn",
    "tool_use",
    "max_tokens",
    "refused",
    "aborted",
    "error",
];
const ORIGIN_KINDS: &[&str] = &["user", "background", "product", "unknown"];

impl Message {
    pub fn parse(value: &Value) -> Checked<Message> {
        let map = object(value, "message")?;
        let role = match string(map, "role", "message role")? {
            "user" => Role::User,
            "assistant" => Role::Assistant,
            "tool_result" => Role::ToolResult,
            _ => return Err(Broken("message role")),
        };
        if let Some(origin) = optional(map, "origin") {
            let origin = object(origin, "message origin")?;
            one_of(origin, "kind", ORIGIN_KINDS, "message origin")?;
            string_or_null(origin, "id", "message origin")?;
        }
        if let Some(usage) = optional(map, "usage") {
            parse_usage(usage)?;
        }
        Ok(Message {
            id: string(map, "id", "message id")?.to_owned(),
            role,
            content: list_of(map, "content", "message content", parse_block)?,
            model: optional_string(map, "model")?,
            stop_reason: optional_one_of(map, "stop_reason", STOP_REASONS, "stop_reason")?
                .map(str::to_owned),
            tool_call_id: optional_string(map, "tool_call_id")?,
            tool_name: optional_string(map, "tool_name")?,
            is_error: optional_bool(map, "is_error", "is_error")?,
        })
    }
}

fn optional_string(map: &Map<String, Value>, key: &str) -> Checked<Option<String>> {
    optional(map, key)
        .map(|v| v.as_str().map(str::to_owned).ok_or(Broken("message field")))
        .transpose()
}

pub fn parse_block(value: &Value) -> Checked<Block> {
    let map = object(value, "block")?;
    Ok(match string(map, "type", "block type")? {
        "text" => Block::Text(string(map, "text", "text block")?.to_owned()),
        "thinking" => Block::Thinking(string(map, "thinking", "thinking block")?.to_owned()),
        "tool_call" => parse_tool_call(map)?,
        other => Block::Unknown(other.to_owned()),
    })
}

pub fn parse_tool_call(map: &Map<String, Value>) -> Checked<Block> {
    one_of(map, "type", &["tool_call"], "tool_call")?;
    Ok(Block::ToolCall {
        id: string(map, "id", "tool_call")?.to_owned(),
        name: string(map, "name", "tool_call")?.to_owned(),
        arguments: object(field(map, "arguments", "tool_call")?, "tool_call")?.clone(),
    })
}

fn parse_usage(value: &Value) -> Checked<()> {
    let map = object(value, "usage")?;
    for key in ["input", "output", "cache_read", "cache_write"] {
        int_key(map, key, "usage")?;
    }
    if let Some(cost) = optional(map, "cost") {
        number(cost, "usage cost")?;
    }
    optional_one_of(map, "cost_kind", &["list", "billed"], "usage cost_kind")?;
    for key in ["context_tokens", "context_window"] {
        if let Some(n) = optional(map, key) {
            int(n, "usage context")?;
        }
    }
    Ok(())
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct Queue {
    pub steers: u64,
    pub follow_ups: u64,
    pub running: u64,
    pub held: u64,
    pub waiting: u64,
}

impl Queue {
    pub fn parse(value: &Value) -> Checked<Queue> {
        Queue::from_map(object(value, "queue")?)
    }

    /// `parse` of a value already checked as an object.
    pub fn from_map(map: &Map<String, Value>) -> Checked<Queue> {
        Ok(Queue {
            steers: int_key(map, "steers", "queue")?,
            follow_ups: int_key(map, "follow_ups", "queue")?,
            running: int_key(map, "running", "queue")?,
            held: int_key(map, "held", "queue")?,
            waiting: int_key(map, "waiting", "queue")?,
        })
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct Ask {
    pub ask_id: String,
    pub call_id: String,
    pub tool: String,
    pub request: Map<String, Value>,
}

impl Ask {
    pub fn parse(value: &Value) -> Checked<Ask> {
        Ask::from_map(object(value, "ask")?)
    }

    /// `parse` of a value already checked as an object.
    pub fn from_map(map: &Map<String, Value>) -> Checked<Ask> {
        Ok(Ask {
            ask_id: string(map, "ask_id", "ask")?.to_owned(),
            call_id: string(map, "call_id", "ask")?.to_owned(),
            tool: string(map, "tool", "ask")?.to_owned(),
            request: object(field(map, "request", "ask")?, "ask request")?.clone(),
        })
    }
}

/// The turn that runs at the snapshot, with its partial message.
#[derive(Debug, Clone, PartialEq)]
pub struct Turn {
    pub id: String,
    pub partial: Option<Message>,
    pub elapsed_ms: u64,
}

#[derive(Debug, Clone, PartialEq)]
pub struct Snapshot {
    pub instance_id: String,
    pub seq: u64,
    pub messages: Vec<Message>,
    pub more: bool,
    pub turn: Option<Turn>,
    pub model: String,
    pub queue: Queue,
    pub persisting: bool,
    pub asks: Vec<Ask>,
}

impl Snapshot {
    pub fn parse(value: &Value) -> Checked<Snapshot> {
        let map = object(value, "snapshot")?;
        let turn = match field(map, "turn", "snapshot turn")? {
            Value::Null => None,
            turn => {
                let turn = object(turn, "snapshot turn")?;
                Some(Turn {
                    id: string(turn, "id", "snapshot turn")?.to_owned(),
                    partial: match field(turn, "partial", "snapshot turn")? {
                        Value::Null => None,
                        // Only an assistant message streams, as in the TUI.
                        partial => match Message::parse(partial)? {
                            message if message.role == Role::Assistant => Some(message),
                            _ => return Err(Broken("snapshot partial")),
                        },
                    },
                    elapsed_ms: int_key(turn, "elapsed_ms", "snapshot turn")?,
                })
            }
        };
        parse_totals(field(map, "usage", "snapshot usage")?)?;
        match field(map, "context", "snapshot context")? {
            Value::Null => {}
            Value::Object(context) => {
                int_or_null(context, "tokens", "snapshot context")?;
                int_or_null(context, "window", "snapshot context")?;
                string_or_null(context, "model", "snapshot context")?;
                int_key(context, "bytes", "snapshot context")?;
            }
            _ => return Err(Broken("snapshot context")),
        }
        Ok(Snapshot {
            instance_id: string(map, "instance_id", "snapshot")?.to_owned(),
            seq: int_key(map, "seq", "snapshot seq")?,
            messages: list_of(map, "messages", "snapshot messages", Message::parse)?,
            more: boolean(map, "more", "snapshot more")?,
            turn,
            model: string(map, "model", "snapshot model")?.to_owned(),
            queue: Queue::parse(field(map, "queue", "snapshot queue")?)?,
            persisting: boolean(map, "persisting", "snapshot persisting")?,
            asks: list_of(map, "asks", "snapshot asks", Ask::parse)?,
        })
    }
}

fn parse_totals(value: &Value) -> Checked<()> {
    let map = object(value, "usage totals")?;
    for key in ["input", "output", "cache_read", "cache_write"] {
        int_key(map, key, "usage totals")?;
    }
    let cost = field(map, "cost", "usage totals")?;
    if !cost.is_null() {
        number(cost, "usage totals")?;
    }
    boolean(map, "unknown", "usage totals")?;
    boolean(map, "list", "usage totals")?;
    Ok(())
}
