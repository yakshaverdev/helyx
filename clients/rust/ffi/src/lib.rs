//! The bindings of the Helyx client kit for Swift (`docs/features/client-kit.md`,
//! "Bindings for Swift" and "A remote server"): the network layer and the
//! operations of the desktop app, over UniFFI with proc macros and no UDL
//! file. A host starts a `Connection` for a local server, a pairing link, or
//! the state of a paired server, sends the operations that it exposes, and
//! receives the state on each change through its `NetListener`. `read_block`,
//! `form_answer`, and `approval_answer` give the UI blocks and the answers to
//! Swift as owned values (`docs/features/ios-app.md`). One rule is of a mobile
//! host: `Connection::became_active` drops a socket that a suspend killed and
//! connects again.

uniffi::setup_scaffolding!();

mod blocks;
mod connection;
mod convert;
mod types;

pub use blocks::{answering, approval_answer, form_answer, read_block};
pub use connection::{Connection, NetListener, PairingStorage};
pub use types::{
    Ask, Block, BlockView, FormAnswerItem, FormOption, FormQuestion, LiveSession, Message,
    NetError, Outcome, Queue, Record, RequestLine, RequestState, Role, Row, SavedSession,
    SendOutcome, SessionState, Shown, Snapshot, Status,
};
