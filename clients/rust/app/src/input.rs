//! The input of the window (`docs/features/client-kit.md`, slice 4): the
//! composer, the folder of a new session, the model ref of the followed
//! session, and the ask that takes the keys while it is open. One key handler
//! of the window gives each press here, so the window needs no per-field
//! focus: a click sets the field, and every key goes to it. An ask takes every
//! key while it is open, and the composer keeps its text, as in the TUI.
//!
//! A send of the composer, and the answer of an ask, are numbered. The input
//! marks the send pending at the key press, before any network thread step,
//! and settles it from one outcome of that number: `ok` empties the composer
//! and keeps an ask hidden, and a refusal, an error reply, or a lost reply
//! keeps the text and shows the ask again, because only the user decides
//! whether to send it again (ADR 0006 §4). The TUI blocks on the send in the
//! same way (`Helyx.TUI.send_message/3`).
//!
//! This module holds no GPUI: it is compiled and tested on every platform.

use crate::ask::{Key as AskKey, Outcome, Panel};
use crate::composer::{Composer, Send, SendId, SendOutcome, Text, clean_paste};
use helyx_client_core::json::Json;
use helyx_client_core::message::Ask;
use helyx_client_core::operation::{Invalid, MAX_CWD_BYTES, MAX_MODEL_BYTES, Operation};

/// The most asks whose answers this window holds hidden at once. A mark
/// leaves when its ask ends or its answer fails. At the bound, a failed mark
/// leaves first, then the oldest settled mark. A pending mark never leaves,
/// so a new answer is refused while every mark is pending.
pub const MAX_HIDDEN_ANSWERS: usize = 16;
/// The line of a refusal while the client holds its 16 requests in flight.
/// The network layer gives the same text for `Refusal::Busy`.
pub use helyx_client_net::BUSY;
/// The line of a send that the stopped network thread cannot take.
pub const CONNECTION_STOPPED: &str = "the connection has stopped";
/// The line of a text over its bound: the composer and the compact control
/// give it as one.
const TEXT_TOO_LARGE: &str = "not sent: over 4 MiB";
/// The line of a control that needs a followed session.
const NO_SESSION: &str = "no session: pick one";

/// The field that the keys act on.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub enum Focus {
    #[default]
    Composer,
    Cwd,
    /// The model ref of the followed session.
    Model,
}

/// One key press, as the window gives it to the input. `text` is the
/// character that the key typed, if it typed one.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Press<'a> {
    pub key: &'a str,
    pub shift: bool,
    pub alt: bool,
    pub platform: bool,
    pub control: bool,
    pub text: Option<&'a str>,
}

/// What the window does after a key.
#[derive(Debug, Clone, PartialEq)]
pub enum Intent {
    /// Nothing goes to the network thread.
    None,
    /// Send this operation. `send` is the number of the send when the window
    /// waits for its outcome: a send of the composer, or the answer of an
    /// ask.
    Send {
        send: Option<SendId>,
        operation: Operation,
    },
    /// Read the clipboard and give it to `Input::paste`.
    Paste,
    /// Write the text of the focused field to the clipboard.
    Copy,
}

/// An ask whose answer this window sent, while it stays hidden: the session
/// that it belongs to, the panel's state, the send that settles it, and the
/// outcome of that send.
#[derive(Debug, Clone)]
struct Hidden {
    session: String,
    panel: Panel,
    send: SendId,
    /// The outcome of its send: none until the network reports one. A failed
    /// send shows the ask again when its session is followed, and a settled
    /// one may leave first when the map is bound.
    outcome: Option<SendOutcome>,
}

/// The input of the window.
#[derive(Debug, Clone)]
pub struct Input {
    pub composer: Composer,
    /// The folder of a new session: a path of at most `MAX_CWD_BYTES`.
    pub cwd: Text,
    /// The model ref of the followed session: at most `MAX_MODEL_BYTES`.
    pub model: Text,
    pub focus: Focus,
    /// The ask that takes the keys, the oldest open one that the window can
    /// read (`Panel::settle`).
    pub ask: Option<Panel>,
    /// The last line of the input for a person, such as `not sent: over
    /// 4 MiB`.
    pub notice: Option<String>,
    /// The send of the composer that the network has not settled: while it
    /// is pending, Enter sends nothing and the text does not change.
    composer_send: Option<SendId>,
    /// The asks whose answers are pending or answered `ok`, by ask id, in
    /// the order that they were answered, bounded to `MAX_HIDDEN_ANSWERS`.
    hidden: Vec<(String, Hidden)>,
    /// The session that the window follows, as of the last `sync`, so a
    /// hidden answer does not show in the asks of another session.
    session: Option<String>,
    next_send: SendId,
    /// The folder field took its default, so a field that the user cleared
    /// stays empty.
    cwd_defaulted: bool,
}

impl Default for Input {
    fn default() -> Input {
        Input {
            composer: Composer::new(),
            cwd: Text::bounded(MAX_CWD_BYTES),
            model: Text::bounded(MAX_MODEL_BYTES),
            focus: Focus::Composer,
            ask: None,
            notice: None,
            composer_send: None,
            hidden: vec![],
            session: None,
            next_send: 0,
            cwd_defaulted: false,
        }
    }
}

impl Input {
    pub fn new() -> Input {
        Input::default()
    }

