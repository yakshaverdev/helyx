//! The usage model of the client: the usage of a message, the session totals,
//! the context estimate, and the texts that a client shows
//! (`docs/features/usage-and-limits.md`, "The footer"). The rules mirror
//! `Helyx.Session.Totals` and `Helyx.Message.bytes/1`, so the live path, a
//! snapshot, and a resume give the same values.
//!
//! The totals and the context estimate keep the forms of the footer, and the
//! display functions are pure, so every client shows the same text.

use crate::check::{
    Checked, boolean, field, int, int_key, int_or_null, number, object, optional, optional_one_of,
    string_or_null,
};
use crate::json::Json;
use crate::message::{Block, Message};

/// The context percent over which the level is `Warn`, as the TUI footer has
/// it (`docs/features/usage-and-limits.md`, "The footer").
pub const WARN_PERCENT: u64 = 70;
/// The context percent over which the level is `Bad`.
pub const BAD_PERCENT: u64 = 90;

/// The usage of one message, as the wire sends it.
#[derive(Debug, Clone, PartialEq)]
pub struct Usage {
    pub input: u64,
    pub output: u64,
    pub cache_read: u64,
    pub cache_write: u64,
    /// The number text as an `f64`, for display only.
    pub cost: Option<f64>,
    /// True for a list price (`cost_kind` `"list"`).
    pub list: bool,
    /// The prompt and the output of the last model call.
    pub context_tokens: Option<u64>,
    /// The context window of the model of the last call.
    pub context_window: Option<u64>,
}

/// The usage sums of a session, as `Helyx.Session.Totals` holds them.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct Totals {
    pub input: u64,
    pub output: u64,
    pub cache_read: u64,
    pub cache_write: u64,
    /// The sum of the known costs, `None` when no cost is known.
    pub cost: Option<f64>,
    /// True when a usage had no cost.
    pub unknown: bool,
    /// True when a known cost is a list price.
    pub list: bool,
}

/// The context estimate of a session: the tokens of the last usage that had
/// `context_tokens`, plus the bytes of the messages after it.
#[derive(Debug, Clone, PartialEq)]
pub struct Context {
    pub tokens: Option<u64>,
    pub window: Option<u64>,
    pub model: Option<String>,
    pub bytes: u64,
}

/// How a client colors a context percent.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Level {
    Normal,
    Warn,
    Bad,
}

/// The usage of one message, as the wire sends it.
pub fn parse_usage(value: &Json) -> Checked<Usage> {
    let map = object(value, "usage")?;
    Ok(Usage {
        input: int_key(map, "input", "usage")?,
        output: int_key(map, "output", "usage")?,
        cache_read: int_key(map, "cache_read", "usage")?,
        cache_write: int_key(map, "cache_write", "usage")?,
        cost: optional(map, "cost")
            .map(|cost| number(cost, "usage cost"))
            .transpose()?,
        list: optional_one_of(map, "cost_kind", &["list", "billed"], "usage cost_kind")?
            == Some("list"),
        context_tokens: optional(map, "context_tokens")
            .map(|n| int(n, "usage context"))
            .transpose()?,
        context_window: optional(map, "context_window")
            .map(|n| int(n, "usage context"))
            .transpose()?,
    })
}

/// The usage totals of a snapshot.
pub fn parse_totals(value: &Json) -> Checked<Totals> {
    let map = object(value, "usage totals")?;
    Ok(Totals {
        input: int_key(map, "input", "usage totals")?,
        output: int_key(map, "output", "usage totals")?,
        cache_read: int_key(map, "cache_read", "usage totals")?,
        cache_write: int_key(map, "cache_write", "usage totals")?,
        cost: match field(map, "cost", "usage totals")? {
            Json::Null => None,
            cost => Some(number(cost, "usage totals")?),
        },
        unknown: boolean(map, "unknown", "usage totals")?,
        list: boolean(map, "list", "usage totals")?,
    })
}

impl Context {
    /// The context state of a snapshot.
    pub fn parse(value: &Json) -> Checked<Context> {
        let map = object(value, "snapshot context")?;
        Ok(Context {
            tokens: int_or_null(map, "tokens", "snapshot context")?,
            window: int_or_null(map, "window", "snapshot context")?,
            model: string_or_null(map, "model", "snapshot context")?.map(str::to_owned),
            bytes: int_key(map, "bytes", "snapshot context")?,
        })
    }
}

/// Adds `message` to the context estimate, as
/// `Helyx.Session.Totals.context/2` does. A usage with `context_tokens` starts
/// a new estimate at its own message; another message adds its bytes to the
/// estimate that it has.
pub fn context(prev: Option<Context>, message: &Message) -> Option<Context> {
    match message
        .usage
        .as_ref()
        .and_then(|usage| usage.context_tokens.map(|tokens| (tokens, usage)))
    {
        Some((tokens, usage)) => Some(Context {
            tokens: Some(tokens),
            window: usage.context_window,
            model: message.model.clone(),
            bytes: 0,
        }),
        None => prev.map(|context| Context {
            bytes: context.bytes.saturating_add(bytes(message)),
            ..context
        }),
    }
}

