//! The value checks of the schema of protocol 3 (`docs/features/wire-protocol.md`,
//! "Codec"). A check returns `Err(Broken)` for a value that the schema does not
//! allow: the frame is a contract break of the server.

use serde_json::{Map, Value};

/// A frame that breaks the contract of the wire: the client ends the connection.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Broken(pub &'static str);

pub type Checked<T> = Result<T, Broken>;

pub(crate) fn object<'a>(value: &'a Value, what: &'static str) -> Checked<&'a Map<String, Value>> {
    value.as_object().ok_or(Broken(what))
}

/// The value of an optional key: absent and null are the same (the notation of
/// the schema).
pub(crate) fn optional<'a>(map: &'a Map<String, Value>, key: &str) -> Option<&'a Value> {
    map.get(key).filter(|value| !value.is_null())
}

pub(crate) fn field<'a>(
    map: &'a Map<String, Value>,
    key: &str,
    what: &'static str,
) -> Checked<&'a Value> {
    map.get(key).ok_or(Broken(what))
}

pub(crate) fn string<'a>(
    map: &'a Map<String, Value>,
    key: &str,
    what: &'static str,
) -> Checked<&'a str> {
    field(map, key, what)?.as_str().ok_or(Broken(what))
}

/// `id` of the schema: a string of 1 to 64 bytes.
pub(crate) fn id<'a>(
    map: &'a Map<String, Value>,
    key: &str,
    what: &'static str,
) -> Checked<&'a str> {
    let text = string(map, key, what)?;
    (1..=64)
        .contains(&text.len())
        .then_some(text)
        .ok_or(Broken(what))
}

/// `int` of the schema: a JSON integer >= 0. An integer above `u64::MAX` is a
/// break too: no bound of the server comes near it.
pub(crate) fn int(value: &Value, what: &'static str) -> Checked<u64> {
    value.as_u64().ok_or(Broken(what))
}

pub(crate) fn int_key(map: &Map<String, Value>, key: &str, what: &'static str) -> Checked<u64> {
    int(field(map, key, what)?, what)
}

pub(crate) fn int_or_null(
    map: &Map<String, Value>,
    key: &str,
    what: &'static str,
) -> Checked<Option<u64>> {
    match field(map, key, what)? {
        Value::Null => Ok(None),
        value => int(value, what).map(Some),
    }
}

/// `number` of the schema: a JSON number >= 0.
pub(crate) fn number(value: &Value, what: &'static str) -> Checked<f64> {
    value.as_f64().filter(|n| *n >= 0.0).ok_or(Broken(what))
}

pub(crate) fn boolean(map: &Map<String, Value>, key: &str, what: &'static str) -> Checked<bool> {
    field(map, key, what)?.as_bool().ok_or(Broken(what))
}

pub(crate) fn optional_bool(
    map: &Map<String, Value>,
    key: &str,
    what: &'static str,
) -> Checked<bool> {
    optional(map, key).map_or(Ok(false), |v| v.as_bool().ok_or(Broken(what)))
}

pub(crate) fn string_or_null<'a>(
    map: &'a Map<String, Value>,
    key: &str,
    what: &'static str,
) -> Checked<Option<&'a str>> {
    match field(map, key, what)? {
        Value::Null => Ok(None),
        value => value.as_str().map(Some).ok_or(Broken(what)),
    }
}

pub(crate) fn one_of<'a>(
    map: &'a Map<String, Value>,
    key: &str,
    allowed: &[&str],
    what: &'static str,
) -> Checked<&'a str> {
    let text = string(map, key, what)?;
    allowed.contains(&text).then_some(text).ok_or(Broken(what))
}

/// `one_of` for an optional key: absent and null give `None`.
pub(crate) fn optional_one_of<'a>(
    map: &'a Map<String, Value>,
    key: &str,
    allowed: &[&str],
    what: &'static str,
) -> Checked<Option<&'a str>> {
    optional(map, key)
        .map(|_| one_of(map, key, allowed, what))
        .transpose()
}

pub(crate) fn list<'a>(
    map: &'a Map<String, Value>,
    key: &str,
    what: &'static str,
) -> Checked<&'a [Value]> {
    field(map, key, what)?
        .as_array()
        .map(Vec::as_slice)
        .ok_or(Broken(what))
}

pub(crate) fn list_of<T>(
    map: &Map<String, Value>,
    key: &str,
    what: &'static str,
    item: impl Fn(&Value) -> Checked<T>,
) -> Checked<Vec<T>> {
    list(map, key, what)?.iter().map(item).collect()
}