    /// Takes the open asks of `session`: the oldest one that the window can
    /// answer, with the state that it kept while it stayed open. An ask whose
    /// answer is pending or answered stays hidden, also while another session
    /// is followed; one whose answer failed shows again, with its last
    /// answer.
    pub fn sync(&mut self, asks: &[Ask], session: Option<&str>) {
        self.session = session.map(str::to_owned);
        let Some(session_id) = session else {
            self.ask = Panel::settle(self.ask.take(), asks, &[]);
            return;
        };
        // The marks of this session whose ask ended leave; a failed one shows
        // again, with its panel when it is the oldest ask that the window
        // shows.
        let answering = Panel::answering(asks).map(str::to_owned);
        let mut ended = vec![];
        let mut failed = vec![];
        for (ask_id, hidden) in &self.hidden {
            if hidden.session != session_id {
                continue;
            }
            if !(asks.iter()).any(|ask| &ask.ask_id == ask_id) {
                ended.push(ask_id.clone());
            } else if matches!(hidden.outcome, Some(SendOutcome::Failed(_))) {
                failed.push(ask_id.clone());
            }
        }
        for ask_id in ended {
            self.hidden.retain(|(id, _)| id != &ask_id);
        }
        for ask_id in failed {
            let Some(at) = self.hidden.iter().position(|(id, _)| id == &ask_id) else {
                continue;
            };
            let (_, hidden) = self.hidden.remove(at);
            // The oldest ask takes the keys: its panel replaces one of a
            // later ask that the window showed meanwhile.
            if answering.as_deref() == Some(ask_id.as_str()) {
                self.ask = Some(hidden.panel);
            }
        }
        let skip: Vec<&str> = (self.hidden.iter())
            .filter(|(_, hidden)| hidden.session == session_id)
            .map(|(ask_id, _)| ask_id.as_str())
            .collect();
        self.ask = Panel::settle(self.ask.take(), asks, &skip);
    }

    /// Takes the outcome that the network thread reported for each numbered
    /// send: the text of a send of the composer leaves when the server
    /// answered `ok`, and stays when it did not; an ask whose answer failed
    /// shows again on the next `sync`. A report is read once and dropped.
    pub fn settle_outcomes(&mut self, outcomes: &[(SendId, SendOutcome)]) {
        for (send, outcome) in outcomes {
            if self.composer_send == Some(*send) {
                match outcome {
                    SendOutcome::Pending => {}
                    SendOutcome::Ok => {
                        self.composer.text.clear();
                        self.composer_send = None;
                    }
                    SendOutcome::Failed(_) => self.composer_send = None,
                }
            }
            if let Some((_, hidden)) = self
                .hidden
                .iter_mut()
                .find(|(_, hidden)| hidden.send == *send)
            {
                match outcome {
                    SendOutcome::Pending => {}
                    outcome => hidden.outcome = Some(outcome.clone()),
                }
            }
        }
    }

    /// Keeps the mark of an answered ask, within the bound of the map. A
    /// pending mark never leaves. At the bound, a failed mark leaves first,
    /// then the oldest settled mark. Gives the mark back, boxed, when every
    /// mark is pending: the caller then refuses the answer.
    fn hide_answer(&mut self, ask_id: String, hidden: Hidden) -> Result<(), Box<Hidden>> {
        if self.hidden.len() >= MAX_HIDDEN_ANSWERS {
            let at = (self.hidden.iter())
                .position(|(_, mark)| matches!(mark.outcome, Some(SendOutcome::Failed(_))))
                .or_else(|| {
                    (self.hidden.iter())
                        .position(|(_, mark)| matches!(mark.outcome, Some(SendOutcome::Ok)))
                });
            let Some(at) = at else {
                return Err(Box::new(hidden));
            };
            self.hidden.remove(at);
        }
        self.hidden.push((ask_id, hidden));
        Ok(())
    }

    /// Settles the sends of a command that the window could not give to the
    /// network thread. A channel that the stopped thread dropped refuses the
    /// send, so no outcome comes for it: settle its number as failed now, and
    /// tell the user why. Gives whether the channel refused the command.
    pub fn settle_refused<E>(&mut self, send: Option<SendId>, sent: Result<(), E>) -> bool {
        if sent.is_ok() {
            return false;
        }
        if let Some(send) = send {
            self.settle_outcomes(&[(send, SendOutcome::Failed(CONNECTION_STOPPED.into()))]);
        }
        self.notice = Some(CONNECTION_STOPPED.into());
        true
    }

    /// The answer of the open ask: the operation that sends it, hidden while
    /// its send is pending or answered `ok`, or the line of the form when the
    /// core refuses it. At the bound of the map, a pending mark never leaves,
    /// so an answer with no mark to drop stays open under the line of
    /// `BUSY`.
    pub fn answer(&mut self, session: Option<&str>, answer: Json) -> Intent {
        let Some(panel) = self.ask.take() else {
            return Intent::None;
        };
        let Some(session) = session else {
            self.ask = Some(panel);
            self.notice = Some(NO_SESSION.into());
            return Intent::None;
        };
        let ask_id = panel.ask_id.clone();
        let operation = match Operation::answer(session, &ask_id, answer) {
            Ok(operation) => operation,
            Err(invalid) => {
                let mut panel = panel;
                panel.fail(invalid.text());
                self.ask = Some(panel);
                return Intent::None;
            }
        };
        // The number is used only when the map keeps the mark: the next
        // accepted answer takes this same number.
        let send = self.next_send;
        let hidden = Hidden {
            session: session.to_owned(),
            panel,
            send,
            outcome: None,
        };
        match self.hide_answer(ask_id, hidden) {
            Ok(()) => {
                self.next_send += 1;
                self.notice = None;
                Intent::Send {
                    send: Some(send),
                    operation,
                }
            }
            Err(hidden) => {
                self.ask = Some(hidden.panel);
                self.notice = Some(BUSY.into());
                Intent::None
            }
        }
    }

    /// A default folder for a new session, once, while the field has none.
    pub fn default_cwd(&mut self, cwd: &str) {
        if !self.cwd_defaulted && self.cwd.is_empty() {
            self.cwd.set(cwd);
            self.cwd_defaulted = true;
        }
    }

    /// `text` into the focused field, or the Other line of the ask, as the
    /// clipboard gives it: cleaned of control characters. A paste on the
    /// Other line is one line, as in the TUI.
    pub fn paste(&mut self, text: &str) {
        let text = clean_paste(text);
        if let Some(ask) = self.ask.as_mut() {
            let line = text.replace('\n', " ");
            ask.press(AskKey::Text(&line));
            return;
        }
        match self.focus {
            // A send of the composer is pending: its text does not change.
            Focus::Composer if self.composer_send.is_some() => {}
            Focus::Composer => {
                self.composer.text.insert(&text);
            }
            // A folder and a model ref are one line: a new line or a tab of a
            // paste drops.
            Focus::Cwd => {
                self.cwd.insert(&one_line(&text));
            }
            Focus::Model => {
                self.model.insert(&one_line(&text));
            }
        }
    }

