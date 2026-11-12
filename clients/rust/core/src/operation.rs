//! The operations that a host sends to a session, typed (`docs/features/
//! wire-protocol.md`, "Operations"): `prompt`, `steer`, `follow_up`, `abort`,
//! `stop`, `set_model`, `compact`, the answer of an ask, `start`, `resume`,
//! and `sessions.saved`. A constructor checks its input, so an `Operation` is
//! one that the server takes; `params` gives the params of the schema, and
//! `name` the op. The deadline of each op is the table of the wire,
//! "Deadlines"; the server owns it, and the client records it with the
//! request, not a timer.
//!
//! The text of a message is a Rust `String`, so it is UTF-8 by its type: the
//! core checks its size, and no text reaches the wire that fails the UTF-8
//! check of the server.

use crate::json::{self, Json, object};
use crate::ui_block;
use std::time::Duration;

/// The largest text of a `prompt`, `steer`, `follow_up`, or `compact`
/// (`Helyx.Session.max_text_bytes/0`).
pub const MAX_TEXT_BYTES: usize = 4 * 1_048_576;
/// The largest model ref of a `set_model`, in bytes (`Helyx.ModelRef`).
pub const MAX_MODEL_BYTES: usize = 256;
/// The largest answer of an ask, as its JSON encode
/// (`Helyx.Session.max_answer_bytes/0`).
pub const MAX_ANSWER_BYTES: usize = 16_384;
/// The largest `limit` of a `sessions.saved` page.
pub const MAX_LIMIT: u64 = 256;
/// The bytes of a folder that a `start` or a `resume` takes: the longest
/// path of macOS (`PATH_MAX`), so a field cannot grow past a path.
pub const MAX_CWD_BYTES: usize = 1_024;

/// An operation that the host sends, with its checks done. Its fields are
/// private, so the only way to make one is a constructor, which checks its
/// input: the host cannot hold an operation that the server refuses for its
/// text, its answer, or its folder.
#[derive(Debug, Clone, PartialEq)]
pub struct Operation(Request);

#[derive(Debug, Clone, PartialEq)]
enum Request {
    Prompt {
        session: String,
        text: String,
    },
    Steer {
        session: String,
        text: String,
    },
    FollowUp {
        session: String,
        text: String,
    },
    Abort {
        session: String,
    },
    /// A `stop` of a session: its running turn aborts first, then it ends.
    Stop {
        session: String,
    },
    /// A `set_model` of the next turn of a session.
    SetModel {
        session: String,
        model: String,
    },
    /// A `compact` of a session, with its instructions when it has them.
    Compact {
        session: String,
        text: String,
    },
    Answer {
        session: String,
        ask_id: String,
        answer: Json,
    },
    Start {
        cwd: String,
        model: Option<String>,
    },
    /// A `resume` of a session id.
    Resume {
        id: String,
    },
    /// A `resume` of the newest session of a folder.
    ResumeFolder {
        cwd: String,
    },
    Saved(Saved),
    /// The records feed of the user (`docs/features/live-records.md`).
    RecordsSubscribe,
    RecordsUnsubscribe,
}

/// The params of a `sessions.saved` page: `cwd` for one folder, `after` the
/// `next` of the page before, and `limit` from 1 to `MAX_LIMIT`.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct Saved {
    pub cwd: Option<String>,
    pub after: Option<String>,
    pub limit: Option<u64>,
}

/// Why the core did not make an operation: its input is not one that the
/// server takes, so nothing goes on the wire.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Invalid {
    /// A text over `MAX_TEXT_BYTES`.
    TextTooLarge,
    /// An answer that is not a JSON object.
    AnswerNotObject,
    /// An answer whose JSON encode is over `MAX_ANSWER_BYTES`.
    AnswerTooLarge,
    /// An answer that holds a text which is not a JSON number or container,
    /// such as a number of `NaN`: the server would close the connection.
    AnswerNotJson,
    /// An answer with a number that is not an integer, such as `1e2`: the
    /// server re-encodes a number for the size of the answer, so its own
    /// count can pass the bound that the client counted.
    AnswerNumber,
    /// An answer with an integer of more than 100 digits, which the server
    /// refuses (`Helyx.Message.max_integer_digits/0`).
    AnswerInteger,
    /// A `limit` of 0, or one over `MAX_LIMIT`.
    Limit,
    /// A folder over `MAX_CWD_BYTES`.
    CwdTooLarge,
    /// A model ref over `MAX_MODEL_BYTES`, with whitespace or a control
    /// character, or with an empty provider or model.
    ModelRef,
}

