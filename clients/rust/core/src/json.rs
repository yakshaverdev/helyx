//! The JSON of the wire, lossless: a number keeps its text, so an integer of
//! a tool call keeps every digit, and no object key has a meaning of its own.
//! `decode` holds the outbound decode bounds of `docs/features/wire-protocol.md`
//! ("Bounds") and the depth bound of this client (`docs/features/client-kit.md`).

use crate::check::{Broken, Checked};
use std::fmt::Write;

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
}

/// The bounds of one decode.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Limits {
    /// The bytes of the text.
    pub frame_bytes: usize,
    /// The values, counted as the server counts them: each value, and each
    /// object key.
    pub values: usize,
    /// The characters of an integer, the minus sign included.
    pub integer_chars: usize,
    /// The nesting of arrays and objects.
    pub depth: usize,
}

/// The bounds of a server frame: the outbound decode bounds of the wire (the
/// largest frame that the server sends by its bounds, joined from parts), and
/// a depth bound of this client. The parse, the clone, and the drop of a
/// value recurse, so the depth bounds the stack of the client.
pub const WIRE: Limits = Limits {
    frame_bytes: 1_611_661_312,
    values: 38_797_312,
    integer_chars: 1_024,
    depth: 1_024,
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

    /// An integer >= 0 that fits in a `u64`, judged by its value: `-0` is
    /// zero, as `JSON.decode/1` of Elixir reads it.
    pub fn as_u64(&self) -> Option<u64> {
        match self {
            Json::Number(text) if text == "-0" => Some(0),
            Json::Number(text) if text.bytes().all(|b| b.is_ascii_digit()) => text.parse().ok(),
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
        let mut out = String::new();
        self.write(&mut out);
        out
    }

    fn write(&self, out: &mut String) {
        match self {
            Json::Null => out.push_str("null"),
            Json::Bool(b) => out.push_str(if *b { "true" } else { "false" }),
            Json::Number(text) => out.push_str(text),
            Json::String(text) => write_string(text, out),
            Json::Array(items) => write_list(out, ['[', ']'], items, |item, out| item.write(out)),
            Json::Object(pairs) => write_list(out, ['{', '}'], pairs, |(key, value), out| {
                write_string(key, out);
                out.push(':');
                value.write(out);
            }),
        }
    }
}

fn write_list<T>(
    out: &mut String,
    [open, close]: [char; 2],
    items: &[T],
    item: impl Fn(&T, &mut String),
) {
    out.push(open);
    for (i, each) in items.iter().enumerate() {
        if i > 0 {
            out.push(',');
        }
        item(each, out);
    }
    out.push(close);
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

/// An object of `pairs`, for the frames that the client sends.
pub fn object<const N: usize>(pairs: [(&str, Json); N]) -> Json {
    Json::Object(pairs.into_iter().map(|(k, v)| (k.to_owned(), v)).collect())
}

fn write_string(text: &str, out: &mut String) {
    out.push('"');
    for c in text.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if (c as u32) < 0x20 => {
                let _ = write!(out, "\\u{:04x}", c as u32);
            }
            c => out.push(c),
        }
    }
    out.push('"');
}

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
    let mut parser = Parser {
        text,
        at: 0,
        values: 0,
        limits,
    };
    parser.space();
    let value = parser.value(0)?;
    parser.space();
    (parser.at == text.len())
        .then_some(value)
        .ok_or(Broken("json"))
}

/// `at` is always at a character boundary of `text`: it moves past ASCII
/// bytes only, and over a run of a string that ends at an ASCII byte.
struct Parser<'a> {
    text: &'a str,
    at: usize,
    values: usize,
    limits: Limits,
}

const BAD: Broken = Broken("json");