    /// The text that `Copy` takes: the field that the keys act on.
    pub fn copy(&self) -> String {
        if let Some(ask) = &self.ask {
            return ask
                .other()
                .map_or_else(String::new, |text| text.text().to_owned());
        }
        match self.focus {
            Focus::Composer => self.composer.text.text().to_owned(),
            Focus::Cwd => self.cwd.text().to_owned(),
            Focus::Model => self.model.text().to_owned(),
        }
    }

    /// One key press. `session` is the session that the window follows, and
    /// `running` whether a turn of it runs.
    pub fn press(&mut self, press: Press<'_>, session: Option<&str>, running: bool) -> Intent {
        // Cmd+V and Cmd+C act in every field, as the clipboard of the window.
        if press.platform {
            match press.key {
                "v" => return Intent::Paste,
                "c" => return Intent::Copy,
                _ => {}
            }
        }
        // Escape, and Cmd+. on a Mac, abort the running turn, also over an
        // ask, as in the TUI.
        if running && (press.key == "escape" || (press.platform && press.key == ".")) {
            return match session {
                Some(session) => Intent::Send {
                    send: None,
                    operation: Operation::abort(session),
                },
                None => Intent::None,
            };
        }
        if self.ask.is_some() {
            return self.ask_press(press, session);
        }
        match self.focus {
            Focus::Composer => self.composer_press(press, session, running),
            Focus::Cwd => self.cwd_press(press),
            Focus::Model => self.model_press(press, session),
        }
    }

    fn composer_press(&mut self, press: Press<'_>, session: Option<&str>, running: bool) -> Intent {
        if press.platform || press.control {
            // Cmd+Left and Cmd+Right move to the end of the line, as in any
            // text field of macOS.
            match (press.platform, press.key) {
                (true, "left") => self.composer.text.home(),
                (true, "right") => self.composer.text.end(),
                _ => {}
            }
            return Intent::None;
        }
        if self.composer_send.is_some() {
            // A send is pending: only moves, which do not change the text.
            // Enter sends nothing, and an edit key is ignored.
            return match press.key {
                "left" | "right" | "home" | "end" => {
                    edit(&mut self.composer.text, press);
                    Intent::None
                }
                _ => Intent::None,
            };
        }
        match press.key {
            // Enter sends, and Shift+Enter keeps the new line, as in the TUI.
            "enter" if press.shift => {
                self.composer.text.insert("\n");
                Intent::None
            }
            // Enter steers a running turn, and Option+Enter follows it up.
            "enter" => self.send(session, running, press.alt),
            _ => {
                edit(&mut self.composer.text, press);
                Intent::None
            }
        }
    }

    fn cwd_press(&mut self, press: Press<'_>) -> Intent {
        if press.control {
            return Intent::None;
        }
        if press.platform {
            match press.key {
                "left" => self.cwd.home(),
                "right" => self.cwd.end(),
                _ => {}
            }
            return Intent::None;
        }
        match press.key {
            "enter" => self.start().map_or(Intent::None, |operation| Intent::Send {
                send: None,
                operation,
            }),
            // Escape leaves the field; the composer takes the keys again.
            "escape" => {
                self.focus = Focus::Composer;
                Intent::None
            }
            _ => {
                edit(&mut self.cwd, press);
                Intent::None
            }
        }
    }

    fn model_press(&mut self, press: Press<'_>, session: Option<&str>) -> Intent {
        if press.control {
            return Intent::None;
        }
        if press.platform {
            match press.key {
                "left" => self.model.home(),
                "right" => self.model.end(),
                _ => {}
            }
            return Intent::None;
        }
        match press.key {
            "enter" => self.set_model(session),
            // Escape leaves the field; the composer takes the keys again.
            "escape" => {
                self.focus = Focus::Composer;
                Intent::None
            }
            _ => {
                edit(&mut self.model, press);
                Intent::None
            }
        }
    }

    /// The `start` of the folder field, when it has a folder.
    pub fn start(&self) -> Option<Operation> {
        (!self.cwd.is_empty())
            .then(|| Operation::start(self.cwd.text(), None).expect("a folder within its bound"))
    }

    /// The `set_model` of the ref in the field. The core checks the ref, so a
    /// mistake shows before a round trip, as the composer shows a text over
    /// its bound.
    pub fn set_model(&mut self, session: Option<&str>) -> Intent {
        let Some(session) = session else {
            self.notice = Some(NO_SESSION.into());
            return Intent::None;
        };
        match Operation::set_model(session, self.model.text()) {
            Ok(operation) => {
                self.notice = None;
                Intent::Send {
                    send: None,
                    operation,
                }
            }
            Err(invalid) => {
                self.notice = Some(not_sent(invalid));
                Intent::None
            }
        }
    }

    /// The `compact` of the composer text: a numbered send, so `ok` empties
    /// the composer as a send does. An empty composer compacts with no
    /// instructions. While a send of the composer waits, its text does not go
    /// again as instructions.
    pub fn compact(&mut self, session: Option<&str>) -> Intent {
        let Some(session) = session else {
            self.notice = Some(NO_SESSION.into());
            return Intent::None;
        };
        if self.composer_send.is_some() {
            return Intent::None;
        }
        match Operation::compact(session, self.composer.text.text()) {
            Ok(operation) => {
                let send = self.next_send;
                self.next_send += 1;
                self.composer_send = Some(send);
                self.notice = None;
                Intent::Send {
                    send: Some(send),
                    operation,
                }
            }
            Err(invalid) => {
                self.notice = Some(not_sent(invalid));
                Intent::None
            }
        }
    }

    /// The number of a send that the window numbers itself, such as the stop
    /// of a live row, whose outcome it reads to ask for a fresh live list.
    pub fn send_number(&mut self) -> SendId {
        let send = self.next_send;
        self.next_send += 1;
        send
    }