impl Invalid {
    /// The line that a client shows a person.
    pub fn text(self) -> &'static str {
        match self {
            Invalid::TextTooLarge => "the text is over 4 MiB",
            Invalid::AnswerNotObject => "the answer is not a JSON object",
            Invalid::AnswerTooLarge => "the answer is over 16 KiB",
            Invalid::AnswerNotJson => "the answer is not JSON",
            Invalid::AnswerNumber => "the answer has a number that is not an integer",
            Invalid::AnswerInteger => "the answer has an integer over 100 digits",
            Invalid::Limit => "the limit of a page is 1 to 256",
            Invalid::CwdTooLarge => "the folder is over 1024 bytes",
            Invalid::ModelRef => "not a model ref: use provider/model",
        }
    }
}

impl Operation {
    /// A `prompt` of `text`, the message of a turn that is not running.
    pub fn prompt(session: &str, text: &str) -> Result<Operation, Invalid> {
        message(text)?;
        Ok(Operation(Request::Prompt {
            session: session.to_owned(),
            text: text.to_owned(),
        }))
    }

    /// A `steer` of `text`: a message that joins the running turn.
    pub fn steer(session: &str, text: &str) -> Result<Operation, Invalid> {
        message(text)?;
        Ok(Operation(Request::Steer {
            session: session.to_owned(),
            text: text.to_owned(),
        }))
    }

    /// A `follow_up` of `text`: a message that the session runs after the
    /// running turn.
    pub fn follow_up(session: &str, text: &str) -> Result<Operation, Invalid> {
        message(text)?;
        Ok(Operation(Request::FollowUp {
            session: session.to_owned(),
            text: text.to_owned(),
        }))
    }

    /// An `abort` of the running turn of `session`.
    pub fn abort(session: &str) -> Operation {
        Operation(Request::Abort {
            session: session.to_owned(),
        })
    }

    /// A `stop` of `session`: a running turn aborts first, then the session
    /// ends and every subscription of it gets a `session_end`.
    pub fn stop(session: &str) -> Operation {
        Operation(Request::Stop {
            session: session.to_owned(),
        })
    }

    /// A `set_model` of `session`: the next turn uses `model`, and a running
    /// turn keeps its own. The ref takes the bounds of `Helyx.ModelRef`.
    pub fn set_model(session: &str, model: &str) -> Result<Operation, Invalid> {
        model_ref(model)?;
        Ok(Operation(Request::SetModel {
            session: session.to_owned(),
            model: model.to_owned(),
        }))
    }

    /// A `compact` of `session`, with `text` as its instructions. An empty
    /// text sends none, so the default of the server holds.
    pub fn compact(session: &str, text: &str) -> Result<Operation, Invalid> {
        message(text)?;
        Ok(Operation(Request::Compact {
            session: session.to_owned(),
            text: text.to_owned(),
        }))
    }

    /// The `answer` of the ask `ask_id`: a JSON object of at most
    /// `MAX_ANSWER_BYTES` as encoded, whose raw texts are JSON, whose numbers
    /// are integers of at most 100 digits, as `Helyx.Session.check_answer/1`
    /// checks it and the forms send them.
    pub fn answer(session: &str, ask_id: &str, answer: Json) -> Result<Operation, Invalid> {
        check_answer(&answer)?;
        Ok(Operation(Request::Answer {
            session: session.to_owned(),
            ask_id: ask_id.to_owned(),
            answer,
        }))
    }

    /// A `start` of a new session in `cwd`, with the default model of the
    /// server when `model` is none.
    pub fn start(cwd: &str, model: Option<&str>) -> Result<Operation, Invalid> {
        folder(cwd)?;
        Ok(Operation(Request::Start {
            cwd: cwd.to_owned(),
            model: model.map(str::to_owned),
        }))
    }

    /// A `resume` of the session `id`.
    pub fn resume(id: &str) -> Operation {
        Operation(Request::Resume { id: id.to_owned() })
    }

    /// A `resume` of the newest session of `cwd`.
    pub fn resume_folder(cwd: &str) -> Result<Operation, Invalid> {
        folder(cwd)?;
        Ok(Operation(Request::ResumeFolder {
            cwd: cwd.to_owned(),
        }))
    }

    /// A `sessions.saved` page.
    pub fn saved(saved: Saved) -> Result<Operation, Invalid> {
        if let Some(limit) = saved.limit
            && !(1..=MAX_LIMIT).contains(&limit)
        {
            return Err(Invalid::Limit);
        }
        if let Some(cwd) = &saved.cwd {
            folder(cwd)?;
        }
        Ok(Operation(Request::Saved(saved)))
    }

    /// The records feed of the user (`docs/features/live-records.md`).
    pub fn records_subscribe() -> Operation {
        Operation(Request::RecordsSubscribe)
    }