impl Parser<'_> {
    fn peek(&self) -> Option<u8> {
        self.text.as_bytes().get(self.at).copied()
    }

    fn space(&mut self) {
        while matches!(self.peek(), Some(b' ' | b'\t' | b'\n' | b'\r')) {
            self.at += 1;
        }
    }

    fn count(&mut self) -> Checked<()> {
        self.values += 1;
        (self.values <= self.limits.values)
            .then_some(())
            .ok_or(Broken("json values"))
    }

    /// The next byte, taken.
    fn next(&mut self) -> Checked<u8> {
        let byte = self.peek().ok_or(BAD)?;
        self.at += 1;
        Ok(byte)
    }

    fn eat(&mut self, byte: u8) -> Checked<()> {
        (self.peek() == Some(byte)).then(|| self.at += 1).ok_or(BAD)
    }

    fn literal(&mut self, word: &str, value: Json) -> Checked<Json> {
        word.bytes().try_for_each(|byte| self.eat(byte))?;
        Ok(value)
    }

    fn value(&mut self, depth: usize) -> Checked<Json> {
        self.count()?;
        match self.peek().ok_or(BAD)? {
            b'n' => self.literal("null", Json::Null),
            b't' => self.literal("true", Json::Bool(true)),
            b'f' => self.literal("false", Json::Bool(false)),
            b'"' => self.string().map(Json::String),
            b'[' | b'{' if depth >= self.limits.depth => Err(Broken("json depth")),
            b'[' => self.items(b']', |p| p.value(depth + 1)).map(Json::Array),
            b'{' => self.items(b'}', |p| p.pair(depth + 1)).map(Json::Object),
            b'-' | b'0'..=b'9' => self.number(),
            _ => Err(BAD),
        }
    }

    /// The items of an array or the pairs of an object, up to `close`.
    fn items<T>(
        &mut self,
        close: u8,
        mut item: impl FnMut(&mut Self) -> Checked<T>,
    ) -> Checked<Vec<T>> {
        self.at += 1;
        self.space();
        let mut items = Vec::new();
        if self.eat(close).is_ok() {
            return Ok(items);
        }
        loop {
            self.space();
            items.push(item(self)?);
            self.space();
            match self.next()? {
                b',' => {}
                byte if byte == close => return Ok(items),
                _ => return Err(BAD),
            }
        }
    }

    /// A key of an object, counted as a value, and its value.
    fn pair(&mut self, depth: usize) -> Checked<(String, Json)> {
        self.count()?;
        let key = self.string()?;
        self.space();
        self.eat(b':')?;
        self.space();
        Ok((key, self.value(depth)?))
    }

    fn digits(&mut self) -> usize {
        let start = self.at;
        while matches!(self.peek(), Some(b'0'..=b'9')) {
            self.at += 1;
        }
        self.at - start
    }

    /// The grammar of RFC 8259. An integer of more characters than
    /// `integer_chars` is over its bound; a float must be finite.
    fn number(&mut self) -> Checked<Json> {
        let start = self.at;
        if self.peek() == Some(b'-') {
            self.at += 1;
        }
        let first = self.peek();
        let digits = self.digits();
        if digits == 0 || (digits > 1 && first == Some(b'0')) {
            return Err(BAD);
        }
        let mut integer = true;
        if self.peek() == Some(b'.') {
            self.at += 1;
            integer = false;
            if self.digits() == 0 {
                return Err(BAD);
            }
        }
        if matches!(self.peek(), Some(b'e' | b'E')) {
            self.at += 1;
            integer = false;
            if matches!(self.peek(), Some(b'+' | b'-')) {
                self.at += 1;
            }
            if self.digits() == 0 {
                return Err(BAD);
            }
        }
        let text = &self.text[start..self.at];
        if integer && text.len() > self.limits.integer_chars {
            return Err(Broken("json integer"));
        }
        if !integer && !text.parse::<f64>().is_ok_and(f64::is_finite) {
            return Err(Broken("json float"));
        }
        Ok(Json::Number(text.to_owned()))
    }

    fn hex4(&mut self) -> Checked<u32> {
        let digits = self.text.as_bytes().get(self.at..self.at + 4).ok_or(BAD)?;
        let code = digits
            .iter()
            .try_fold(0, |n, &b| char::from(b).to_digit(16).map(|d| n * 16 + d))
            .ok_or(BAD)?;
        self.at += 4;
        Ok(code)
    }

    fn string(&mut self) -> Checked<String> {
        self.eat(b'"')?;
        let mut out = String::new();
        loop {
            let start = self.at;
            while !matches!(self.peek(), None | Some(b'"' | b'\\' | 0..=0x1f)) {
                self.at += 1;
            }
            // The run ends at an ASCII byte or at the end: whole characters.
            out.push_str(&self.text[start..self.at]);
            match self.next()? {
                b'"' => return Ok(out),
                b'\\' => {
                    out.push(match self.next()? {
                        b'"' => '"',
                        b'\\' => '\\',
                        b'/' => '/',
                        b'b' => '\u{8}',
                        b'f' => '\u{c}',
                        b'n' => '\n',
                        b'r' => '\r',
                        b't' => '\t',
                        b'u' => self.unicode()?,
                        _ => return Err(BAD),
                    });
                }
                _ => return Err(BAD),
            }
        }
    }

    /// A `\u` escape, with the low half of a surrogate pair after a high
    /// half. A lone surrogate is not a character.
    fn unicode(&mut self) -> Checked<char> {
        let high = self.hex4()?;
        let code = match high {
            0xd800..=0xdbff => {
                self.eat(b'\\')?;
                self.eat(b'u')?;
                let low = self.hex4()?;
                if !(0xdc00..=0xdfff).contains(&low) {
                    return Err(BAD);
                }
                0x10000 + ((high - 0xd800) << 10) + (low - 0xdc00)
            }
            code => code,
        };
        char::from_u32(code).ok_or(BAD)
    }
}
