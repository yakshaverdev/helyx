//! The notification of the attention of the followed session on macOS
//! (`docs/features/client-kit.md`, slice 4): one line through `osascript`,
//! with the title `Helyx`. A notification is a hint, not data, so a failure
//! is one line on stderr and nothing else.

use helyx_client_core::attention::Attention;
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};

/// True while the `osascript` of a post runs: a post that finds it true is
/// dropped, so a burst of events leaves one process at a time.
static RUNNING: AtomicBool = AtomicBool::new(false);

/// Shows `attention` as a notification. A post while one runs returns at
/// once, and the process runs on a thread of its own, so a slow `osascript`
/// never holds a frame.
pub fn post(attention: &Attention) {
    if RUNNING.swap(true, Ordering::AcqRel) {
        return;
    }
    let script = script(&attention.line());
    std::thread::spawn(move || {
        let result = Command::new("/usr/bin/osascript")
            .arg("-e")
            .arg(&script)
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status();
        match result {
            Ok(status) if status.success() => {}
            Ok(status) => eprintln!("helyx-desktop: notification failed: {status}"),
            Err(error) => eprintln!("helyx-desktop: notification failed: {error}"),
        }
        RUNNING.store(false, Ordering::Release);
    });
}

/// The script of a notification whose text is `text`. The core cleaned the
/// text, so it holds no new line; the script goes to `osascript` as one
/// argument, with no shell.
fn script(text: &str) -> String {
    format!(
        "display notification \"{}\" with title \"Helyx\"",
        escape(text)
    )
}

/// `text` with `\` and `"` escaped for an AppleScript string.
pub fn escape(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    for c in text.chars() {
        if c == '\\' || c == '"' {
            out.push('\\');
        }
        out.push(c);
    }
    out
}
