//! The parts of a frame (`docs/features/wire-protocol.md`, "Parts", O3): a
//! frame over 1,048,576 bytes of JSON text goes as consecutive `part` frames,
//! `n` from 0, `last` on the final one, each with up to 786,000 bytes of the
//! text as base64.

use crate::check::{Broken, Checked};
use crate::json::Json;
use base64::Engine;
use base64::engine::general_purpose::STANDARD;

/// The JSON text of one WebSocket frame, both ways.
pub const FRAME_BYTES: usize = 1_048_576;
/// The bytes of the text in one part.
pub const PART_BYTES: usize = 786_000;
/// The largest request that the server joins from parts; over it the server
/// closes with `4413`.
pub const REQUEST_BYTES: usize = 26_214_400;

/// The frames that send `text`: the text itself when it fits one frame,
/// else its parts. A text over `REQUEST_BYTES` is refused.
pub fn split(text: String) -> Result<Vec<String>, TooLarge> {
    if text.len() > REQUEST_BYTES {
        return Err(TooLarge);
    }
    if text.len() <= FRAME_BYTES {
        return Ok(vec![text]);
    }
    let last = text.len().div_ceil(PART_BYTES) - 1;
    Ok(text
        .as_bytes()
        .chunks(PART_BYTES)
        .enumerate()
        .map(|(n, piece)| {
            format!(
                r#"{{"type":"part","n":{n},"last":{},"data":"{}"}}"#,
                n == last,
                STANDARD.encode(piece)
            )
        })
        .collect())
}

/// A request over `REQUEST_BYTES`: the server would close the connection.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct TooLarge;

/// The parts of one frame joined so far.
#[derive(Debug, Default)]
pub(crate) struct Joiner {
    next: u64,
    joined: Vec<u8>,
}

impl Joiner {
    /// True while a frame has parts that have not come.
    pub fn pending(&self) -> bool {
        self.next > 0
    }

    /// Takes one `part` frame. Gives the joined text after the last part.
    /// A part with another key, out of order, of bad base64, or that takes
    /// the joined bytes over `max`, or a joined text that is not UTF-8, is a
    /// break.
    pub fn take(&mut self, part: &Json, max: usize) -> Checked<Option<String>> {
        let broken = Broken("part");
        let Json::Object(pairs) = part else {
            return Err(broken);
        };
        let keys = ["type", "n", "last", "data"];
        if pairs.len() != keys.len() || !keys.iter().all(|key| part.get(key).is_some()) {
            return Err(broken);
        }
        let (Some(n), Some(last), Some(data)) = (
            part.get("n").and_then(Json::as_u64),
            part.get("last").and_then(Json::as_bool),
            part.get("data").and_then(Json::as_str),
        ) else {
            return Err(broken);
        };
        if n != self.next {
            return Err(broken);
        }
        let piece = STANDARD.decode(data).map_err(|_| broken.clone())?;
        if self.joined.len() + piece.len() > max {
            return Err(Broken("parts size"));
        }
        self.joined.extend_from_slice(&piece);
        self.next += 1;
        if !last {
            return Ok(None);
        }
        let joined = std::mem::take(&mut self.joined);
        self.next = 0;
        String::from_utf8(joined).map(Some).map_err(|_| broken)
    }
}
