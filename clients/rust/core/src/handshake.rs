//! The handshake of protocol 15 (rule O1 of `docs/features/wire-protocol.md`):
//! the server sends `challenge`, the client sends `hello`, the server sends
//! `welcome` or `refused`. Any other frame is a break.
//!
//! The `hello` has one of three forms, by the credential of the connection: the
//! proof of the server token of a local server, the proof of a pairing link
//! with the Ed25519 signature of the signature text, or the signature alone of
//! a paired client (`docs/features/remote-hands.md`, "The pairing handshake"
//! and "The handshake of a paired peer").

use crate::check::{Broken, Checked, int_key, object, one_of, string};
use crate::json::Json;
use crate::key::Key;
use base64::Engine;
use base64::engine::general_purpose::STANDARD;
use hmac::{Hmac, Mac};
use sha2::{Digest, Sha256};

/// The protocol number of this client.
pub const PROTOCOL: u64 = 15;

/// The context text that both pairing handshakes sign.
pub const CONTEXT: &str = "helyx-handshake-v1";

/// The kind of a paired client, in the signature text and the `hello`.
pub const CLIENT: &str = "client";

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

/// What the client proves at the handshake of one connection: the token of a
/// local server, the bootstrap token and the key of a pairing, or the key of a
/// paired client. `Debug` holds no token and no key byte.
#[derive(Clone)]
pub enum Credential {
    /// The server token of a local server, or no proof when the server has
    /// no token.
    Token(Option<Token>),
    /// A pairing with a link: the bootstrap token of the link, the pin, the
    /// name, and the key that the pairing made.
    Pair {
        token: Token,
        pin: String,
        name: String,
        key: Key,
    },
    /// A paired client: the pin, the name, and the key of its saved state.
    Paired { pin: String, name: String, key: Key },
}

impl Credential {
    /// The credential of a local server that proves `token`.
    pub fn token(token: impl Into<String>) -> Credential {
        Credential::Token(Some(Token::new(token.into())))
    }

    /// The credential of a server with no token: the `hello` carries no proof.
    pub fn none() -> Credential {
        Credential::Token(None)
    }
}

impl std::fmt::Debug for Credential {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("Credential(..)")
    }
}

/// The state of one handshake: it waits for `challenge`, then for the answer.
/// The connection leaves the handshake at that answer (`connection::Link`).
#[derive(Debug)]
pub struct Handshake {
    credential: Credential,
    phase: Phase,
}

/// O1: one `challenge`, then one `welcome` or `refused`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Phase {
    Challenge,
    Answer,
}

impl Handshake {
    /// A handshake that proves `credential`. The proof is made from the token
    /// here and the token is in no frame.
    pub fn new(credential: Credential) -> Handshake {
        Handshake {
            credential,
            phase: Phase::Challenge,
        }
    }

    /// Takes the next server frame of the handshake. The connection leaves
    /// the handshake at `welcome` or `refused`.
    pub fn step(&mut self, frame: &Json) -> Checked<Step> {
        let map = object(frame, "handshake frame")?;
        match (self.phase, string(map, "type", "handshake frame")?) {
            (Phase::Challenge, "challenge") => {
                let nonce = STANDARD
                    .decode(string(map, "nonce", "challenge nonce")?)
                    .map_err(|_| Broken("challenge nonce"))?;
                let nonce: [u8; 32] = nonce.try_into().map_err(|_| Broken("challenge nonce"))?;
                self.phase = Phase::Answer;
                Ok(Step::Send(hello(&self.credential, &nonce)))
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

/// The `hello` of a credential for `nonce`. The keys are in the order that the
/// server's encoder writes a map, so the frame of a pairing is the one that
/// the Elixir test peer builds byte for byte.
fn hello(credential: &Credential, nonce: &[u8; 32]) -> Json {
    match credential {
        Credential::Token(token) => {
            let mut hello = vec![
                ("type".to_owned(), "hello".into()),
                ("protocol".to_owned(), PROTOCOL.into()),
            ];
            if let Some(token) = token {
                hello.push(("proof".to_owned(), Json::String(proof(&token.0, nonce))));
            }
            Json::Object(hello)
        }
        Credential::Pair {
            token,
            pin,
            name,
            key,
        } => {
            let text = signature_text(pin, CLIENT, name, nonce);
            Json::Object(vec![
                ("client".to_owned(), Json::String(name.clone())),
                (
                    "pair".to_owned(),
                    Json::Object(vec![
                        ("proof".to_owned(), Json::String(proof(&token.0, nonce))),
                        ("public_key".to_owned(), Json::String(key.public_key())),
                        ("signature".to_owned(), Json::String(key.sign(&text))),
                    ]),
                ),
                ("protocol".to_owned(), PROTOCOL.into()),
                ("role".to_owned(), Json::String(CLIENT.into())),
                ("type".to_owned(), Json::String("hello".into())),
            ])
        }
        Credential::Paired { pin, name, key } => {
            let text = signature_text(pin, CLIENT, name, nonce);
            Json::Object(vec![
                ("client".to_owned(), Json::String(name.clone())),
                ("protocol".to_owned(), PROTOCOL.into()),
                ("role".to_owned(), Json::String(CLIENT.into())),
                ("signature".to_owned(), Json::String(key.sign(&text))),
                ("type".to_owned(), Json::String("hello".into())),
            ])
        }
    }
}

/// The bytes that a peer signs: the context text, the nonce, the pin, the
/// kind, and the name, each preceded by its length as a 32-bit big-endian
/// integer (`Helyx.Transport.WebSocket.Pairing.signature_text/4`).
pub fn signature_text(pin: &str, kind: &str, name: &str, nonce: &[u8; 32]) -> Vec<u8> {
    let mut text = vec![];
    for part in [
        CONTEXT.as_bytes(),
        nonce,
        pin.as_bytes(),
        kind.as_bytes(),
        name.as_bytes(),
    ] {
        text.extend((part.len() as u32).to_be_bytes());
        text.extend(part);
    }
    text
}

/// base64(HMAC-SHA256(SHA-256(token), nonce)), rule O1.
pub fn proof(token: &str, nonce: &[u8; 32]) -> String {
    let key = Sha256::digest(token.as_bytes());
    let mut mac = Hmac::<Sha256>::new_from_slice(&key).expect("HMAC takes a key of any length");
    mac.update(nonce);
    STANDARD.encode(mac.finalize().into_bytes())
}
