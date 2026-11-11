//! The decoder of the JSON of a server frame, within the bounds of
//! `Limits` (`docs/features/client-kit.md`, the `json` bullet of "Slices" and
//! the table "Bounds"), on `serde_json`: the grammar, the string escapes, the
//! text of a number, and the span of a container are its. This module keeps
//! the rules of the wire that its own value type does not: the first of two
//! equal keys, the bounds, and a container past `Limits::depth` kept as its
//! text.

use super::{Json, Limits, WIRE};
use crate::check::{Broken, Checked};
use serde::Deserialize;
use serde::de::{self, DeserializeSeed, Deserializer, MapAccess, SeqAccess, Visitor};
use serde_json::value::RawValue;
use std::cell::Cell;
use std::fmt;

/// Decodes the text of one server frame within the bounds of `WIRE`. A text
/// over a bound, or that is not JSON, is a break of the server.
pub fn decode(text: &str) -> Checked<Json> {
    decode_within(text, WIRE)
}

/// Decodes `text` within `limits`.
pub fn decode_within(text: &str, limits: Limits) -> Checked<Json> {
    if text.len() > limits.frame_bytes {
        return Err(Broken("frame size"));
    }
    let state = State {
        values: Cell::new(0),
        caught: Cell::new(None),
    };
    let mut de = serde_json::Deserializer::from_str(text);
    let seed = Seed {
        limits,
        state: &state,
        depth: 0,
    };
    let Ok(value) = seed.deserialize(&mut de) else {
        return Err(Broken(state.caught.get().unwrap_or("json")));
    };
    if de.end().is_err() {
        return Err(Broken("json"));
    }
    Ok(value)
}

/// The values counted so far, and the bound that the parse broke, if it did.
struct State {
    values: Cell<usize>,
    caught: Cell<Option<&'static str>>,
}

impl State {
    /// Counts one value, as the server counts it: each value and each object
    /// key.
    fn count<E: de::Error>(&self, limits: Limits) -> Result<(), E> {
        let values = self.values.get() + 1;
        self.values.set(values);
        if values > limits.values {
            return Err(self.fault("json values"));
        }
        Ok(())
    }

    /// The error of a bound, kept for `decode_within`, which answers a
    /// `Broken`.
    fn fault<E: de::Error>(&self, what: &'static str) -> E {
        self.caught.set(Some(what));
        E::custom(what)
    }
}

/// One value at `depth` containers. The value is read first as its text
/// (`serde_json::value::RawValue`), so a number keeps every digit and an
/// object keeps every key; a container past `Limits::depth` is kept as that
/// text, with no stack for its nesting.
#[derive(Clone, Copy)]
struct Seed<'a> {
    limits: Limits,
    state: &'a State,
    depth: usize,
}

impl<'de> DeserializeSeed<'de> for Seed<'_> {
    type Value = Json;

    fn deserialize<D>(self, deserializer: D) -> Result<Json, D::Error>
    where
        D: Deserializer<'de>,
    {
        self.state.count(self.limits)?;
        let raw = <&RawValue>::deserialize(deserializer)?;
        let text = raw.get();
        let container = matches!(text.as_bytes().first(), Some(b'[' | b'{'));
        if container && self.depth >= self.limits.depth {
            return Ok(Json::Deep(text.to_owned()));
        }
        if !container {
            return self.scalar(text);
        }
        let mut de = serde_json::Deserializer::from_str(text);
        let value = de
            .deserialize_any(Container { seed: self })
            .map_err(de::Error::custom)?;
        de.end().map_err(de::Error::custom)?;
        Ok(value)
    }
}

impl Seed<'_> {
    /// A value that is not an array or an object, by its text.
    fn scalar<E: de::Error>(self, text: &str) -> Result<Json, E> {
        match text {
            "null" => Ok(Json::Null),
            "true" => Ok(Json::Bool(true)),
            "false" => Ok(Json::Bool(false)),
            _ if text.starts_with('"') => serde_json::from_str::<String>(text)
                .map(Json::String)
                .map_err(E::custom),
            _ => self.number(text),
        }
    }

    /// A number, at its text. An integer has at most `Limits::integer_chars`
    /// characters with the sign; a float is finite.
    fn number<E: de::Error>(self, text: &str) -> Result<Json, E> {
        let integer = !text.bytes().any(|b| matches!(b, b'.' | b'e' | b'E'));
        if integer {
            if text.len() > self.limits.integer_chars {
                return Err(self.state.fault("json integer"));
            }
        } else if !text.parse::<f64>().is_ok_and(f64::is_finite) {
            return Err(self.state.fault("json float"));
        }
        Ok(Json::Number(text.to_owned()))
    }
}

/// The items of a container whose text `Seed` read: the members are seeded
/// one level deeper.
struct Container<'a> {
    seed: Seed<'a>,
}

impl<'a> Container<'a> {
    fn child(&self) -> Seed<'a> {
        Seed {
            depth: self.seed.depth + 1,
            ..self.seed
        }
    }
}

impl<'de> Visitor<'de> for Container<'_> {
    type Value = Json;

    fn expecting(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str("a JSON array or object")
    }

    fn visit_seq<A: SeqAccess<'de>>(self, mut items: A) -> Result<Json, A::Error> {
        let mut values = Vec::new();
        while let Some(value) = items.next_element_seed(self.child())? {
            values.push(value);
        }
        Ok(Json::Array(values))
    }

    fn visit_map<A: MapAccess<'de>>(self, mut map: A) -> Result<Json, A::Error> {
        let mut pairs = Vec::new();
        while let Some(key) = map.next_key::<String>()? {
            self.seed.state.count(self.seed.limits)?;
            let value = map.next_value_seed(self.child())?;
            pairs.push((key, value));
        }
        Ok(Json::Object(pairs))
    }
}
