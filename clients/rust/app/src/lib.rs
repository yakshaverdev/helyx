//! The parts of the desktop app that run on every platform: the composer,
//! the ask, the input of the window, the settings, and the network thread
//! (`docs/features/client-kit.md`, slice 4).

pub mod ask;
pub mod composer;
pub mod input;
pub mod net;
pub mod settings;
pub mod socket;
