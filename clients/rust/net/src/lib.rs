//! The network layer of the Helyx client kit (`docs/features/client-kit.md`,
//! "The network layer"): the WebSocket thread, its reconnect rules, its
//! watchdog, and the guards of its socket. A host starts the thread with the
//! `Server` of the layer, sends `Command`s on a channel, reads `Shared` under
//! its lock, and is called back when the state changes. The layer holds no UI
//! type, so a desktop app, a mobile app through its bindings, and a test drive
//! the same code. The feature `stub` builds the stub server on the loopback
//! for the tests of this crate and of its bindings; only a test enables it, so
//! no build of a host holds it.

mod net;
pub mod send;
pub mod socket;
#[cfg(feature = "stub")]
pub mod stub;

pub use net::{
    BUSY, Command, MAX_LINES, MAX_PROMPT_BYTES, RequestLine, RequestState, Server, Shared,
    became_active, follow_line, run, run_with,
};
