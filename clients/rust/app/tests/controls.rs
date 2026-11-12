//! The stop confirm of the live list: a second click on the same row inside
//! the window sends the stop, and anything else only arms it.

use helyx_desktop::controls::{STOP_CONFIRM, confirm_stop};
use std::time::{Duration, Instant};

#[test]
fn a_second_click_on_the_same_row_inside_the_window_sends_the_stop() {
    let at = Instant::now();
    let armed = ("s1".to_owned(), at);
    assert!(confirm_stop(Some(&armed), "s1", at));
    // A click one millisecond inside the window still confirms.
    let inside = at + STOP_CONFIRM - Duration::from_millis(1);
    assert!(confirm_stop(Some(&armed), "s1", inside));
}

#[test]
fn another_row_and_a_click_after_the_window_only_arm_again() {
    let at = Instant::now();
    let armed = ("s1".to_owned(), at);
    assert!(!confirm_stop(Some(&armed), "s2", at));
    assert!(!confirm_stop(Some(&armed), "s1", at + STOP_CONFIRM));
    assert!(!confirm_stop(None, "s1", at));
}
