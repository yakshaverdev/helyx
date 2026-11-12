//! The data shapes of protocol 13 that the fold keeps: messages, blocks, asks,
//! the queue, the snapshot. Each `parse` checks a value by the schema.

use crate::check::{
    Broken, Checked, boolean, field, int, int_key, int_or_null, list_of, number, object, one_of,
    optional, optional_bool, optional_one_of, seq_key, string, string_or_null, strings,
};
use crate::json::Json;
use crate::seq::Seq;
use crate::ui_block::{self, MAX_RESULT_BLOCKS, Shown};

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
        arguments: Json,
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
    /// The UI blocks of a tool result; a message of another role has none.
    pub ui_blocks: Vec<Json>,
}

const STOP_REASONS: &[&str] = &[
    "end_turn",
    "tool_use",
    "max_tokens",
    "refused",
    "aborted",
    "error",
];
const ORIGIN_KINDS: &[&str] = &["user", "background", "product", "hook"];

impl Message {
    pub fn parse(value: &Json) -> Checked<Message> {
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
            ui_blocks: ui_blocks(map, role)?,
        })
    }
}

/// The `ui_blocks` of a message: only a tool result has them, at most
/// `MAX_RESULT_BLOCKS`, as the TUI checks them.
fn ui_blocks(map: &Json, role: Role) -> Checked<Vec<Json>> {
    match (optional(map, "ui_blocks"), role) {
        (None, _) => Ok(vec![]),
        (Some(Json::Array(blocks)), Role::ToolResult) if blocks.len() <= MAX_RESULT_BLOCKS => {
            blocks.iter().map(|b| ui_block::block(b).cloned()).collect()
        }
        _ => Err(Broken("message ui_blocks")),
    }
}

fn optional_string(map: &Json, key: &str) -> Checked<Option<String>> {
    optional(map, key)
        .map(|v| v.as_str().map(str::to_owned).ok_or(Broken("message field")))
        .transpose()
}

pub fn parse_block(value: &Json) -> Checked<Block> {
    let map = object(value, "block")?;
    Ok(match string(map, "type", "block type")? {
        "text" => Block::Text(string(map, "text", "text block")?.to_owned()),
        "thinking" => Block::Thinking(string(map, "thinking", "thinking block")?.to_owned()),
        "tool_call" => parse_tool_call(map)?,
        other => Block::Unknown(other.to_owned()),
    })
}

pub fn parse_tool_call(map: &Json) -> Checked<Block> {
    one_of(map, "type", &["tool_call"], "tool_call")?;
    Ok(Block::ToolCall {
        id: string(map, "id", "tool_call")?.to_owned(),
        name: string(map, "name", "tool_call")?.to_owned(),
        arguments: object(field(map, "arguments", "tool_call")?, "tool_call")?.clone(),
    })
}

fn parse_usage(value: &Json) -> Checked<()> {
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
    pub fn parse(value: &Json) -> Checked<Queue> {
        Queue::from_map(object(value, "queue")?)
    }

    /// `parse` of a value already checked as an object.
    pub fn from_map(map: &Json) -> Checked<Queue> {
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
    pub request: Json,
}

impl Ask {
    pub fn parse(value: &Json) -> Checked<Ask> {
        Ask::from_map(object(value, "ask")?)
    }

    /// `parse` of a value already checked as an object.
    pub fn from_map(map: &Json) -> Checked<Ask> {
        Ok(Ask {
            ask_id: string(map, "ask_id", "ask")?.to_owned(),
            call_id: string(map, "call_id", "ask")?.to_owned(),
            tool: string(map, "tool", "ask")?.to_owned(),
            request: request(field(map, "request", "ask")?)?.clone(),
        })
    }
}

/// The request of an ask: an object, and one with a kind is an input UI
/// block, whose envelope is checked; its size is the ask bound of Core.
fn request(value: &Json) -> Checked<&Json> {
    let map = object(value, "ask request")?;
    if map.get("kind").is_some() {
        ui_block::envelope(map)?;
    }
    Ok(map)
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
    pub seq: Seq,
    pub messages: Vec<Message>,
    /// The count of the older messages that `messages` leaves out; their
    /// pages come from `history`.
    pub older: u64,
    pub turn: Option<Turn>,
    pub model: String,
    pub queue: Queue,
    pub persisting: bool,
    pub asks: Vec<Ask>,
    /// The UI blocks that the session shows, in their order.
    pub ui_blocks: Vec<Shown>,
    /// The activated deferred tool names, in drop order.
    pub activated: Vec<String>,
}

impl Snapshot {
    pub fn parse(value: &Json) -> Checked<Snapshot> {
        let map = object(value, "snapshot")?;
        let turn = match field(map, "turn", "snapshot turn")? {
            Json::Null => None,
            turn => {
                let turn = object(turn, "snapshot turn")?;
                Some(Turn {
                    id: string(turn, "id", "snapshot turn")?.to_owned(),
                    partial: match field(turn, "partial", "snapshot turn")? {
                        Json::Null => None,
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
            Json::Null => {}
            context @ Json::Object(_) => {
                int_or_null(context, "tokens", "snapshot context")?;
                int_or_null(context, "window", "snapshot context")?;
                string_or_null(context, "model", "snapshot context")?;
                int_key(context, "bytes", "snapshot context")?;
            }
            _ => return Err(Broken("snapshot context")),
        }
        Ok(Snapshot {
            instance_id: string(map, "instance_id", "snapshot")?.to_owned(),
            seq: seq_key(map, "seq", "snapshot seq")?,
            messages: list_of(map, "messages", "snapshot messages", Message::parse)?,
            older: int(field(map, "older", "snapshot older")?, "snapshot older")?,
            turn,
            model: string(map, "model", "snapshot model")?.to_owned(),
            queue: Queue::parse(field(map, "queue", "snapshot queue")?)?,
            persisting: boolean(map, "persisting", "snapshot persisting")?,
            asks: list_of(map, "asks", "snapshot asks", Ask::parse)?,
            ui_blocks: list_of(map, "ui_blocks", "snapshot ui_blocks", Shown::parse)?,
            activated: strings(map, "activated", "snapshot activated")?,
        })
    }
}

fn parse_totals(value: &Json) -> Checked<()> {
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
