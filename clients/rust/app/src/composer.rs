//! The composer of the window (`docs/features/client-kit.md`, slice 4). It
//! takes the rules of the TUI composer that fit a GUI
//! (`docs/features/multiline-composer.md`): Enter sends, Shift+Enter adds a
//! new line, and a text over 4 MiB is not sent. While a turn runs, Enter
//! sends `steer` and Option+Enter sends `follow_up`, as in the TUI; with no
//! turn it sends `prompt`. A send that the network takes leaves the
//! composer, and a send that it refuses keeps its text.
//!
//! This module holds no GPUI: it is compiled and tested on every platform, so
//! the iOS app can use the same rules.

use helyx_client_core::operation::Operation;

/// The character that marks the cursor in a drawn text: a thin bar at the
/// character boundary. GPUI has no text layout to read, so the window draws
/// the caret as one more character.
pub const CARET: &str = "\u{258f}";

/// The window's number of a send whose outcome the window waits for: a send
/// of the composer, or the answer of an ask. The network layer reports one
/// `SendOutcome` for it, and the input drops the report once it has read it.
pub use helyx_client_net::send::SendId;

/// What became of a send that the window numbered, from the line of its
/// request: the network layer's `SendOutcome`.
pub use helyx_client_net::send::SendOutcome;

/// What Enter sends, from the composer.
#[derive(Debug, Clone, PartialEq)]
pub enum Send {
    /// The operation of the text.
    Operation(Operation),
    /// The composer has no text.
    Empty,
    /// No session is followed.
    NoSession,
    /// The text is over `MAX_TEXT_BYTES`.
    TooLarge,
}

/// A text with a cursor. A bounded text is cut at its bound, at a character
/// boundary, when a paste or a write would pass it.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct Text {
    text: String,
    /// A byte offset at a character boundary.
    cursor: usize,
    /// The most bytes of the text; none is no bound.
    max: Option<usize>,
}

impl Text {
    /// A text of at most `max` bytes.
    pub fn bounded(max: usize) -> Text {
        Text {
            max: Some(max),
            ..Text::default()
        }
    }

    pub fn text(&self) -> &str {
        &self.text
    }

    pub fn is_empty(&self) -> bool {
        self.text.is_empty()
    }

    /// The bytes that the text takes without passing its bound.
    fn room(&self) -> usize {
        self.max
            .map_or(usize::MAX, |max| max.saturating_sub(self.text.len()))
    }

    /// Inserts `text` at the cursor, cut to the room of a bounded text at a
    /// character boundary. Gives the bytes that it took.
    pub fn insert(&mut self, text: &str) -> usize {
        let mut end = text.len().min(self.room());
        while !text.is_char_boundary(end) {
            end -= 1;
        }
        self.text.insert_str(self.cursor, &text[..end]);
        self.cursor += end;
        end
    }

    /// Removes the character before the cursor.
    pub fn backspace(&mut self) -> bool {
        let Some(c) = self.text[..self.cursor].chars().next_back() else {
            return false;
        };
        self.cursor -= c.len_utf8();
        self.text.remove(self.cursor);
        true
    }

    /// Removes the character at the cursor.
    pub fn delete(&mut self) -> bool {
        if self.cursor == self.text.len() {
            return false;
        }
        self.text.remove(self.cursor);
        true
    }

    pub fn left(&mut self) -> bool {
        let Some(c) = self.text[..self.cursor].chars().next_back() else {
            return false;
        };
        self.cursor -= c.len_utf8();
        true
    }

    pub fn right(&mut self) -> bool {
        let Some(c) = self.text[self.cursor..].chars().next() else {
            return false;
        };
        self.cursor += c.len_utf8();
        true
    }

    /// Moves to the start of the cursor line.
    pub fn home(&mut self) {
        self.cursor = self.text[..self.cursor].rfind('\n').map_or(0, |at| at + 1);
    }

    /// Moves to the end of the cursor line.
    pub fn end(&mut self) {
        self.cursor = self.text[self.cursor..]
            .find('\n')
            .map_or(self.text.len(), |at| self.cursor + at);
    }

    /// Sets the text, cut to the bound of a bounded text at a character
    /// boundary, with the cursor at its end.
    pub fn set(&mut self, text: &str) {
        self.text.clear();
        self.cursor = 0;
        self.insert(text);
    }

    pub fn clear(&mut self) {
        self.text.clear();
        self.cursor = 0;
    }

    /// The text with the caret at its cursor.
    pub fn display(&self) -> String {
        let (before, after) = self.text.split_at(self.cursor);
        format!("{before}{CARET}{after}")
    }

    /// The last `lines` lines of the display, and whether earlier lines are
    /// left out: a composer in the window shows a window on the end, where
    /// the cursor is when a person types.
    pub fn window(&self, lines: usize) -> (String, bool) {
        let display = self.display();
        let parts: Vec<&str> = display.split('\n').collect();
        match parts.len() <= lines {
            true => (display, false),
            false => (parts[parts.len() - lines..].join("\n"), true),
        }
    }
}

/// The composer of the window.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct Composer {
    pub text: Text,
}

impl Composer {
    pub fn new() -> Composer {
        Composer::default()
    }

