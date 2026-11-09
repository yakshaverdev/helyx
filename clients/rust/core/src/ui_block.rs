//! The UI blocks of protocol 5 (ADR 0011, `docs/features/ui-blocks.md`): the
//! envelope, the bounds that Core admits a block with, and a block that the
//! session shows. A block of a kind that the client does not know passes:
//! a client shows its `text`.

use crate::check::{Broken, Checked, field, object, string, string_or_null};
use crate::json::Json;

/// The bytes of the JSON of a block (`Helyx.UIBlock.max_bytes/0`).
pub const MAX_BYTES: usize = 65_536;
/// The blocks of a tool result (`Helyx.UIBlock.max_result_blocks/0`).
pub const MAX_RESULT_BLOCKS: usize = 8;
/// The digits of an integer in a block (`Helyx.Message.max_integer_digits/0`).
const MAX_INTEGER_DIGITS: usize = 100;
/// The bytes of a kind and of a key.
const MAX_NAME_BYTES: usize = 64;

/// A block that the session shows, from the snapshot or a `ui_block` event:
/// of a tool call, or of the turn when `call_id` is none.
#[derive(Debug, Clone, PartialEq)]
pub struct Shown {
    pub call_id: Option<String>,
    pub key: String,
    pub block: Json,
}

impl Shown {
    pub fn parse(value: &Json) -> Checked<Shown> {
        let map = object(value, "ui block")?;
        let key = string(map, "key", "ui block key")?;
        if key.is_empty() || key.len() > MAX_NAME_BYTES {
            return Err(Broken("ui block key"));
        }
        Ok(Shown {
            call_id: string_or_null(map, "call_id", "ui block")?.map(str::to_owned),
            key: key.to_owned(),
            block: block(field(map, "block", "ui block")?)?.clone(),
        })
    }
}

/// A block as Core admits it, as the TUI checks it: the envelope, at most
/// `MAX_BYTES` of JSON as the server encodes it, and no integer of more than
/// 100 digits. A server cuts a block over the bound, so one over it is a
/// break.
pub fn block(value: &Json) -> Checked<&Json> {
    envelope(value)?;
    if size(value)? > MAX_BYTES {
        return Err(Broken("ui block size"));
    }
    Ok(value)
}

/// The envelope of a block, also of the request of an ask with a kind: a
/// `kind` of 1 to 64 bytes of `a`-`z`, `0`-`9`, and `_`, a string `text`, and
/// `cut` absent or a boolean.
pub fn envelope(value: &Json) -> Checked<()> {
    let map = object(value, "ui block")?;
    let kind = string(map, "kind", "ui block kind")?;
    let name = |b: u8| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'_';
    if kind.is_empty() || kind.len() > MAX_NAME_BYTES || !kind.bytes().all(name) {
        return Err(Broken("ui block kind"));
    }
    string(map, "text", "ui block text")?;
    match map.get("cut") {
        Some(cut) if cut.as_bool().is_none() => Err(Broken("ui block cut")),
        _ => Ok(()),
    }
}

/// The bytes of the JSON encode of `value` by the server, as
/// `Helyx.UIBlock` counts them: a string with the escapes of the encoder of
/// OTP, a number at the text that the server sent, and a container nested
/// past the depth of the decoder at its text, which the server encoded.
/// An integer of more than 100 digits is a break.
fn size(value: &Json) -> Checked<usize> {
    Ok(match value {
        Json::Null | Json::Bool(true) => 4,
        Json::Bool(false) => 5,
        Json::Number(text) => {
            integer_digits(text)?;
            // An integer `-0` decodes to 0, which the server encodes as `0`.
            if text == "-0" { 1 } else { text.len() }
        }
        Json::String(text) => string_bytes(text),
        Json::Array(items) => {
            let mut bytes = 2 + items.len().saturating_sub(1);
            for item in items {
                bytes += size(item)?;
            }
            bytes
        }
        Json::Object(pairs) => {
            let mut bytes = 2 + pairs.len().saturating_sub(1);
            for (key, value) in pairs {
                bytes += string_bytes(key) + 1 + size(value)?;
            }
            bytes
        }
        Json::Deep(text) => {
            deep_integers(text)?;
            text.len()
        }
    })
}

/// The bytes of the JSON string of `text`, the quotes included.
fn string_bytes(text: &str) -> usize {
    let escapes: usize = (text.bytes())
        .map(|b| match b {
            b'"' | b'\\' | 0x08 | 0x0c | b'\n' | b'\r' | b'\t' => 1,
            0..=0x1f => 5,
            _ => 0,
        })
        .sum();
    text.len() + 2 + escapes
}

/// A number text that is an integer has at most 100 digits, the sign not
/// counted.
fn integer_digits(text: &str) -> Checked<()> {
    let integer = !text.bytes().any(|b| matches!(b, b'.' | b'e' | b'E'));
    let digits = text.trim_start_matches('-').len();
    match integer && digits > MAX_INTEGER_DIGITS {
        true => Err(Broken("ui block integer")),
        false => Ok(()),
    }
}

/// The integers of the text of a container that the decoder kept whole: the
/// numbers outside its strings, each by `integer_digits`.
fn deep_integers(text: &str) -> Checked<()> {
    let bytes = text.as_bytes();
    let (mut at, mut in_string) = (0, false);
    while at < bytes.len() {
        let b = bytes[at];
        if in_string {
            match b {
                b'\\' => at += 1,
                b'"' => in_string = false,
                _ => {}
            }
            at += 1;
        } else if b == b'"' {
            in_string = true;
            at += 1;
        } else if b == b'-' || b.is_ascii_digit() {
            let start = at;
            while at < bytes.len()
                && matches!(bytes[at], b'0'..=b'9' | b'-' | b'+' | b'.' | b'e' | b'E')
            {
                at += 1;
            }
            integer_digits(&text[start..at])?;
        } else {
            at += 1;
        }
    }
    Ok(())
}
