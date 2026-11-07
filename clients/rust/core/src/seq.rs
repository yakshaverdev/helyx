//! The `seq` of an event: an `int` of the schema, of any size within the
//! decode bounds, kept exact, for the fold compares it and counts on from it
//! (`docs/features/client-kit.md`, "Bounds").

use crate::json::{Json, natural};
use num_bigint::BigUint;
use std::fmt;

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Seq(BigUint);

impl Seq {
    /// The `seq` of the text of a JSON integer >= 0 (`-0` is 0); `None` for
    /// another text.
    pub fn parse(text: &str) -> Option<Seq> {
        BigUint::parse_bytes(natural(text)?.as_bytes(), 10).map(Seq)
    }

    /// The next `seq`.
    pub fn next(&self) -> Seq {
        Seq(&self.0 + 1u32)
    }

    /// Whether `to` is past a multiple of `step` that `from` is not.
    pub fn passes(from: &Seq, to: &Seq, step: u64) -> bool {
        &to.0 / step > &from.0 / step
    }

    /// The value, when it fits a `u64`.
    pub fn to_u64(&self) -> Option<u64> {
        u64::try_from(&self.0).ok()
    }
}

impl From<u64> for Seq {
    fn from(n: u64) -> Seq {
        Seq(BigUint::from(n))
    }
}

impl PartialEq<u64> for Seq {
    fn eq(&self, n: &u64) -> bool {
        self.to_u64() == Some(*n)
    }
}

/// A `seq` as the client sends it: a JSON integer of its digits.
impl From<&Seq> for Json {
    fn from(seq: &Seq) -> Json {
        Json::Number(seq.to_string())
    }
}

impl fmt::Display for Seq {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}", self.0)
    }
}
