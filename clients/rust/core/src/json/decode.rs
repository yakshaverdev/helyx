//! The decoder of the JSON of a server frame, within the bounds of
//! `Limits` (`docs/features/client-kit.md`, "Bounds").

use super::{Json, Limits, WIRE};
use crate::check::{Broken, Checked};

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
            b'[' | b'{' if depth >= self.limits.depth => self.deep(),
            b'[' => self.items(b']', |p| p.value(depth + 1)).map(Json::Array),
            b'{' => self.items(b'}', |p| p.pair(depth + 1)).map(Json::Object),
            _ => self.scalar(),
        }
    }

    /// A value that is not an array or an object.
    fn scalar(&mut self) -> Checked<Json> {
        match self.peek().ok_or(BAD)? {
            b'n' => self.literal("null", Json::Null),
            b't' => self.literal("true", Json::Bool(true)),
            b'f' => self.literal("false", Json::Bool(false)),
            b'"' => self.string().map(Json::String),
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

    /// A container past the depth: checked by the same grammar and bounds,
    /// with a stack of its open containers on the heap, and kept as its
    /// text. `value` counted the container itself.
    fn deep(&mut self) -> Checked<Json> {
        let start = self.at;
        let mut closes: Vec<u8> = Vec::new();
        let mut at_value = self.open(&mut closes)?;
        loop {
            if at_value {
                self.count()?;
                at_value = match self.peek().ok_or(BAD)? {
                    b'[' | b'{' => self.open(&mut closes)?,
                    _ => {
                        self.scalar()?;
                        false
                    }
                };
                continue;
            }
            let Some(&close) = closes.last() else {
                return Ok(Json::Deep(self.text[start..self.at].to_owned()));
            };
            self.space();
            match self.next()? {
                b',' => {
                    self.space();
                    if close == b'}' {
                        self.key()?;
                    }
                    at_value = true;
                }
                byte if byte == close => drop(closes.pop()),
                _ => return Err(BAD),
            }
        }
    }

    /// The `[` or `{` of a container in `deep`, and the key of a first pair;
    /// `true` when a value follows, `false` for an empty container.
    fn open(&mut self, closes: &mut Vec<u8>) -> Checked<bool> {
        let close = if self.next()? == b'[' { b']' } else { b'}' };
        self.space();
        if self.eat(close).is_ok() {
            return Ok(false);
        }
        closes.push(close);
        if close == b'}' {
            self.key()?;
        }
        Ok(true)
    }

    /// A key of an object, counted as a value, then its `:`.
    fn key(&mut self) -> Checked<String> {
        self.count()?;
        let key = self.string()?;
        self.space();
        self.eat(b':')?;
        self.space();
        Ok(key)
    }

    /// A key of an object, counted as a value, and its value.
    fn pair(&mut self, depth: usize) -> Checked<(String, Json)> {
        let key = self.key()?;
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
