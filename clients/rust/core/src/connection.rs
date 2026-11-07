//! The state of one connection to the server: the handshake, the parts of a
//! frame, the requests in flight, and the live subscriptions. It turns the
//! text of each server frame into a decoded frame, and a request into its
//! frames; `Client` keeps what outlives the connection.

use crate::check::{Broken, Checked};
use crate::handshake::{Handshake, Token};
use crate::json::{self, Json, Limits, object};
use crate::parts::{self, FRAME_BYTES, Joiner, TooLarge};
use std::collections::{HashMap, HashSet};

/// The requests in flight on one connection, as the server bounds them.
pub const MAX_IN_FLIGHT: usize = 16;

/// Why the client did not send a request.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Refusal {
    /// No connection has taken the handshake.
    NotReady,
    /// `MAX_IN_FLIGHT` requests wait for their replies.
    Busy,
    /// `MAX_IN_FLIGHT` sessions are followed, the subscriptions of one
    /// connection.
    TooManySubscriptions,
    /// The frame is over the request size of the server.
    TooLarge,
    /// `subscribe` and `unsubscribe` go through their own functions, which
    /// keep the state of the session.
    Subscription,
}

/// Why a session is held.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Hold {
    /// Its subscription ended with `session_end`: a renewal ends the hold.
    Ended,
    /// The server answered a request that reconciles it with an error, or no
    /// request of it fits the request size.
    Refused,
}

#[derive(Debug)]
pub(crate) struct Request {
    pub op: &'static str,
    /// The session that the request names.
    pub session: Option<String>,
    /// The subscription that an `unsubscribe` ends.
    pub sub: Option<String>,
    /// The `instance_id` that a request names, as a `history` page does.
    pub instance: Option<String>,
}

/// A server frame, decoded and joined from its parts.
pub(crate) enum Decoded {
    Handshake(Json),
    Frame(Json),
    /// A part of a frame whose other parts have not come.
    Pending,
}

#[derive(Debug)]
pub(crate) struct Connection {
    pub handshake: Handshake,
    pub welcomed: bool,
    pub broken: bool,
    joiner: Joiner,
    next_id: u64,
    pub requests: HashMap<String, Request>,
    /// The session of each live subscription.
    pub subs: HashMap<String, String>,
    /// The sessions that the client sends no request for on this connection
    /// until the host states its intent again, and why.
    pub held: HashMap<String, Hold>,
    /// The subscriptions that an `unsubscribe` got `unknown_sub` for: the
    /// server holds none of them. A frame of one that was on the way is
    /// dropped.
    pub gone: HashSet<String>,
}

impl Connection {
    pub fn new(token: Option<Token>) -> Connection {
        Connection {
            handshake: Handshake::new(token),
            welcomed: false,
            broken: false,
            joiner: Joiner::default(),
            next_id: 0,
            requests: HashMap::new(),
            subs: HashMap::new(),
            held: HashMap::new(),
            gone: HashSet::new(),
        }
    }

    pub fn ready(&self) -> bool {
        self.welcomed && !self.broken
    }

    /// The text of one server frame, decoded within `limits`; the parts of a
    /// frame are joined first. A frame over `FRAME_BYTES`, a frame while the
    /// parts of another wait, and a part inside parts are breaks.
    pub fn decode(&mut self, text: &str, limits: Limits) -> Checked<Decoded> {
        if text.len() > FRAME_BYTES {
            return Err(Broken("frame size"));
        }
        let value = json::decode_within(text, limits)?;
        if !self.welcomed {
            return Ok(Decoded::Handshake(value));
        }
        if !is_part(&value) {
            return if self.joiner.pending() {
                Err(Broken("frame in parts"))
            } else {
                Ok(Decoded::Frame(value))
            };
        }
        match self.joiner.take(&value, limits.frame_bytes)? {
            None => Ok(Decoded::Pending),
            Some(joined) => {
                let value = json::decode_within(&joined, limits)?;
                if is_part(&value) {
                    Err(Broken("part in parts"))
                } else {
                    Ok(Decoded::Frame(value))
                }
            }
        }
    }

    /// The id and the frames of a request of `op`, kept in flight until its
    /// reply.
    pub fn request(
        &mut self,
        op: &'static str,
        params: Json,
        request: Request,
    ) -> Result<(String, Vec<String>), Refusal> {
        if !self.ready() {
            return Err(Refusal::NotReady);
        }
        if self.requests.len() >= MAX_IN_FLIGHT {
            return Err(Refusal::Busy);
        }
        let id = self.next_id.to_string();
        let text = object([
            ("type", "req".into()),
            ("id", id.as_str().into()),
            ("op", op.into()),
            ("params", params),
        ])
        .encode();
        let frames = parts::split(text).map_err(|TooLarge| Refusal::TooLarge)?;
        self.next_id += 1;
        self.requests.insert(id.clone(), request);
        Ok((id, frames))
    }

    /// The live subscription of `session`.
    pub fn live_sub(&self, session: &str) -> Option<String> {
        self.subs
            .iter()
            .find(|(_, s)| *s == session)
            .map(|(sub, _)| sub.clone())
    }

    /// `session` has a live subscription or a subscribe in flight.
    pub fn attached(&self, session: &str) -> bool {
        self.subs.values().any(|s| s == session) || self.in_flight(session, &["subscribe"])
    }

    /// A request of one of `ops` for `session` is in flight.
    pub fn in_flight(&self, session: &str, ops: &[&str]) -> bool {
        self.requests
            .values()
            .any(|r| ops.contains(&r.op) && r.session.as_deref() == Some(session))
    }

    /// The subscriptions that the server holds or can hold for the
    /// connection: the live ones and the subscribes in flight.
    pub fn subscriptions(&self) -> usize {
        self.subs.len()
            + self
                .requests
                .values()
                .filter(|r| r.op == "subscribe")
                .count()
    }
}

fn is_part(value: &Json) -> bool {
    value.get("type").and_then(Json::as_str) == Some("part")
}