    /// Ends the records subscription of the connection.
    pub fn records_unsubscribe() -> Operation {
        Operation(Request::RecordsUnsubscribe)
    }

    /// The op of the schema.
    pub fn name(&self) -> &'static str {
        match &self.0 {
            Request::Prompt { .. } => "prompt",
            Request::Steer { .. } => "steer",
            Request::FollowUp { .. } => "follow_up",
            Request::Abort { .. } => "abort",
            Request::Stop { .. } => "stop",
            Request::SetModel { .. } => "set_model",
            Request::Compact { .. } => "compact",
            Request::Answer { .. } => "answer",
            Request::Start { .. } => "start",
            Request::Resume { .. } | Request::ResumeFolder { .. } => "resume",
            Request::Saved(_) => "sessions.saved",
            Request::RecordsSubscribe => "records.subscribe",
            Request::RecordsUnsubscribe => "records.unsubscribe",
        }
    }

    /// The session that the operation names, if it names one.
    pub fn session(&self) -> Option<&str> {
        match &self.0 {
            Request::Prompt { session, .. }
            | Request::Steer { session, .. }
            | Request::FollowUp { session, .. }
            | Request::Abort { session }
            | Request::Stop { session }
            | Request::SetModel { session, .. }
            | Request::Compact { session, .. }
            | Request::Answer { session, .. } => Some(session),
            Request::Start { .. }
            | Request::Resume { .. }
            | Request::ResumeFolder { .. }
            | Request::Saved(_)
            | Request::RecordsSubscribe
            | Request::RecordsUnsubscribe => None,
        }
    }

    /// The text of a `prompt`, a `steer`, or a `follow_up`, or the
    /// instructions of a `compact` when it has them.
    pub fn text(&self) -> Option<&str> {
        match &self.0 {
            Request::Prompt { text, .. }
            | Request::Steer { text, .. }
            | Request::FollowUp { text, .. } => Some(text),
            Request::Compact { text, .. } => (!text.is_empty()).then_some(text.as_str()),
            _ => None,
        }
    }

    /// The params of the schema.
    pub fn params(&self) -> Json {
        match &self.0 {
            Request::Prompt { session, text }
            | Request::Steer { session, text }
            | Request::FollowUp { session, text } => object([
                ("session", session.as_str().into()),
                ("text", text.as_str().into()),
            ]),
            Request::Abort { session } | Request::Stop { session } => {
                object([("session", session.as_str().into())])
            }
            Request::SetModel { session, model } => object([
                ("session", session.as_str().into()),
                ("model", model.as_str().into()),
            ]),
            Request::Compact { session, text } => {
                let mut pairs: Vec<(String, Json)> =
                    vec![("session".to_owned(), session.as_str().into())];
                if !text.is_empty() {
                    pairs.push(("text".to_owned(), text.as_str().into()));
                }
                Json::Object(pairs)
            }
            Request::Answer {
                session,
                ask_id,
                answer,
            } => object([
                ("session", session.as_str().into()),
                ("ask_id", ask_id.as_str().into()),
                ("answer", answer.clone()),
            ]),
            Request::Start { cwd, model } => match model {
                None => object([("cwd", cwd.as_str().into())]),
                Some(model) => object([
                    ("cwd", cwd.as_str().into()),
                    ("model", model.as_str().into()),
                ]),
            },
            Request::Resume { id } => object([("id", id.as_str().into())]),
            Request::ResumeFolder { cwd } => object([("cwd", cwd.as_str().into())]),
            Request::Saved(saved) => {
                let mut pairs: Vec<(String, Json)> = vec![];
                if let Some(cwd) = &saved.cwd {
                    pairs.push(("cwd".to_owned(), cwd.as_str().into()));
                }
                if let Some(after) = &saved.after {
                    pairs.push(("after".to_owned(), after.as_str().into()));
                }
                if let Some(limit) = saved.limit {
                    pairs.push(("limit".to_owned(), limit.into()));
                }
                Json::Object(pairs)
            }
            Request::RecordsSubscribe | Request::RecordsUnsubscribe => object([]),
        }
    }
}

/// The deadline of the server for `op` from its `req`, or none for an op that
/// the server does not bound (`docs/features/wire-protocol.md`,
/// "Deadlines"). The core keeps no timer: the host shows it with the request
/// (`client::Client::outstanding`). A `sessions.saved` of a session under a
/// Hub takes 15,000 ms, so that is the bound the client knows.
pub fn deadline(op: &str) -> Option<Duration> {
    let ms = match op {
        // The open of a session waits for its file, so the server gives it no
        // fixed deadline (#834).
        "start" | "resume" => return None,
        "abort" => 46_000,
        "stop" => 77_000,
        "sessions.saved" => 15_000,
        "subscribe" => 5_000,
        _ => 6_000,
    };
    Some(Duration::from_millis(ms))
}

