//! The parts of the desktop app: the composer, the ask, the input of the
//! window, and the settings. The network layer is the shared crate
//! `helyx_client_net` (`docs/features/client-kit.md`, "The network layer").

pub mod ask;
pub mod composer;
pub mod controls;
pub mod input;
pub use helyx_client_net as net;
pub mod settings;
