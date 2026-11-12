//! The client core of Helyx for wire protocol 15 (`docs/features/wire-protocol.md`,
//! `docs/features/client-kit.md`): the frame checks, the handshake, and the fold
//! of events into the state that a client shows. It does no I/O: a host feeds
//! it the decoded frames of one connection and sends the frames it returns.

pub mod attention;
mod check;
pub mod client;
mod connection;
pub mod event;
pub mod fold;
mod follow;
pub mod frame;
pub mod handshake;
pub mod json;
pub mod message;
pub mod operation;
pub mod parts;
mod reconcile;
pub mod records;
pub mod seq;
pub mod transcript;
pub mod ui_block;
pub mod usage;
pub mod vocabulary;

pub use check::{Broken, Checked};