/// The check of an answer, as `Helyx.Session.check_answer/1` makes it: a JSON
/// object whose encode is at most `MAX_ANSWER_BYTES`, whose raw texts are the
/// JSON of the wire, and no integer over 100 digits. The size comes first, so
/// a value over the bound is refused before its texts are read.
fn check_answer(answer: &Json) -> Result<(), Invalid> {
    if !matches!(answer, Json::Object(_)) {
        return Err(Invalid::AnswerNotObject);
    }
    let bytes = ui_block::size(answer).map_err(|_| Invalid::AnswerInteger)?;
    if bytes > MAX_ANSWER_BYTES {
        return Err(Invalid::AnswerTooLarge);
    }
    check_texts(answer)
}

/// The raw texts of `value`: a number parses as a JSON integer, and a
/// container kept as its text (`Json::Deep`) parses as JSON with the same
/// rule inside. A host can make a value whose text is not JSON, and the frame
/// that carries it would close the connection; a number that is not an
/// integer can change its encode size on the server, so the answer is refused
/// before it goes.
fn check_texts(value: &Json) -> Result<(), Invalid> {
    match value {
        Json::Null | Json::Bool(_) | Json::String(_) => Ok(()),
        Json::Number(text) => {
            match json::decode(text) {
                Ok(Json::Number(_)) => {}
                _ => return Err(Invalid::AnswerNotJson),
            }
            let digits = text.strip_prefix('-').unwrap_or(text);
            if digits.is_empty() || !digits.bytes().all(|byte| byte.is_ascii_digit()) {
                return Err(Invalid::AnswerNumber);
            }
            Ok(())
        }
        Json::Array(items) => items.iter().try_for_each(check_texts),
        Json::Object(pairs) => pairs.iter().try_for_each(|(_, value)| check_texts(value)),
        Json::Deep(text) => {
            let decoded = json::decode(text).map_err(|_| Invalid::AnswerNotJson)?;
            check_texts(&decoded)
        }
    }
}

/// One item of the answer of a `form`, in the order of its question
/// (`docs/features/ui-blocks.md`): the labels that the user picked, and the
/// text of the Other line, or none.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct FormAnswer {
    pub selected: Vec<String>,
    pub other: Option<String>,
}

/// One item of the answer of a `form`, as `form_answer` writes it: an item
/// with no `selected` and no `other` leaves both keys out.
pub fn form_answer_item(item: &FormAnswer) -> Json {
    let mut pairs: Vec<(String, Json)> = vec![];
    if !item.selected.is_empty() {
        pairs.push((
            "selected".to_owned(),
            Json::Array(
                item.selected
                    .iter()
                    .map(|label| label.as_str().into())
                    .collect(),
            ),
        ));
    }
    if let Some(other) = item.other.as_deref().filter(|text| !text.is_empty()) {
        pairs.push(("other".to_owned(), other.into()));
    }
    Json::Object(pairs)
}

/// The answer of a `form`: `{"answers": [{"selected": [...], "other": ...}]}`.
pub fn form_answer(items: &[FormAnswer]) -> Json {
    object([(
        "answers",
        Json::Array(items.iter().map(form_answer_item).collect()),
    )])
}

/// The answer of an `approval`: `{"decision": "allow"}` or
/// `{"decision": "deny"}`.
pub fn approval_answer(allow: bool) -> Json {
    object([("decision", if allow { "allow" } else { "deny" }.into())])
}

fn message(text: &str) -> Result<(), Invalid> {
    if text.len() > MAX_TEXT_BYTES {
        return Err(Invalid::TextTooLarge);
    }
    Ok(())
}

/// The check of a model ref, as `Helyx.ModelRef.parse/1` makes it: at most
/// `MAX_MODEL_BYTES` bytes, a provider and a model of at least one character
/// around the first `/`, and no whitespace and no control character. The
/// server also refuses the wider Unicode category C, which the standard
/// library has no table for, and answers `invalid_model_ref`; this check
/// catches the mistake of a person before the round trip.
fn model_ref(model: &str) -> Result<(), Invalid> {
    let (provider, rest) = model.split_once('/').ok_or(Invalid::ModelRef)?;
    let valid = model.len() <= MAX_MODEL_BYTES
        && !provider.is_empty()
        && !rest.is_empty()
        && !model.chars().any(|c| c.is_whitespace() || c.is_control());
    if valid {
        Ok(())
    } else {
        Err(Invalid::ModelRef)
    }
}

fn folder(cwd: &str) -> Result<(), Invalid> {
    if cwd.len() > MAX_CWD_BYTES {
        return Err(Invalid::CwdTooLarge);
    }
    Ok(())
}
