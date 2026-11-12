//! The rules of the session controls (`docs/features/client-kit.md`, slice 4):
//! the stop of a live row, and the model ref and compaction above the
//! composer. A stop ends a running turn too, so one click only arms it, and a
//! second click on the same row inside `STOP_CONFIRM` sends it.
//!
//! This module holds no GPUI: it is compiled and tested on every platform, so
//! the iOS app can use the same rule.

use std::time::{Duration, Instant};

/// The time in which a second click on **stop?** sends the stop. The window
/// keeps no timer: it checks this window on the second click.
pub const STOP_CONFIRM: Duration = Duration::from_secs(3);

/// Whether a click on `row` sends the stop that `armed` holds: the same row,
/// and no more than `STOP_CONFIRM` since it was armed. An arm of another row,
/// or one older than the window, only arms again.
pub fn confirm_stop(armed: Option<&(String, Instant)>, row: &str, now: Instant) -> bool {
    armed.is_some_and(|(armed_row, at)| {
        armed_row == row && now.saturating_duration_since(*at) < STOP_CONFIRM
    })
}
