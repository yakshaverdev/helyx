//! The JSON of the wire, lossless: a number keeps its text, so an integer of
//! a tool call keeps every digit, and no object key has a meaning of its own.
//! `decode` holds the outbound decode bounds of `docs/features/wire-protocol.md`
//! ("Bounds"), and keeps a container nested past `Limits::depth` as its text.
//! The grammar, the escaping, and the text of a number are the ones of
//! `serde_json` (`docs/features/client-kit.md`, "Decoded").

use serde::Serialize;
use serde::ser::{SerializeMap, Serializer};
use serde_json::value::RawValue;

/// A JSON value. An object keeps its pairs in their order; a lookup takes the
/// first pair of a key, as `JSON.decode/1` of Elixir and the frame decoder
/// of the server and the TUI (`Helyx.Transport.WebSocket.Frame`) do.
#[derive(Debug, Clone, PartialEq)]
pub enum Json {
    Null,
    Bool(bool),
    /// The text of the number, as it came.
    Number(String),
    String(String),
    Array(Vec<Json>),
    Object(Vec<(String, Json)>),
    /// An array or an object nested past `Limits::depth`, as its text: it is
    /// checked by the grammar and the bounds as any value, with no stack
    /// for its nesting, and no lookup reads into it. Only an argument of a
    /// tool call, a request of an ask, or an answer nests that deep.
    Deep(String),
}

/// The bounds of one decode.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Limits {
    /// The bytes of the text.
    pub frame_bytes: usize,
    /// The values, counted as the server counts them: each value, and each
    /// object key of the tree. A container past `depth` is kept as its text,
    /// and the frame bound holds it.
    pub values: usize,
    /// The characters of an integer, the minus sign included.
    pub integer_chars: usize,
    /// The nesting of arrays and objects past which a container is kept as
    /// its text (`Json::Deep`), so the stack of the parse, the clone, and
    /// the drop of a value is bounded. Not a bound of the frame: the values
    /// bound its nesting, as for the TUI.
    pub depth: usize,
}

/// The bounds of a server frame: the outbound decode bounds of the wire (the
/// largest frame that the server sends by its bounds, joined from parts), and
/// the nesting past which this client keeps a container as its text.
pub const WIRE: Limits = Limits {
    frame_bytes: 1_611_661_312,
    values: 38_797_312,
    integer_chars: 1_024,
    depth: 64,
};

impl Json {
    /// The value of `key` in an object.
    pub fn get(&self, key: &str) -> Option<&Json> {
        match self {
            Json::Object(pairs) => pairs.iter().find(|(k, _)| k == key).map(|(_, v)| v),
            _ => None,
        }
    }

    pub fn is_null(&self) -> bool {
        matches!(self, Json::Null)
    }

    pub fn as_str(&self) -> Option<&str> {
        match self {
            Json::String(text) => Some(text),
            _ => None,
        }
    }

    pub fn as_bool(&self) -> Option<bool> {
        match self {
            Json::Bool(b) => Some(*b),
            _ => None,
        }
    }

    pub fn as_array(&self) -> Option<&[Json]> {
        match self {
            Json::Array(items) => Some(items),
            _ => None,
        }
    }

    /// An `int` of the schema, an integer >= 0 of any size, judged by its
    /// value (`-0` is zero, as `JSON.decode/1` of Elixir reads it), and kept
    /// at most `u64::MAX`: a larger one is taken and kept as `u64::MAX`. A
    /// `seq`, which the fold counts on from, is kept exact (`crate::seq`).
    pub fn as_u64(&self) -> Option<u64> {
        match self {
            Json::Number(text) => natural(text).map(|digits| digits.parse().unwrap_or(u64::MAX)),
            _ => None,
        }
    }

    /// A number >= 0, as a float; `-0.0` is zero, as the `>= 0` of the server.
    pub fn as_nonnegative_f64(&self) -> Option<f64> {
        match self {
            Json::Number(text) => text.parse().ok().filter(|n: &f64| *n >= 0.0),
            _ => None,
        }
    }

    /// The JSON text of the value.
    pub fn encode(&self) -> String {
        serde_json::to_string(self).expect("a Json is JSON")
    }
}

impl Serialize for Json {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: Serializer,
    {
        match self {
            Json::Null => serializer.serialize_unit(),
            Json::Bool(value) => serializer.serialize_bool(*value),
            // The text as it came: a number, or a container that the decoder
            // kept whole. Neither is read back into a value here.
            Json::Number(text) | Json::Deep(text) => raw(text).serialize(serializer),
            Json::String(text) => serializer.serialize_str(text),
            Json::Array(items) => items.serialize(serializer),
            Json::Object(pairs) => {
                let mut map = serializer.serialize_map(Some(pairs.len()))?;
                for (key, value) in pairs {
                    map.serialize_entry(key, value)?;
                }
                map.end()
            }
        }
    }
}

/// The JSON text of a number or of a deep container, to write as it is.
fn raw(text: &str) -> Box<RawValue> {
    RawValue::from_string(text.to_owned()).expect("the decoder kept JSON text")
}

impl From<&str> for Json {
    fn from(text: &str) -> Json {
        Json::String(text.to_owned())
    }
}

impl From<u64> for Json {
    fn from(n: u64) -> Json {
        Json::Number(n.to_string())
    }
}

/// The digits of the text of a JSON integer >= 0, judged by its value: `-0`
/// is `0`, as `JSON.decode/1` of Elixir reads it. `None` for another text.
pub(crate) fn natural(text: &str) -> Option<&str> {
    match text {
        "-0" => Some("0"),
        _ if !text.is_empty() && text.bytes().all(|b| b.is_ascii_digit()) => Some(text),
        _ => None,
    }
}

/// An object of `pairs`, for the frames that the client sends.
pub fn object<const N: usize>(pairs: [(&str, Json); N]) -> Json {
    Json::Object(pairs.into_iter().map(|(k, v)| (k.to_owned(), v)).collect())
}

mod decode;
pub use decode::{decode, decode_within};
