//! The intent of the host to follow one session, and the state of the
//! following, derived on read (`docs/features/client-kit.md`, slice 3). The
//! intent is what the host stated, and only the host changes it; the live
//! subscription, the requests in flight, and the answers of the server are
//! read from the connection, and the client reconciles the two after each
//! input.

use crate::fold::State;

#[derive(Debug, Default)]
pub(crate) struct Session {
    pub state: State,
    /// The host follows the session: from `subscribe` to `unsubscribe`.
    wanted: bool,
    /// The number of the last statement of the host for the session
    /// (`Client::statements`). An answer of the server holds the session only
    /// while it answers that statement.
    stated: u64,
}

impl Session {
    pub fn wanted(&self) -> bool {
        self.wanted
    }

    pub fn stated(&self) -> u64 {
        self.stated
    }

    /// `subscribe` (`true`) or `unsubscribe` (`false`) of the host, its
    /// statement number `stated`.
    pub fn state_intent(&mut self, wanted: bool, stated: u64) {
        self.wanted = wanted;
        self.stated = stated;
    }
}

/// The state of the following of a session, derived from the intent of the
/// host and the frames of the server (`Client::follow`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Follow {
    /// The host does not follow it.
    Unwanted,
    /// A subscription of it lives.
    Live,
    /// Its subscribe is in flight.
    Subscribing,
    /// No subscribe of it can go now; it goes when the wait ends.
    Waiting(Wait),
    /// No request of it goes on this connection until the host states its
    /// intent again or a new connection starts, or for `Hold::Ended`, until
    /// a `history` reply says that the instance that ended was replaced.
    Held(Hold),
}

/// Why a subscribe of a followed session waits.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Wait {
    /// No connection has taken the handshake.
    Connection,
    /// Its old subscription ends: an `unsubscribe` of it is in flight.
    Ending,
    /// The 16 subscriptions of the connection are taken, by live ones and
    /// subscribes in flight. `unwanted` names the sessions among them that
    /// the host does not follow, in byte order: the client unsubscribes each
    /// when a request place is free, unless the server refused it for the
    /// last statement of the host, which the host can state again.
    Places { unwanted: Vec<String> },
    /// The 16 requests in flight wait for their replies.
    Requests,
}

/// Why a followed session is held.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Hold {
    /// Its subscription ended with `session_end`: the session stopped. A
    /// `history` reply that says that its instance was replaced ends it.
    Ended,
    /// The server answered a request that reconciles it with an error, or no
    /// request of it fits the request size.
    Refused,
}
