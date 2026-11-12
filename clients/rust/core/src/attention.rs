//! What needs the user, from one change of the state of the followed session
//! (`docs/features/client-kit.md`, slice 4): a new ask that blocks the turn,
//! a turn that ended badly, and a turn that ended well. The rule is here so
//! that every host shows the same attention: a host only delivers it.

use crate::event::TurnOutcome;
use crate::fold::State;
use crate::message::{Block, Role};

/// The bytes of the text of an attention. A notification shows about two
/// lines, and the text is model output, so the text is cut here.
pub const MAX_ATTENTION_BYTES: usize = 200;

/// What a host tells the user about one change of the followed session.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Attention {
    Done(String),
    Failed(String),
    Waiting(String),
}

impl Attention {
    /// The one line that a host shows: what happened, and the text.
    pub fn line(&self) -> String {
        match self {
            Attention::Done(text) => format!("done: {text}"),
            Attention::Failed(text) => format!("failed: {text}"),
            Attention::Waiting(text) => format!("waiting for your answer: {text}"),
        }
    }
}

/// The facts of a state that the rule reads from the state before a change:
/// the state holds the whole transcript, so a host keeps these instead of a
/// copy of it for every frame.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Seen {
    instance_id: Option<String>,
    running: bool,
    /// The ids of the open asks.
    asks: Vec<String>,
    /// The count of the notices.
    notices: usize,
}

impl Seen {
    /// The facts of `state` that the rule reads.
    pub fn of(state: &State) -> Seen {
        Seen {
            instance_id: state.instance_id.clone(),
            running: state.running,
            asks: state.asks.iter().map(|ask| ask.ask_id.clone()).collect(),
            notices: state.notices.len(),
        }
    }
}

/// The attention of a change from `before` to `after`, when the change needs
/// the user. One change gives at most one attention, and an answer comes
/// first: it blocks the agent. A state that a snapshot or a replay made is
/// history that the user has seen or that is old, and a state of another
/// instance is another session, so neither gives an attention.
pub fn attention(before: &Seen, after: &State) -> Option<Attention> {
    if after.from_snapshot || before.instance_id != after.instance_id {
        return None;
    }
    if let Some(text) = waiting(before, after) {
        return Some(Attention::Waiting(text));
    }
    // `running` falls only at a `turn_end`, which records the outcome.
    if before.running && !after.running {
        return Some(match after.outcome {
            Some(TurnOutcome::Done) => Attention::Done(done(after)),
            Some(TurnOutcome::Aborted) => Attention::Failed(notice(before, after, "turn aborted")),
            _ => Attention::Failed(notice(before, after, "turn failed")),
        });
    }
    None
}

/// The text of an ask that `after` opened and `before` did not, when the ask
/// is of a kind that takes an answer: a `form` or an `approval`.
fn waiting(before: &Seen, after: &State) -> Option<String> {
    let ask = (after.asks.iter()).find(|ask| !before.asks.contains(&ask.ask_id))?;
    let block = ask.block()?;
    matches!(block.kind.as_str(), "form" | "approval").then(|| bounded(clean(&block.text)))
}

/// The newest notice that `after` added, else `fallback`: an `error` turn
/// pushes its text as a notice, and an abort pushes none.
fn notice(before: &Seen, after: &State, fallback: &str) -> String {
    match after.notices.last() {
        Some(text) if after.notices.len() > before.notices => bounded(clean(text)),
        _ => fallback.to_owned(),
    }
}

/// The first non-empty line of the newest assistant text of `after`, else
/// `turn ended` when the turn wrote no text.
fn done(after: &State) -> String {
    let line = (after.messages.iter().rev())
        .filter(|message| message.role == Role::Assistant)
        .flat_map(|message| message.content.iter().rev())
        .find_map(|block| match block {
            Block::Text(text) => first_line(text),
            _ => None,
        });
    line.unwrap_or_else(|| "turn ended".to_owned())
}

/// The first line of `text` that has a character after cleaning, cleaned and
/// bounded.
fn first_line(text: &str) -> Option<String> {
    (text.lines())
        .map(clean)
        .find(|line| !line.is_empty())
        .map(bounded)
}

/// The text of an attention: a control character and any other whitespace
/// become one space, and the ends have none.
fn clean(text: &str) -> String {
    let mut out = String::with_capacity(text.len().min(MAX_ATTENTION_BYTES));
    for c in text.chars() {
        if c.is_control() || c.is_whitespace() {
            if !out.is_empty() && !out.ends_with(' ') {
                out.push(' ');
            }
        } else {
            out.push(c);
        }
    }
    let end = out.trim_end().len();
    out.truncate(end);
    out
}

/// `text` cut at `MAX_ATTENTION_BYTES` at a character boundary, with `…`
/// when a part is left out.
fn bounded(text: String) -> String {
    if text.len() <= MAX_ATTENTION_BYTES {
        return text;
    }
    let mut end = MAX_ATTENTION_BYTES;
    while !text.is_char_boundary(end) {
        end -= 1;
    }
    let mut out = text[..end].to_owned();
    let end = out.trim_end().len();
    out.truncate(end);
    out.push('…');
    out
}