/// The context state after a compaction, as `Helyx.Session.Totals.compacted/2`
/// does: the tokens become `tokens_after` with no bytes after them; the window
/// and the model stay. With no estimate it stays `None`.
pub fn compacted(prev: Option<Context>, tokens_after: Option<u64>) -> Option<Context> {
    prev.map(|context| Context {
        tokens: tokens_after,
        bytes: 0,
        ..context
    })
}

impl Totals {
    /// Adds the usage of `message`, as `Helyx.Session.Totals.add/2` does. A
    /// usage with no cost keeps the known sum and sets `unknown`.
    ///
    /// The sums saturate: the server sends integers of up to 100 digits, and
    /// `Json::as_u64` reads one past the largest `u64` as `u64::MAX`, so a
    /// sum must not panic.
    pub fn add(&mut self, message: &Message) {
        let Some(usage) = message.usage.as_ref() else {
            return;
        };
        self.input = self.input.saturating_add(usage.input);
        self.output = self.output.saturating_add(usage.output);
        self.cache_read = self.cache_read.saturating_add(usage.cache_read);
        self.cache_write = self.cache_write.saturating_add(usage.cache_write);
        match usage.cost {
            None => self.unknown = true,
            Some(cost) => {
                self.cost = Some(self.cost.unwrap_or(0.0) + cost);
                self.list |= usage.list;
            }
        }
    }
}

/// The bytes of the context estimate of one message: its text and thinking,
/// and for a tool call its name and its JSON arguments, as
/// `Helyx.Message.bytes/1` counts them.
fn bytes(message: &Message) -> u64 {
    message
        .content
        .iter()
        .map(block_bytes)
        .fold(0, u64::saturating_add)
}

fn block_bytes(block: &Block) -> u64 {
    match block {
        Block::Text(text) | Block::Thinking(text) => text.len() as u64,
        Block::ToolCall {
            name, arguments, ..
        } => (name.len() as u64).saturating_add(arguments.encode().len() as u64),
        Block::Unknown(_) => 0,
    }
}

/// A token count in the form of the footer: under 1,000 as it is, else in
/// tenths of `k`, `M`, or `B`, cut and not rounded, and `>999B` at the top.
pub fn tokens_text(n: u64) -> String {
    if n < 1_000 {
        n.to_string()
    } else if n < 1_000_000 {
        tenths(n, 1_000, "k")
    } else if n < 1_000_000_000 {
        tenths(n, 1_000_000, "M")
    } else if n < 1_000_000_000_000 {
        tenths(n, 1_000_000_000, "B")
    } else {
        ">999B".to_owned()
    }
}

fn tenths(n: u64, unit: u64, suffix: &str) -> String {
    // `n` is under 10^12 here, so the product is far within a `u64`.
    let tenths = n * 10 / unit;
    format!("{}.{}{suffix}", tenths / 10, tenths % 10)
}

/// The cost text of the footer: `$1.23`, `≥$1.23` with an unknown part,
/// `$?` when no cost is known, and ` list` after a list price. `None` when
/// no usage carries a cost and none is unknown.
pub fn cost_text(totals: &Totals) -> Option<String> {
    match totals.cost {
        None if !totals.unknown => None,
        None => Some("$?".to_owned()),
        Some(cost) => Some(format!(
            "{}{}{}",
            if totals.unknown { "≥" } else { "" },
            dollars(cost),
            if totals.list { " list" } else { "" }
        )),
    }
}

// Each form is chosen on the rounded value, as the footer chooses it.
fn dollars(cost: f64) -> String {
    let small = rounds(cost * 10_000.0);
    let cents = rounds(cost * 100.0);
    if small < 100 {
        format!("${}", decimals(small, 10_000, 4))
    } else if cents > 9_999_999 {
        ">$99999".to_owned()
    } else {
        format!("${}", decimals(cents, 100, 2))
    }
}

// A cost is non-negative at the wire; a total can reach the float limit, and
// a cast of a float past the largest `u64` saturates there.
fn rounds(n: f64) -> u64 {
    n.round() as u64
}

fn decimals(n: u64, unit: u64, places: usize) -> String {
    format!("{}.{:0width$}", n / unit, n % unit, width = places)
}

/// The context percent of `context` for `model`, as the footer shows it: the
/// estimate over the window, `None` unless both counts are known and the
/// message of the estimate is of `model`. A window of 0 gives no percent.
pub fn context_percent(context: &Context, model: &str) -> Option<u64> {
    let (Some(tokens), Some(window)) = (context.tokens, context.window) else {
        return None;
    };
    if context.model.as_deref() != Some(model) || window == 0 {
        return None;
    }
    // A `u128` holds every product of the two counts, so no sum of tokens and
    // bytes overflows before the division.
    let percent = (u128::from(tokens) + u128::from(context.bytes) / 4) * 100 / u128::from(window);
    Some(u64::try_from(percent).unwrap_or(u64::MAX))
}

/// The level of a context percent: plain at the warn bound, yellow over it,
/// red over the bad bound.
pub fn level(percent: u64) -> Level {
    if percent > BAD_PERCENT {
        Level::Bad
    } else if percent > WARN_PERCENT {
        Level::Warn
    } else {
        Level::Normal
    }
}
