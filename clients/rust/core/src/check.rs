//! The value checks of the schema of protocol 5 (`docs/features/wire-protocol.md`,
//! "Codec"). A check returns `Err(Broken)` for a value that the schema does not
//! allow: the frame is a contract break of the server.

use crate::json::Json;
use crate::seq::Seq;

/// A frame that breaks the contract of the wire: the client ends the connection.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Broken(pub &'static str);

pub type Checked<T> = Result<T, Broken>;

/// `value` when it is an object; the other checks read its keys.
pub(crate) fn object<'a>(value: &'a Json, what: &'static str) -> Checked<&'a Json> {
    matches!(value, Json::Object(_))
        .then_some(value)
        .ok_or(Broken(what))
}

/// The value of an optional key: absent and null are the same (the notation of
/// the schema).
pub(crate) fn optional<'a>(map: &'a Json, key: &str) -> Option<&'a Json> {
    map.get(key).filter(|value| !value.is_null())
}

pub(crate) fn field<'a>(map: &'a Json, key: &str, what: &'static str) -> Checked<&'a Json> {
    map.get(key).ok_or(Broken(what))
}

pub(crate) fn string<'a>(map: &'a Json, key: &str, what: &'static str) -> Checked<&'a str> {
    field(map, key, what)?.as_str().ok_or(Broken(what))
}

/// `id` of the schema: a string of 1 to 64 bytes.
pub(crate) fn id<'a>(map: &'a Json, key: &str, what: &'static str) -> Checked<&'a str> {
    let text = string(map, key, what)?;
    (1..=64)
        .contains(&text.len())
        .then_some(text)
        .ok_or(Broken(what))
}

/// `int` of the schema: a JSON integer >= 0, read as `Json::as_u64` reads it.
pub(crate) fn int(value: &Json, what: &'static str) -> Checked<u64> {
    value.as_u64().ok_or(Broken(what))
}

pub(crate) fn int_key(map: &Json, key: &str, what: &'static str) -> Checked<u64> {
    int(field(map, key, what)?, what)
}

pub(crate) fn int_or_null(map: &Json, key: &str, what: &'static str) -> Checked<Option<u64>> {
    match field(map, key, what)? {
        Json::Null => Ok(None),
        value => int(value, what).map(Some),
    }
}

/// `number` of the schema: a JSON number >= 0.
pub(crate) fn number(value: &Json, what: &'static str) -> Checked<f64> {
    value.as_nonnegative_f64().ok_or(Broken(what))
}

pub(crate) fn boolean(map: &Json, key: &str, what: &'static str) -> Checked<bool> {
    field(map, key, what)?.as_bool().ok_or(Broken(what))
}

pub(crate) fn optional_bool(map: &Json, key: &str, what: &'static str) -> Checked<bool> {
    optional(map, key).map_or(Ok(false), |v| v.as_bool().ok_or(Broken(what)))
}

pub(crate) fn string_or_null<'a>(
    map: &'a Json,
    key: &str,
    what: &'static str,
) -> Checked<Option<&'a str>> {
    match field(map, key, what)? {
        Json::Null => Ok(None),
        value => value.as_str().map(Some).ok_or(Broken(what)),
    }
}

pub(crate) fn one_of<'a>(
    map: &'a Json,
    key: &str,
    allowed: &[&str],
    what: &'static str,
) -> Checked<&'a str> {
    let text = string(map, key, what)?;
    allowed.contains(&text).then_some(text).ok_or(Broken(what))
}

/// `one_of` for an optional key: absent and null give `None`.
pub(crate) fn optional_one_of<'a>(
    map: &'a Json,
    key: &str,
    allowed: &[&str],
    what: &'static str,
) -> Checked<Option<&'a str>> {
    optional(map, key)
        .map(|_| one_of(map, key, allowed, what))
        .transpose()
}

pub(crate) fn list<'a>(map: &'a Json, key: &str, what: &'static str) -> Checked<&'a [Json]> {
    field(map, key, what)?.as_array().ok_or(Broken(what))
}

pub(crate) fn list_of<T>(
    map: &Json,
    key: &str,
    what: &'static str,
    item: impl Fn(&Json) -> Checked<T>,
) -> Checked<Vec<T>> {
    list(map, key, what)?.iter().map(item).collect()
}

/// The `seq` of `key`: an `int` of the schema, exact.
pub(crate) fn seq_key(map: &Json, key: &str, what: &'static str) -> Checked<Seq> {
    match field(map, key, what)? {
        Json::Number(text) => Seq::parse(text).ok_or(Broken(what)),
        _ => Err(Broken(what)),
    }
}