    /// Enter: the operation of the text. With no turn it is a `prompt`; while
    /// a turn runs, Enter steers and `follow_up` (Option+Enter) waits for the
    /// turn, as in the TUI.
    pub fn send(&self, session: Option<&str>, running: bool, follow_up: bool) -> Send {
        let Some(session) = session else {
            return Send::NoSession;
        };
        if self.text.is_empty() {
            return Send::Empty;
        }
        let text = self.text.text();
        let operation = match (running, follow_up) {
            (false, _) => Operation::prompt(session, text),
            (true, false) => Operation::steer(session, text),
            (true, true) => Operation::follow_up(session, text),
        };
        // The only refusal of a message is its size.
        operation.map_or(Send::TooLarge, Send::Operation)
    }
}

/// The text of a paste, cleaned as the TUI cleans it: CRLF and a lone CR are
/// one new line, and a control character other than tab and LF drops, so a
/// pasted escape sequence cannot reach the window.
pub fn clean_paste(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut chars = text.chars().peekable();
    while let Some(c) = chars.next() {
        match c {
            '\r' => {
                if chars.peek() == Some(&'\n') {
                    chars.next();
                }
                out.push('\n');
            }
            '\n' | '\t' => out.push(c),
            c if c.is_control() => {}
            c => out.push(c),
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::{Composer, Send, Text, clean_paste};
    use helyx_client_core::operation::{MAX_TEXT_BYTES, Operation};

    fn typed(text: &str) -> Composer {
        let mut composer = Composer::new();
        composer.text.insert(text);
        composer
    }

    #[test]
    fn enter_sends_the_prompt_idle_and_steers_while_running() {
        let composer = typed("hello");
        assert_eq!(
            composer.send(Some("s1"), false, false),
            Send::Operation(Operation::prompt("s1", "hello").unwrap())
        );
        // Enter steers a running turn; Option+Enter follows it up.
        assert_eq!(
            composer.send(Some("s1"), true, false),
            Send::Operation(Operation::steer("s1", "hello").unwrap())
        );
        assert_eq!(
            composer.send(Some("s1"), true, true),
            Send::Operation(Operation::follow_up("s1", "hello").unwrap())
        );
    }

    #[test]
    fn an_empty_composer_and_no_session_send_nothing() {
        let composer = Composer::new();
        assert_eq!(composer.send(Some("s1"), false, false), Send::Empty);
        assert_eq!(typed("hi").send(None, false, false), Send::NoSession);
    }

    #[test]
    fn a_text_over_the_bound_is_not_sent() {
        let mut composer = typed(&"a".repeat(MAX_TEXT_BYTES));
        assert!(matches!(
            composer.send(Some("s1"), false, false),
            Send::Operation(_)
        ));
        composer.text.insert("a");
        assert_eq!(composer.send(Some("s1"), false, false), Send::TooLarge);
    }

    #[test]
    fn a_new_line_goes_at_the_cursor() {
        let mut text = Text::default();
        text.insert("ab");
        text.left();
        text.insert("\n");
        assert_eq!(text.text(), "a\nb");
        assert_eq!(text.display(), "a\n\u{258f}b");
        // Home and End move on the line of the cursor only.
        text.end();
        assert_eq!(text.display(), "a\nb\u{258f}");
        text.home();
        assert_eq!(text.display(), "a\n\u{258f}b");
    }

    #[test]
    fn an_edit_at_the_cursor_keeps_multibyte_characters_whole() {
        let mut text = Text::default();
        text.insert("aé b");
        text.left();
        // The cursor is before the `b`; Backspace takes the space.
        assert!(text.backspace());
        assert_eq!(text.text(), "aéb");
        assert!(text.delete());
        assert_eq!(text.text(), "aé");
        assert!(text.backspace());
        assert_eq!(text.text(), "a");
        assert!(text.backspace());
        assert!(!text.backspace());
        assert!(!text.delete());
    }

    #[test]
    fn a_bounded_text_cuts_a_paste_at_a_character_boundary() {
        let mut text = Text::bounded(4);
        assert_eq!(text.insert("ééé"), 4);
        assert_eq!(text.text(), "éé");
        assert_eq!(text.insert("x"), 0);
        text.clear();
        assert_eq!(text.insert("abcdef"), 4);
        assert_eq!(text.text(), "abcd");
        text.set("xy");
        assert_eq!(text.display(), "xy\u{258f}");
    }

    #[test]
    fn the_window_shows_the_end_of_a_long_text() {
        let mut text = Text::default();
        text.insert("1\n2\n3");
        assert_eq!(text.window(8), ("1\n2\n3\u{258f}".to_owned(), false));
        let (shown, cut) = text.window(2);
        assert!(cut);
        assert_eq!(shown, "2\n3\u{258f}");
    }

    #[test]
    fn the_display_shows_the_caret_at_the_cursor() {
        let mut text = Text::default();
        assert_eq!(text.display(), super::CARET);
        text.insert("ab");
        text.left();
        assert_eq!(text.display(), format!("a{}b", super::CARET));
    }

    #[test]
    fn a_paste_keeps_lines_and_tabs_and_drops_other_control_characters() {
        assert_eq!(clean_paste("a\r\nb\rc\td\u{7}e"), "a\nb\nc\tde");
        assert_eq!(clean_paste("x\u{1b}[31m"), "x[31m");
    }
}
