//! The server frames of protocol 12 after the handshake: `res`, `event`,
//! `session_end`, and the records feed frames, each checked by the schema of
//! `docs/features/wire-protocol.md`. A `res` is read by the op of its
//! request, which the caller keeps by `id`.

use crate::check::{
    Broken, Checked, boolean, field, id, int_key, list_of, object, one_of, string, string_or_null,
};
use crate::event::{Event, parse_event};
use crate::json::Json;
use crate::message::{Message, Snapshot};
use crate::records::{self, Record, RecordFrame};

#[derive(Debug, Clone, PartialEq)]
pub enum Subscribed {
    Snapshot(Box<Snapshot>),
    Replay(Vec<Event>),
}

#[derive(Debug, Clone, PartialEq)]
pub struct SavedSession {
    pub id: String,
    pub cwd: String,
    pub model: String,
    pub mtime: u64,
    pub prompt: String,
}

#[derive(Debug, Clone, PartialEq)]
pub struct LiveSession {
    pub id: String,
    pub instance_id: String,
    pub cwd: String,
    pub model: String,
    pub running: bool,
}

/// The result of a request, by its op.
#[derive(Debug, Clone, PartialEq)]
pub enum Reply {
    Subscribe {
        sub: String,
        subscribed: Subscribed,
    },
    Session(String),
    SessionsLive(Vec<LiveSession>),
    SessionsSaved {
        items: Vec<SavedSession>,
        next: Option<String>,
    },
    History {
        messages: Vec<Message>,
        /// The `before` of the page before it; `None` when older messages
        /// exist no more (`more` of the wire).
        next: Option<String>,
    },
    /// The records of the user, waiting first; `more` says that the user
    /// owns more.
    Records {
        records: Vec<Record>,
        more: bool,
    },
    Empty,
}

#[derive(Debug, Clone, PartialEq)]
pub enum ServerFrame {
    Res {
        id: String,
        result: Result<Reply, (String, String)>,
    },
    Event {
        sub: String,
        event: Box<Event>,
    },
    SessionEnd {
        sub: String,
        crashed: bool,
    },
    /// A `record` or `records` frame of the records feed.
    Record(RecordFrame),
}

pub const OPS: &[&str] = &[
    "sessions.live",
    "sessions.saved",
    "start",
    "resume",
    "subscribe",
    "unsubscribe",
    "history",
    "prompt",
    "steer",
    "follow_up",
    "abort",
    "set_model",
    "compact",
    "stop",
    "answer",
    "records.subscribe",
    "records.unsubscribe",
];

/// The error codes of the wire (`test/fixtures/wire/bounds.json`).
pub const ERROR_CODES: &[&str] = &[
    "unknown_op",
    "bad_params",
    "busy",
    "timeout",
    "failed",
    "session_not_found",
    "too_many_sessions",
    "too_many_subscriptions",
    "unknown_sub",
    "instance_changed",
    "unknown_message",
    "invalid_cwd",
    "invalid_model_ref",
    "unknown_provider",
    "not_found",
    "start_failed",
    "invalid_utf8",
    "invalid_origin",
    "queue_full",
    "turn_running",
    "text_too_large",
    "invalid_answer",
    "not_waiting",
    // The codes of a Hub (protocol 6, `docs/features/hub.md`).
    "forbidden",
    "too_many_records",
    "too_many_projects",
    "unknown_project",
    "unknown_token",
    // The codes of the schedules of a Hub (protocol 7, #870).
    "too_many_schedules",
    "unknown_schedule",
    // The codes of the event subscriptions of a Hub (protocol 9, #921).
    "too_many_event_subscriptions",
    "unknown_subscription",
];

/// Checks a frame after `welcome`. `op_of` gives the op of the request with
/// that id; a `res` of no request in flight is a break.
pub fn parse(
    value: &Json,
    op_of: impl FnOnce(&str) -> Option<&'static str>,
) -> Checked<ServerFrame> {
    let map = object(value, "frame")?;
    match string(map, "type", "frame type")? {
        "res" => {
            let req = id(map, "id", "res id")?;
            let op = op_of(req).ok_or(Broken("res of no request"))?;
            let result = if boolean(map, "ok", "res ok")? {
                Ok(parse_result(
                    op,
                    object(field(map, "result", "res result")?, "res result")?,
                )?)
            } else {
                let error = object(field(map, "error", "res error")?, "res error")?;
                let code = one_of(error, "code", ERROR_CODES, "res error code")?;
                Err((
                    code.to_owned(),
                    string(error, "text", "res error text")?.to_owned(),
                ))
            };
            Ok(ServerFrame::Res {
                id: req.to_owned(),
                result,
            })
        }
        "event" => Ok(ServerFrame::Event {
            sub: string(map, "sub", "event sub")?.to_owned(),
            event: Box::new(parse_event(field(map, "event", "event")?)?),
        }),
        "session_end" => Ok(ServerFrame::SessionEnd {
            sub: string(map, "sub", "session_end sub")?.to_owned(),
            crashed: one_of(map, "reason", &["stopped", "crashed"], "session_end reason")?
                == "crashed",
        }),
        "record" | "records" => Ok(ServerFrame::Record(records::parse_frame(value)?)),
        _ => Err(Broken("frame type")),
    }
}

fn parse_result(op: &str, map: &Json) -> Checked<Reply> {
    Ok(match op {
        "subscribe" => {
            let sub = string(map, "sub", "subscribe sub")?.to_owned();
            let subscribed = match (map.get("snapshot"), map.get("replay")) {
                (Some(snapshot), None) => {
                    Subscribed::Snapshot(Box::new(Snapshot::parse(snapshot)?))
                }
                (None, Some(_)) => {
                    Subscribed::Replay(list_of(map, "replay", "replay", parse_event)?)
                }
                _ => return Err(Broken("subscribe result")),
            };
            Reply::Subscribe { sub, subscribed }
        }
        "start" | "resume" => Reply::Session(string(map, "session", "session")?.to_owned()),
        "sessions.live" => {
            Reply::SessionsLive(list_of(map, "sessions", "sessions.live", |value| {
                let item = object(value, "live session")?;
                Ok(LiveSession {
                    id: string(item, "id", "live session")?.to_owned(),
                    instance_id: string(item, "instance_id", "live session")?.to_owned(),
                    cwd: string(item, "cwd", "live session")?.to_owned(),
                    model: string(item, "model", "live session")?.to_owned(),
                    running: one_of(item, "status", &["idle", "running"], "live session")?
                        == "running",
                })
            })?)
        }
        "sessions.saved" => Reply::SessionsSaved {
            items: list_of(map, "items", "sessions.saved", |value| {
                let item = object(value, "saved session")?;
                Ok(SavedSession {
                    id: string(item, "id", "saved session")?.to_owned(),
                    cwd: string(item, "cwd", "saved session")?.to_owned(),
                    model: string(item, "model", "saved session")?.to_owned(),
                    mtime: int_key(item, "mtime", "saved session")?,
                    prompt: string(item, "prompt", "saved session")?.to_owned(),
                })
            })?,
            next: string_or_null(map, "next", "sessions.saved next")?.map(str::to_owned),
        },
        "history" => Reply::History {
            messages: list_of(map, "messages", "history", Message::parse)?,
            next: string_or_null(map, "next", "history next")?.map(str::to_owned),
        },
        // The first list and each full list of the records feed
        // (`docs/features/live-records.md`).
        "records.subscribe" => Reply::Records {
            records: list_of(map, "records", "records.subscribe", records::parse_record)?,
            more: boolean(map, "more", "records.subscribe more")?,
        },
        _ => Reply::Empty,
    })
}
