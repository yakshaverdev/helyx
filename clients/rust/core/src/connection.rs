//! The state of one connection to the server: the handshake, the parts of a
//! frame, the requests in flight, and the live subscriptions. It turns the
//! text of each server frame into a decoded frame, and a request into its
//! frames; `Client` keeps what outlives the connection.

use crate::check::{Broken, Checked};
use crate::follow::Hold;
use crate::handshake::{Handshake, Token};
use crate::json::{self, Json, Limits, object};
use crate::parts::{self, FRAME_BYTES, Joiner, TooLarge};
use std::collections::{HashMap, HashSet};
use std::time::Duration;

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

/// The last answer of the server that stops the reconciling of a session on
/// one connection, and the statement of the host that it answered.
#[derive(Debug)]
pub(crate) struct Answer {
    pub stop: Stop,
    pub stated: u64,
}

#[derive(Debug)]
pub(crate) enum Stop {
    /// A `session_end` of a subscription of the instance.
    Ended(String),
    /// An error answer, or a request that does not fit the request size.
    Refused,
}

#[derive(Debug)]
pub(crate) struct Request {
    pub op: &'static str,
    /// The session that the request names.
    pub session: Option<String>,
    /// The subscription that an `unsubscribe` ends.
    pub sub: Option<String>,
    /// The statement of the host that a subscribe or an `unsubscribe` of the
    /// session reconciles; none for another request, which is one of the
    /// host's operations and whose reply the host shows.
    pub stated: Option<u64>,
    /// The `instance_id` that a request names, as a `history` page does.
    pub instance: Option<String>,
    /// The deadline of the server for the op from its send
    /// (`crate::operation::deadline`); none for an op that it does not bound.
    /// The connection keeps no timer: it holds the bound for the host.
    pub deadline: Option<Duration>,
}

/// A server frame, decoded and joined from its parts.
pub(crate) enum Decoded {
    Handshake(Json),
    Frame(Json),
    /// A part of a frame whose other parts have not come.
    Pending,
}

/// The state of one connection's link to the server: the handshake is on, the
/// link is open, or it ended in a break or a refusal.
#[derive(Debug)]
pub(crate) enum Link {
    /// The handshake is on: each frame is one of its own until its answer.
    Handshake(Handshake),
    /// The server took the handshake: requests may go.
    Open,
    /// The connection ended with a break or a refusal: no frame is taken, and
    /// a close stops the client.
    Ended,
}

#[derive(Debug)]
pub(crate) struct Connection {
    pub link: Link,
    joiner: Joiner,
    next_id: u64,
    pub requests: HashMap<String, Request>,
    /// The session of each live subscription.
    pub subs: HashMap<String, String>,
    /// The last answer of the server that stops the reconciling of each
    /// session, a refusal or an end (`hold`).
    pub answers: HashMap<String, Answer>,
    /// The instance of each session that a `history` reply of
    /// `instance_changed` says the session replaced, when it was the instance
    /// of the state; it stays, for a replaced instance never serves again.
    pub replaced: HashMap<String, String>,
    /// The subscriptions that an `unsubscribe` got `unknown_sub` for: the
    /// server holds none of them. A frame of one that was on the way is
    /// dropped.
    pub gone: HashSet<String>,
    /// The records feed of the user is live on this connection: its reply
    /// came and its `records.unsubscribe` did not.
    pub records: bool,
}

impl Connection {
    pub fn new(token: Option<Token>) -> Connection {
        Connection {
            link: Link::Handshake(Handshake::new(token)),
            joiner: Joiner::default(),
            next_id: 0,
            requests: HashMap::new(),
            subs: HashMap::new(),
            answers: HashMap::new(),
            replaced: HashMap::new(),
            gone: HashSet::new(),
            records: false,
        }
    }

    pub fn ready(&self) -> bool {
        matches!(self.link, Link::Open)
    }

    /// The text of one server frame, decoded within `limits`; the parts of a
    /// frame are joined first. A frame over `FRAME_BYTES`, a frame while the
    /// parts of another wait, and a part inside parts are breaks.
    pub fn decode(&mut self, text: &str, limits: Limits) -> Checked<Decoded> {
        if text.len() > FRAME_BYTES {
            return Err(Broken("frame size"));
        }
        let value = json::decode_within(text, limits)?;
        match self.link {
            Link::Handshake(_) => return Ok(Decoded::Handshake(value)),
            Link::Open => {}
            // `Client::take` refuses a frame of an ended connection.
            Link::Ended => return Err(Broken("no connection")),
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

    /// Why `session` is held for the statement `stated` of the host, derived
    /// from the last answer of the server that stops it: one that answered
    /// that statement, and an end only while its instance is not replaced.
    pub fn hold(&self, session: &str, stated: u64) -> Option<Hold> {
        let answer = self.answers.get(session).filter(|a| a.stated == stated)?;
        match &answer.stop {
            Stop::Refused => Some(Hold::Refused),
            Stop::Ended(instance) if self.replaced.get(session) == Some(instance) => None,
            Stop::Ended(_) => Some(Hold::Ended),
        }
    }

    /// The answer of the server that stops `session`, which answered the
    /// statement `stated` of the host.
    pub fn stop(&mut self, session: String, stop: Stop, stated: u64) {
        self.answers.insert(session, Answer { stop, stated });
    }

    /// Drops what the connection keeps of a session that the client forgot.
    pub fn forget(&mut self, session: &str) {
        self.answers.remove(session);
        self.replaced.remove(session);
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
