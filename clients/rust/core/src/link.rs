//! The link of a pairing (`docs/features/remote-hands.md`, "The link"): the
//! address, the bootstrap token, the pin, the kind, and the name, as
//! `helyx-pair:1:<base64url JSON {"a","t","p","k","n"}>`. The parse is pure
//! and checks every field, so a bad link is refused before a connection. No
//! error and no `Debug` form holds the token.

use crate::handshake::Token;
use crate::json::{Json, decode};
use base64::Engine;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;

/// The prefix of a link and its version.
pub const PREFIX: &str = "helyx-pair:1:";
/// The bytes of a link: the longest link that the server makes, plus a
/// margin. The server's longest is under 700 bytes: a host name of 253
/// bytes, a token of 43, a pin of 43, the kind, and a name of 64, in JSON,
/// base64url. The bound is a margin of about three times, so a longer host
/// still fits.
pub const MAX_LINK_BYTES: usize = 2_048;
/// The bytes of the name of a peer, as `Helyx.Transport.WebSocket.Pairing.name_bytes/0`.
pub const MAX_NAME_BYTES: usize = 64;
/// The bytes of a pin.
pub const PIN_BYTES: usize = 32;
/// The kind of a link that a client app pairs with.
pub const KIND: &str = "client";

/// A parsed link of the kind `client`.
#[derive(Clone, PartialEq, Eq)]
pub struct Link {
    /// The host that the link carries: a DNS name or an IP address, without
    /// brackets.
    pub host: String,
    pub port: u16,
    /// The bootstrap token of the link, as its text.
    pub token: Token,
    /// The pin of the server's certificate: the base64url, without padding,
    /// of the SHA-256 of the DER of its SubjectPublicKeyInfo.
    pub pin: String,
    pub name: String,
}

impl Link {
    /// Parses a link, or gives the fault of the first field that does not
    /// hold.
    pub fn parse(text: &str) -> Result<Link, ParseError> {
        if text.len() > MAX_LINK_BYTES {
            return Err(ParseError::Size);
        }
        let body = text.strip_prefix(PREFIX).ok_or(ParseError::Prefix)?;
        let bytes = URL_SAFE_NO_PAD
            .decode(body)
            .map_err(|_| ParseError::Base64)?;
        let text = std::str::from_utf8(&bytes).map_err(|_| ParseError::Json)?;
        let value = decode(text).map_err(|_| ParseError::Json)?;
        let address = string(&value, "a")?;
        let token = string(&value, "t")?;
        let pin = string(&value, "p")?;
        let kind = string(&value, "k")?;
        let name = string(&value, "n")?;
        if kind != KIND {
            return Err(ParseError::Kind);
        }
        if !name_ok(name) {
            return Err(ParseError::Name);
        }
        if !pin_ok(pin) {
            return Err(ParseError::Pin);
        }
        let (host, port) = split_address(address)?;
        Ok(Link {
            host,
            port,
            token: Token::new(token.to_owned()),
            pin: pin.to_owned(),
            name: name.to_owned(),
        })
    }
}

impl std::fmt::Debug for Link {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "Link({}:{}, {})", self.host, self.port, self.name)
    }
}

/// Why a link does not parse. No value holds a part of the link.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ParseError {
    /// Another prefix or version.
    Prefix,
    /// The body is not base64url.
    Base64,
    /// The body is not JSON.
    Json,
    /// A field is missing, or is not a string: `"a"`, `"t"`, `"p"`, `"k"`,
    /// or `"n"`.
    Field(&'static str),
    /// The kind is not `client`.
    Kind,
    /// The name breaks the name rule.
    Name,
    /// The port is not 1 to 65,535.
    Port,
    /// The host is empty.
    Host,
    /// The pin is not the base64url of 32 bytes.
    Pin,
    /// The link is over `MAX_LINK_BYTES`.
    Size,
}

impl ParseError {
    /// The fault, for a line of the host.
    pub fn text(&self) -> &'static str {
        match self {
            ParseError::Prefix => "the link does not start with helyx-pair:1:",
            ParseError::Base64 => "the link body is not base64url",
            ParseError::Json => "the link body is not JSON",
            ParseError::Field("a") => "the link address is missing or not a string",
            ParseError::Field("t") => "the link token is missing or not a string",
            ParseError::Field("p") => "the link pin is missing or not a string",
            ParseError::Field("k") => "the link kind is missing or not a string",
            ParseError::Field(_) => "the link name is missing or not a string",
            ParseError::Kind => "the link is not for a client",
            ParseError::Name => "the link name is not 1 to 64 bytes of a-z, 0-9, and _",
            ParseError::Port => "the link port is not 1 to 65535",
            ParseError::Host => "the link host is empty",
            ParseError::Pin => "the link pin is not the base64url of 32 bytes",
            ParseError::Size => "the link is over its size",
        }
    }
}

/// Whether `name` is 1 to `MAX_NAME_BYTES` bytes of a-z, 0-9, and `_`, the
/// one name rule of the wire.
pub fn name_ok(name: &str) -> bool {
    !name.is_empty()
        && name.len() <= MAX_NAME_BYTES
        && name
            .bytes()
            .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'_')
}

/// Whether `pin` is the base64url, without padding, of 32 bytes.
pub fn pin_ok(pin: &str) -> bool {
    URL_SAFE_NO_PAD
        .decode(pin)
        .is_ok_and(|bytes| bytes.len() == PIN_BYTES)
}

fn string<'a>(value: &'a Json, key: &'static str) -> Result<&'a str, ParseError> {
    value
        .get(key)
        .and_then(Json::as_str)
        .ok_or(ParseError::Field(key))
}

/// The host and the port of `host:port`. An IPv6 literal is in brackets.
fn split_address(text: &str) -> Result<(String, u16), ParseError> {
    let (host, port) = text.rsplit_once(':').ok_or(ParseError::Field("a"))?;
    let host = match host.strip_prefix('[').and_then(|h| h.strip_suffix(']')) {
        Some(bare) => bare,
        None => host,
    };
    if host.is_empty() {
        return Err(ParseError::Host);
    }
    let digits = !port.is_empty() && port.bytes().all(|b| b.is_ascii_digit());
    let port: u32 = port.parse().map_err(|_| ParseError::Port)?;
    if !digits || !(1..=65_535).contains(&port) {
        return Err(ParseError::Port);
    }
    Ok((host.to_owned(), port as u16))
}
