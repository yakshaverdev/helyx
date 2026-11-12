//! The bindings of the Helyx client kit for Swift (`docs/features/client-kit.md`,
//! "Bindings for Swift"): the network layer and the operations of the desktop
//! app, over UniFFI with proc macros and no UDL file. A host starts a
//! `Connection` for an address and a token, sends the operations that it
//! exposes, and receives the state on each change through its `NetListener`.
//! One rule is of a mobile host: `Connection::became_active` drops a socket
//! that a suspend killed and connects again.

uniffi::setup_scaffolding!();

mod connection;
mod convert;
mod types;

pub use connection::{Connection, NetListener};
pub use types::{
    Ask, Block, LiveSession, Message, NetError, Outcome, Queue, RequestLine, RequestState, Role,
    Row, SavedSession, SendOutcome, SessionState, Shown, Snapshot,
};