    fn ask_press(&mut self, press: Press<'_>, session: Option<&str>) -> Intent {
        if press.platform || press.control {
            return Intent::None;
        }
        let key = match (press.key, press.text) {
            ("up", _) => AskKey::Up,
            ("down", _) => AskKey::Down,
            ("space", _) => AskKey::Space,
            ("enter", _) => AskKey::Enter,
            ("backspace" | "delete", _) => AskKey::Backspace,
            ("tab", _) | (_, None) => return Intent::None,
            (_, Some(text)) => AskKey::Text(text),
        };
        let ask = self.ask.as_mut().expect("press gives keys to an open ask");
        match ask.press(key) {
            Outcome::None | Outcome::TooLarge => Intent::None,
            Outcome::Answer(answer) => self.answer(session, answer),
        }
    }

    fn send(&mut self, session: Option<&str>, running: bool, follow_up: bool) -> Intent {
        if self.composer_send.is_some() {
            return Intent::None;
        }
        match self.composer.send(session, running, follow_up) {
            Send::Operation(operation) => {
                let send = self.next_send;
                self.next_send += 1;
                self.composer_send = Some(send);
                self.notice = None;
                Intent::Send {
                    send: Some(send),
                    operation,
                }
            }
            Send::Empty => Intent::None,
            Send::NoSession => {
                self.notice = Some(NO_SESSION.into());
                Intent::None
            }
            Send::TooLarge => {
                self.notice = Some(TEXT_TOO_LARGE.into());
                Intent::None
            }
        }
    }
}

/// The one line of a paste into a field of one line: a new line or a tab
/// drops.
fn one_line(text: &str) -> String {
    text.chars().filter(|c| !matches!(c, '\n' | '\t')).collect()
}

/// The line of an operation that the core refused before it went, in the
/// form of the composer's line.
fn not_sent(invalid: Invalid) -> String {
    match invalid {
        Invalid::TextTooLarge => TEXT_TOO_LARGE.to_owned(),
        invalid => format!("not sent: {}", invalid.text()),
    }
}

