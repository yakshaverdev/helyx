//! The handshake of protocol 13 (rule O1 of `docs/features/wire-protocol.md`):
//! the server sends `challenge`, the client sends `hello` with the proof of its
//! token, the server sends `welcome` or `refused`. Any other frame is a break.

use crate::check::{Broken, Checked, int_key, object, one_of, string};
use crate::json::Json;
use base64::Engine;
use base64::engine::general_purpose::STANDARD;
use hmac::{Hmac, Mac};
use sha2::{Digest, Sha256};

/// The protocol number of this client.
pub const PROTOCOL: u64 = 13;

#[derive(Debug, Clone, PartialEq)]
pub enum Step {
    /// Send this `hello` frame, then wait for the answer.
    Send(Json),
    /// The server took the `hello`: requests may go.
    Welcome,
    /// The server speaks protocol `n`: the client must update.
    Refused(u64),
}

/// The token of the server. Its `Debug` form holds no byte of it, so no log
/// or crash report of a state that holds it shows it.
#[derive(Clone, PartialEq, Eq)]
pub struct Token(String);

impl Token {
    pub fn new(token: String) -> Token {
        Token(token)
    }
}

impl std::fmt::Debug for Token {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("Token(..)")
    }
}

/// The state of one handshake: it waits for `challenge`, then for the answer.
/// The connection leaves the handshake at that answer (`connection::Link`).
#[derive(Debug)]
pub struct Handshake {
    token: Option<Token>,
    phase: Phase,
}

/// O1: one `challenge`, then one `welcome` or `refused`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Phase {
    Challenge,
    Answer,
}

impl Handshake {
    /// A handshake that proves `token`, or sends no proof when the server has
    /// no token. The proof is made from the token here and the token is in no frame.
    pub fn new(token: Option<Token>) -> Handshake {
        Handshake {
            token,
            phase: Phase::Challenge,
        }
    }

    /// Takes the next server frame of the handshake. The connection leaves the
    /// handshake at `welcome` or `refused`.
    pub fn step(&mut self, frame: &Json) -> Checked<Step> {
        let map = object(frame, "handshake frame")?;
        match (self.phase, string(map, "type", "handshake frame")?) {
            (Phase::Challenge, "challenge") => {
                let nonce = STANDARD
                    .decode(string(map, "nonce", "challenge nonce")?)
                    .map_err(|_| Broken("challenge nonce"))?;
                let nonce: [u8; 32] = nonce.try_into().map_err(|_| Broken("challenge nonce"))?;
                self.phase = Phase::Answer;
                let mut hello = vec![
                    ("type".to_owned(), "hello".into()),
                    ("protocol".to_owned(), PROTOCOL.into()),
                ];
                if let Some(token) = &self.token {
                    hello.push(("proof".to_owned(), Json::String(proof(&token.0, &nonce))));
                }
                Ok(Step::Send(Json::Object(hello)))
            }
            (Phase::Answer, "welcome") if int_key(map, "protocol", "welcome")? == PROTOCOL => {
                Ok(Step::Welcome)
            }
            (Phase::Answer, "refused") => {
                one_of(map, "code", &["protocol"], "refused")?;
                // The server refuses only a protocol that is not its own.
                let server_protocol = int_key(map, "server_protocol", "refused")?;
                if server_protocol == PROTOCOL {
                    return Err(Broken("refused"));
                }
                Ok(Step::Refused(server_protocol))
            }
            _ => Err(Broken("handshake order")),
        }
    }
}

/// base64(HMAC-SHA256(SHA-256(token), nonce)), rule O1.
pub fn proof(token: &str, nonce: &[u8; 32]) -> String {
    let key = Sha256::digest(token.as_bytes());
    let mut mac = Hmac::<Sha256>::new_from_slice(&key).expect("HMAC takes a key of any length");
    mac.update(nonce);
    STANDARD.encode(mac.finalize().into_bytes())
}
