//! The AppleScript escape of a notification, which a pure function holds so
//! that the text of a model cannot end the script.
#![cfg(target_os = "macos")]

use helyx_desktop::notify::escape;

#[test]
fn a_quote_and_a_backslash_are_escaped() {
    assert_eq!(escape("say \"hi\""), "say \\\"hi\\\"");
    assert_eq!(escape(r"a\b"), r"a\\b");
    assert_eq!(escape("plain text"), "plain text");
}