/// A key of a text field with no modifier: an edit, a move, or the text that
/// it typed. Enter, Escape, Tab, Up, and Down do nothing here.
fn edit(text: &mut Text, press: Press<'_>) {
    match press.key {
        "backspace" => {
            text.backspace();
        }
        "delete" => {
            text.delete();
        }
        "left" => {
            text.left();
        }
        "right" => {
            text.right();
        }
        "home" => text.home(),
        "end" => text.end(),
        "tab" | "up" | "down" | "enter" | "escape" => {}
        _ => {
            if let Some(typed) = press.text {
                text.insert(typed);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{
        BUSY, CONNECTION_STOPPED, Focus, Input, Intent, MAX_HIDDEN_ANSWERS, NO_SESSION, Press,
        TEXT_TOO_LARGE,
    };
    use crate::composer::SendOutcome;
    use helyx_client_core::json::decode;
    use helyx_client_core::message::Ask;
    use helyx_client_core::operation::{MAX_CWD_BYTES, MAX_TEXT_BYTES, Operation};

    fn press<'a>(key: &'a str, text: Option<&'a str>) -> Press<'a> {
        Press {
            key,
            shift: false,
            alt: false,
            platform: false,
            control: false,
            text,
        }
    }

    fn enter() -> Press<'static> {
        press("enter", None)
    }

    fn typed(text: &'static str) -> Press<'static> {
        press(text, Some(text))
    }

    fn approval_ask(ask_id: &str) -> Ask {
        Ask {
            ask_id: ask_id.into(),
            call_id: "c1".into(),
            tool: "t".into(),
            request: decode(
                r#"{"kind":"approval","text":"allow bash?","tool":"bash","arguments":"{}"}"#,
            )
            .unwrap(),
        }
    }

    fn form_ask(ask_id: &str) -> Ask {
        Ask {
            ask_id: ask_id.into(),
            call_id: "c1".into(),
            tool: "t".into(),
            request: decode(
                r#"{"kind":"form","text":"1 question","questions":[{"question":"q","header":"h","options":[{"label":"a","description":""},{"label":"b","description":""}],"multi_select":false}]}"#,
            )
            .unwrap(),
        }
    }

    /// The number and the operation of a numbered send.
    fn send_of(intent: Intent) -> (u64, Operation) {
        let Intent::Send {
            send: Some(send),
            operation,
        } = intent
        else {
            panic!("a numbered send");
        };
        (send, operation)
    }

    #[test]
    fn enter_sends_the_prompt_and_shift_enter_a_new_line() {
        let mut input = Input::new();
        for text in ["he", "llo"] {
            assert_eq!(input.press(typed(text), Some("s1"), false), Intent::None);
        }
        let shift_enter = Press {
            shift: true,
            ..enter()
        };
        assert_eq!(input.press(shift_enter, Some("s1"), false), Intent::None);
        assert_eq!(input.composer.text.text(), "hello\n");
        assert_eq!(
            input.press(enter(), Some("s1"), false),
            Intent::Send {
                send: Some(0),
                operation: Operation::prompt("s1", "hello\n").unwrap(),
            }
        );
    }

    #[test]
    fn enter_steers_a_running_turn_and_option_enter_follows_it_up() {
        let mut input = Input::new();
        input.press(typed("hi"), Some("s1"), true);
        assert_eq!(
            input.press(enter(), Some("s1"), true),
            Intent::Send {
                send: Some(0),
                operation: Operation::steer("s1", "hi").unwrap(),
            }
        );
        // The first send is pending: Enter sends nothing until it settles.
        assert_eq!(input.press(enter(), Some("s1"), true), Intent::None);
        input.settle_outcomes(&[(0, SendOutcome::Ok)]);
        input.press(typed("again"), Some("s1"), true);
        let follow_up = Press {
            alt: true,
            ..enter()
        };
        assert_eq!(
            input.press(follow_up, Some("s1"), true),
            Intent::Send {
                send: Some(1),
                operation: Operation::follow_up("s1", "again").unwrap(),
            }
        );
    }

    #[test]
    fn two_enter_presses_before_a_settle_give_one_send() {
        let mut input = Input::new();
        input.press(typed("hello"), Some("s1"), false);
        let (send, _) = send_of(input.press(enter(), Some("s1"), false));
        assert!(input.composer_send.is_some());
        assert_eq!(input.press(enter(), Some("s1"), false), Intent::None);
        // The network took it: still one send, and Enter sends nothing.
        input.settle_outcomes(&[(send, SendOutcome::Pending)]);
        assert_eq!(input.press(enter(), Some("s1"), false), Intent::None);
        // `ok` empties the composer and unlocks it.
        input.settle_outcomes(&[(send, SendOutcome::Ok)]);
        assert!(input.composer_send.is_none());
        assert_eq!(input.composer.text.text(), "");
        assert_eq!(input.press(enter(), Some("s1"), false), Intent::None);
    }

    #[test]
    fn an_edit_key_while_a_send_is_pending_does_not_change_the_text() {
        let mut input = Input::new();
        input.press(typed("hello"), Some("s1"), false);
        let (send, _) = send_of(input.press(enter(), Some("s1"), false));
        // Text and new lines are ignored, and so is a paste into the composer.
        for key in [typed("x"), press("backspace", None), press("delete", None)] {
            assert_eq!(input.press(key, Some("s1"), false), Intent::None);
        }
        let shift_enter = Press {
            shift: true,
            ..enter()
        };
        assert_eq!(input.press(shift_enter, Some("s1"), false), Intent::None);
        input.paste("pasted");
        assert_eq!(input.composer.text.text(), "hello");
        // A move changes no text.
        assert_eq!(
            input.press(press("left", None), Some("s1"), false),
            Intent::None
        );
        assert_eq!(input.composer.text.text(), "hello");
        // The abort still works while the send is pending.
        assert_eq!(
            input.press(press("escape", None), Some("s1"), true),
            Intent::Send {
                send: None,
                operation: Operation::abort("s1"),
            }
        );
        input.settle_outcomes(&[(send, SendOutcome::Ok)]);
    }

    #[test]
    fn an_error_reply_keeps_the_text_and_a_retry_is_a_new_send() {
        let mut input = Input::new();
        input.press(typed("hello"), Some("s1"), false);
        let (first, _) = send_of(input.press(enter(), Some("s1"), false));
        input.settle_outcomes(&[(
            first,
            SendOutcome::Failed("queue_full: the queue is full".into()),
        )]);
        assert!(input.composer_send.is_none());
        assert_eq!(input.composer.text.text(), "hello");
        let (second, _) = send_of(input.press(enter(), Some("s1"), false));
        assert_ne!(first, second);
    }

    #[test]
    fn a_lost_reply_keeps_the_text() {
        let mut input = Input::new();
        input.press(typed("hello"), Some("s1"), false);
        let (send, _) = send_of(input.press(enter(), Some("s1"), false));
        input.settle_outcomes(&[(send, SendOutcome::Failed("the reply was lost".into()))]);
        assert!(input.composer_send.is_none());
        assert_eq!(input.composer.text.text(), "hello");
    }

    #[test]
    fn an_empty_composer_sends_nothing() {
        let mut input = Input::new();
        assert_eq!(input.press(enter(), Some("s1"), false), Intent::None);
        assert_eq!(input.notice, None);
        input.press(typed("hi"), Some("s1"), false);
        assert_eq!(input.press(enter(), None, false), Intent::None);
        assert_eq!(input.notice.as_deref(), Some("no session: pick one"));
    }

    #[test]
    fn a_text_over_the_bound_is_not_sent_and_stays() {
        let mut input = Input::new();
        input.composer.text.insert(&"a".repeat(MAX_TEXT_BYTES + 1));
        assert_eq!(input.press(enter(), Some("s1"), false), Intent::None);
        assert_eq!(input.notice.as_deref(), Some("not sent: over 4 MiB"));
        assert_eq!(input.composer.text.text().len(), MAX_TEXT_BYTES + 1);
    }

    #[test]
    fn escape_and_cmd_dot_abort_a_running_turn() {
        let mut input = Input::new();
        input.press(typed("hi"), Some("s1"), true);
        assert_eq!(
            input.press(press("escape", None), Some("s1"), true),
            Intent::Send {
                send: None,
                operation: Operation::abort("s1"),
            }
        );
        let cmd_dot = Press {
            key: ".",
            shift: false,
            alt: false,
            platform: true,
            control: false,
            text: None,
        };
        assert_eq!(
            input.press(cmd_dot, Some("s1"), true),
            Intent::Send {
                send: None,
                operation: Operation::abort("s1"),
            }
        );
        // With no turn, Escape leaves the field alone.
        assert_eq!(
            input.press(press("escape", None), Some("s1"), false),
            Intent::None
        );
    }

    #[test]
    fn an_approval_answers_through_the_one_path() {
        let mut input = Input::new();
        input.press(typed("kept"), Some("s1"), false);
        input.sync(&[approval_ask("a1")], Some("s1"));
        // A key of the ask does not reach the composer.
        input.press(typed("x"), Some("s1"), false);
        assert_eq!(input.composer.text.text(), "kept");
        // An approval has no form to take the keys; its buttons answer.
        assert_eq!(input.press(enter(), Some("s1"), false), Intent::None);
        let answer = decode(r#"{"decision":"allow"}"#).unwrap();
        let (send, operation) = send_of(input.answer(Some("s1"), answer.clone()));
        assert_eq!(send, 0);
        assert_eq!(operation, Operation::answer("s1", "a1", answer).unwrap());
        // The ask closes, and the composer has its text.
        input.sync(&[], Some("s1"));
        assert!(input.ask.is_none());
        assert_eq!(input.composer.text.text(), "kept");
    }

    #[test]
    fn a_form_takes_the_keys_and_sends_the_answer() {
        let mut input = Input::new();
        input.sync(&[form_ask("a1")], Some("s1"));
        assert_eq!(
            input.press(press("down", None), Some("s1"), false),
            Intent::None
        );
        let expected = Operation::answer(
            "s1",
            "a1",
            decode(r#"{"answers":[{"selected":["b"]}]}"#).unwrap(),
        )
        .unwrap();
        assert_eq!(
            input.press(enter(), Some("s1"), false),
            Intent::Send {
                send: Some(0),
                operation: expected,
            }
        );
    }

    #[test]
    fn space_on_the_other_line_types_a_space() {
        let mut input = Input::new();
        input.sync(&[form_ask("a1")], Some("s1"));
        // A typed character goes to the Other line; Space there is a space.
        input.press(typed("x"), Some("s1"), false);
        input.press(press("space", Some(" ")), Some("s1"), false);
        assert_eq!(input.ask.as_ref().unwrap().other().unwrap().text(), "x ");
    }

    #[test]
    fn a_paste_on_the_other_line_is_one_line() {
        let mut input = Input::new();
        input.sync(&[form_ask("a1")], Some("s1"));
        input.paste("one\ntwo\r\nthree");
        assert_eq!(
            input.ask.as_ref().unwrap().other().unwrap().text(),
            "one two three"
        );
    }

    #[test]
    fn an_answered_ask_stays_hidden_until_its_answer_fails() {
        let ask = form_ask("a1");
        let mut input = Input::new();
        input.sync(std::slice::from_ref(&ask), Some("s1"));
        // The user answers with the Other line, which the panel keeps.
        input.press(typed("an answer"), Some("s1"), false);
        let (send, _) = send_of(input.press(enter(), Some("s1"), false));
        assert!(input.ask.is_none());
        // Its request is on its way: hidden.
        input.settle_outcomes(&[(send, SendOutcome::Pending)]);
        input.sync(std::slice::from_ref(&ask), Some("s1"));
        assert!(input.ask.is_none());
        // The server answered `ok`: hidden until the server ends the ask.
        input.settle_outcomes(&[(send, SendOutcome::Ok)]);
        input.sync(std::slice::from_ref(&ask), Some("s1"));
        assert!(input.ask.is_none());
        // The server ends the ask: the mark leaves.
        input.sync(&[], Some("s1"));
        assert!(input.ask.is_none());
        assert!(input.hidden.is_empty());
    }

    #[test]
    fn a_failed_answer_shows_again_with_its_last_answer() {
        let ask = form_ask("a1");
        let mut input = Input::new();
        input.sync(std::slice::from_ref(&ask), Some("s1"));
        input.press(typed("an answer"), Some("s1"), false);
        let (send, _) = send_of(input.press(enter(), Some("s1"), false));
        input.settle_outcomes(&[(send, SendOutcome::Failed("busy: x".into()))]);
        input.sync(std::slice::from_ref(&ask), Some("s1"));
        assert!(input.ask.is_some());
        assert_eq!(
            input.ask.as_ref().unwrap().other().unwrap().text(),
            "an answer"
        );
        // The user sends it again; it is a new send, and the ask stays
        // hidden while that one is pending.
        let (again, _) = send_of(input.press(enter(), Some("s1"), false));
        assert_ne!(send, again);
        input.settle_outcomes(&[(again, SendOutcome::Pending)]);
        input.sync(std::slice::from_ref(&ask), Some("s1"));
        assert!(input.ask.is_none());
    }

    #[test]
    fn a_failed_older_answer_takes_the_keys_back_with_its_last_answer() {
        let first = form_ask("a1");
        let second = form_ask("a2");
        let asks = [first.clone(), second.clone()];
        let mut input = Input::new();
        input.sync(&asks, Some("s1"));
        // The oldest takes the keys; its answer hides it, and the next ask
        // shows.
        input.press(typed("first answer"), Some("s1"), false);
        let (send, _) = send_of(input.press(enter(), Some("s1"), false));
        input.sync(&asks, Some("s1"));
        assert_eq!(
            input.ask.as_ref().map(|panel| panel.ask_id.as_str()),
            Some("a2")
        );
        // The first answer fails: the oldest takes the keys again, with its
        // last answer.
        input.settle_outcomes(&[(send, SendOutcome::Failed("busy: x".into()))]);
        input.sync(&asks, Some("s1"));
        assert_eq!(
            input.ask.as_ref().map(|panel| panel.ask_id.as_str()),
            Some("a1")
        );
        assert_eq!(
            input.ask.as_ref().unwrap().other().unwrap().text(),
            "first answer"
        );
    }

    #[test]
    fn a_follow_of_another_session_keeps_a_pending_ask_hidden() {
        let ask = form_ask("a1");
        let mut input = Input::new();
        input.sync(std::slice::from_ref(&ask), Some("s1"));
        let (send, _) = send_of(input.press(enter(), Some("s1"), false));
        input.settle_outcomes(&[(send, SendOutcome::Pending)]);
        // Another session: its ask shows, and the answer of `a1` stays hidden.
        let other = form_ask("b1");
        input.sync(std::slice::from_ref(&other), Some("s2"));
        assert_eq!(
            input.ask.as_ref().map(|panel| panel.ask_id.as_str()),
            Some("b1")
        );
        // Back: `a1` is still hidden while its answer is pending.
        input.sync(std::slice::from_ref(&ask), Some("s1"));
        assert!(input.ask.is_none());
        // `ok` keeps it hidden, and the server ends it.
        input.settle_outcomes(&[(send, SendOutcome::Ok)]);
        input.sync(std::slice::from_ref(&ask), Some("s1"));
        assert!(input.ask.is_none());
        input.sync(&[], Some("s1"));
        assert!(input.ask.is_none());
    }

    #[test]
    fn a_failed_answer_shows_when_its_session_is_followed_again() {
        let ask = form_ask("a1");
        let mut input = Input::new();
        input.sync(std::slice::from_ref(&ask), Some("s1"));
        let (send, _) = send_of(input.press(enter(), Some("s1"), false));
        // The user follows another session, and the answer fails there.
        input.sync(&[form_ask("b1")], Some("s2"));
        input.settle_outcomes(&[(send, SendOutcome::Failed("busy: x".into()))]);
        input.sync(&[form_ask("b1")], Some("s2"));
        assert_eq!(
            input.ask.as_ref().map(|panel| panel.ask_id.as_str()),
            Some("b1")
        );
        // Back in its session, the ask shows again.
        input.sync(std::slice::from_ref(&ask), Some("s1"));
        assert_eq!(
            input.ask.as_ref().map(|panel| panel.ask_id.as_str()),
            Some("a1")
        );
    }

    #[test]
    fn the_hidden_marks_are_bounded() {
        let mut input = Input::new();
        // All of the asks stay open, as the session keeps them: each mark
        // stays until its ask ends or its answer fails.
        let mut open: Vec<Ask> = vec![];
        for n in 0..=MAX_HIDDEN_ANSWERS {
            let ask = form_ask(&format!("a{n}"));
            open.push(ask);
            input.sync(&open, Some("s1"));
            let (send, _) = send_of(input.press(enter(), Some("s1"), false));
            input.settle_outcomes(&[(send, SendOutcome::Ok)]);
        }
        // The map holds the bound, and the oldest settled mark left.
        assert_eq!(input.hidden.len(), MAX_HIDDEN_ANSWERS);
        assert!(!input.hidden.iter().any(|(ask_id, _)| ask_id == "a0"));
        assert!(
            input
                .hidden
                .iter()
                .any(|(ask_id, _)| ask_id == &format!("a{MAX_HIDDEN_ANSWERS}"))
        );
    }

    #[test]
    fn a_new_answer_is_refused_while_every_mark_is_pending() {
        let mut input = Input::new();
        let mut open: Vec<Ask> = vec![];
        for n in 0..MAX_HIDDEN_ANSWERS {
            let ask = form_ask(&format!("a{n}"));
            open.push(ask);
            input.sync(&open, Some("s1"));
            let (send, _) = send_of(input.press(enter(), Some("s1"), false));
            input.settle_outcomes(&[(send, SendOutcome::Pending)]);
        }
        assert_eq!(input.hidden.len(), MAX_HIDDEN_ANSWERS);
        // The 17th answer finds every mark pending: it is refused, and the
        // next number is not used.
        let next = form_ask("a16");
        open.push(next);
        input.sync(&open, Some("s1"));
        assert_eq!(
            input.ask.as_ref().map(|panel| panel.ask_id.as_str()),
            Some("a16")
        );
        assert_eq!(input.press(enter(), Some("s1"), false), Intent::None);
        assert_eq!(input.notice.as_deref(), Some(BUSY));
        assert_eq!(
            input.ask.as_ref().map(|panel| panel.ask_id.as_str()),
            Some("a16")
        );
        assert_eq!(input.next_send, MAX_HIDDEN_ANSWERS as u64);
        // Every pending ask stays hidden, and the refused answer left no
        // mark.
        input.sync(&open, Some("s1"));
        assert_eq!(
            input.ask.as_ref().map(|panel| panel.ask_id.as_str()),
            Some("a16")
        );
        assert_eq!(input.hidden.len(), MAX_HIDDEN_ANSWERS);
        assert!(!input.hidden.iter().any(|(ask_id, _)| ask_id == "a16"));
    }

    #[test]
    fn a_new_answer_drops_a_failed_mark_before_a_pending_one() {
        let mut input = Input::new();
        // 15 pending marks in `s1`.
        let mut open: Vec<Ask> = vec![];
        for n in 0..MAX_HIDDEN_ANSWERS - 1 {
            let ask = form_ask(&format!("a{n}"));
            open.push(ask);
            input.sync(&open, Some("s1"));
            let (send, _) = send_of(input.press(enter(), Some("s1"), false));
            input.settle_outcomes(&[(send, SendOutcome::Pending)]);
        }
        // One failed mark in `s2`, which stays failed while the window does
        // not follow `s2`.
        input.sync(&[form_ask("b0")], Some("s2"));
        let (send, _) = send_of(input.press(enter(), Some("s2"), false));
        input.settle_outcomes(&[(send, SendOutcome::Failed("busy: x".into()))]);
        assert_eq!(input.hidden.len(), MAX_HIDDEN_ANSWERS);
        // The new answer drops the failed mark of `s2`, not a pending one.
        open.push(form_ask("a15"));
        input.sync(&open, Some("s1"));
        let _ = send_of(input.press(enter(), Some("s1"), false));
        assert!(!input.hidden.iter().any(|(ask_id, _)| ask_id == "b0"));
        assert!(input.hidden.iter().any(|(ask_id, _)| ask_id == "a15"));
        assert_eq!(input.hidden.len(), MAX_HIDDEN_ANSWERS);
    }

    #[test]
    fn a_new_answer_drops_a_settled_mark_before_a_pending_one() {
        let mut input = Input::new();
        // 15 pending marks.
        let mut open: Vec<Ask> = vec![];
        for n in 0..MAX_HIDDEN_ANSWERS - 1 {
            let ask = form_ask(&format!("a{n}"));
            open.push(ask);
            input.sync(&open, Some("s1"));
            let (send, _) = send_of(input.press(enter(), Some("s1"), false));
            input.settle_outcomes(&[(send, SendOutcome::Pending)]);
        }
        // One settled mark.
        open.push(form_ask("a15"));
        input.sync(&open, Some("s1"));
        let (send, _) = send_of(input.press(enter(), Some("s1"), false));
        input.settle_outcomes(&[(send, SendOutcome::Ok)]);
        // The new answer drops the settled mark, not a pending one.
        open.push(form_ask("a16"));
        input.sync(&open, Some("s1"));
        let _ = send_of(input.press(enter(), Some("s1"), false));
        assert!(!input.hidden.iter().any(|(ask_id, _)| ask_id == "a15"));
        assert!(input.hidden.iter().any(|(ask_id, _)| ask_id == "a16"));
        assert_eq!(input.hidden.len(), MAX_HIDDEN_ANSWERS);
        assert_eq!(
            input
                .hidden
                .iter()
                .filter(|(_, mark)| mark.outcome.is_none())
                .count(),
            MAX_HIDDEN_ANSWERS
        );
    }

    #[test]
    fn a_send_that_the_channel_refuses_settles_as_failed() {
        let mut input = Input::new();
        input.press(typed("hello"), Some("s1"), false);
        let (send, _) = send_of(input.press(enter(), Some("s1"), false));
        // A channel whose receiver is dropped refuses the send, as the
        // stopped network thread's channel does.
        let (commands, receive) = std::sync::mpsc::channel::<()>();
        drop(receive);
        assert!(input.settle_refused(Some(send), commands.send(())));
        assert!(input.composer_send.is_none());
        assert_eq!(input.composer.text.text(), "hello");
        assert_eq!(input.notice.as_deref(), Some(CONNECTION_STOPPED));
    }

    #[test]
    fn an_answer_that_the_channel_refuses_shows_the_ask_again() {
        let ask = form_ask("a1");
        let mut input = Input::new();
        input.sync(std::slice::from_ref(&ask), Some("s1"));
        let (send, _) = send_of(input.press(enter(), Some("s1"), false));
        let (commands, receive) = std::sync::mpsc::channel::<()>();
        drop(receive);
        assert!(input.settle_refused(Some(send), commands.send(())));
        input.sync(std::slice::from_ref(&ask), Some("s1"));
        assert_eq!(
            input.ask.as_ref().map(|panel| panel.ask_id.as_str()),
            Some("a1")
        );
        assert_eq!(input.notice.as_deref(), Some(CONNECTION_STOPPED));
    }

    #[test]
    fn a_command_with_no_send_that_the_channel_refuses_sets_the_notice() {
        let mut input = Input::new();
        assert!(input.settle_refused(None, Err::<(), &str>("closed")));
        assert_eq!(input.notice.as_deref(), Some(CONNECTION_STOPPED));
        assert!(!input.settle_refused(None, Ok::<(), &str>(())));
    }

    #[test]
    fn the_model_field_sends_the_ref_and_keeps_a_ref_that_is_not_one() {
        let mut input = Input::new();
        input.focus = Focus::Model;
        input.press(typed("openai/gpt-5.1"), Some("s1"), false);
        assert_eq!(
            input.press(enter(), Some("s1"), false),
            Intent::Send {
                send: None,
                operation: Operation::set_model("s1", "openai/gpt-5.1").unwrap(),
            }
        );
        assert_eq!(input.notice, None);
        // A ref that the core refuses keeps the field, and nothing goes.
        input.model.set("nope");
        assert_eq!(input.press(enter(), Some("s1"), false), Intent::None);
        assert_eq!(
            input.notice.as_deref(),
            Some("not sent: not a model ref: use provider/model")
        );
        assert_eq!(input.model.text(), "nope");
        // Escape leaves the field to the composer.
        assert_eq!(
            input.press(press("escape", None), Some("s1"), false),
            Intent::None
        );
        assert_eq!(input.focus, Focus::Composer);
    }

    #[test]
    fn compact_sends_the_composer_text_and_ok_empties_it() {
        let mut input = Input::new();
        input.press(typed("summarize"), Some("s1"), false);
        let (send, operation) = send_of(input.compact(Some("s1")));
        assert_eq!(operation, Operation::compact("s1", "summarize").unwrap());
        // `ok` empties the composer, as a send does.
        input.settle_outcomes(&[(send, SendOutcome::Ok)]);
        assert_eq!(input.composer.text.text(), "");
        // An empty composer compacts with no instructions.
        let (send, operation) = send_of(input.compact(Some("s1")));
        assert_eq!(operation, Operation::compact("s1", "").unwrap());
        input.settle_outcomes(&[(send, SendOutcome::Failed("busy: x".into()))]);
        // A text over the bound is not sent and stays.
        input.composer.text.insert(&"a".repeat(MAX_TEXT_BYTES + 1));
        assert_eq!(input.compact(Some("s1")), Intent::None);
        assert_eq!(input.notice.as_deref(), Some(TEXT_TOO_LARGE));
        // No session: nothing goes.
        assert_eq!(input.compact(None), Intent::None);
        assert_eq!(input.notice.as_deref(), Some(NO_SESSION));
    }

    #[test]
    fn the_cwd_field_starts_a_session_and_escape_leaves_it() {
        let mut input = Input::new();
        input.focus = Focus::Cwd;
        input.press(typed("/r"), Some("s1"), false);
        assert_eq!(
            input.press(enter(), Some("s1"), false),
            Intent::Send {
                send: None,
                operation: Operation::start("/r", None).unwrap(),
            }
        );
        assert_eq!(
            input.press(press("escape", None), Some("s1"), false),
            Intent::None
        );
        assert_eq!(input.focus, Focus::Composer);
    }

    #[test]
    fn the_cwd_field_takes_no_more_than_its_bound() {
        let mut input = Input::new();
        input.focus = Focus::Cwd;
        input.paste(&"a".repeat(MAX_CWD_BYTES + 100));
        assert_eq!(input.cwd.text().len(), MAX_CWD_BYTES);
        input.press(typed("b"), Some("s1"), false);
        assert_eq!(input.cwd.text().len(), MAX_CWD_BYTES);
    }

    #[test]
    fn a_paste_goes_to_the_focused_field() {
        let mut input = Input::new();
        let paste = Press {
            key: "v",
            shift: false,
            alt: false,
            platform: true,
            control: false,
            text: None,
        };
        assert_eq!(input.press(paste, Some("s1"), false), Intent::Paste);
        input.paste("a\r\nb\u{7}");
        assert_eq!(input.composer.text.text(), "a\nb");
        input.focus = Focus::Cwd;
        input.paste("/r\n/x");
        assert_eq!(input.cwd.text(), "/r/x");
        assert_eq!(input.copy(), "/r/x");
    }
}
