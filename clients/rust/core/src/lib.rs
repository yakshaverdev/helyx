//! The client core of Helyx for wire protocol 3 (`docs/features/wire-protocol.md`,
//! `docs/features/client-kit.md`): the frame checks, the handshake, and the fold
//! of events into the state that a client shows. It does no I/O: a host feeds
//! it the decoded frames of one connection and sends the frames it returns.

mod check;
pub mod event;
pub mod fold;
pub mod frame;
pub mod handshake;
pub mod json;
pub mod message;
pub mod transcript;

pub use check::{Broken, Checked};
