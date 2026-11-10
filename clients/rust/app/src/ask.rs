//! The ask of a kind that the window answers (`docs/features/ui-blocks.md`):
//! `form` and `approval`. The window shows the oldest open ask of a kind that
//! it can read, takes every key while it is open, and sends the answer with
//! the `answer` operation. An ask of another kind, or one whose fields the
//! core cannot read, keeps its fallback text and stays open for another
//! client (ADR 0011 §4).
//!
//! The form follows the picker of the TUI (`Helyx.TUI.Question`): one
//! question at a time, a cursor over its options and its Other line, an
//! answer that goes on only while every later question can still be
//! answered, and an Other line bound to the answer bound.
//!
//! This module holds no GPUI: it is compiled and tested on every platform.

use crate::composer::Text;
use helyx_client_core::json::Json;
use helyx_client_core::message::Ask;
use helyx_client_core::operation::{
    FormAnswer, MAX_ANSWER_BYTES, approval_answer, form_answer, form_answer_item,
};
use helyx_client_core::vocabulary::{Approval, Form, Question, UiBlock, View};

/// The line of a form that cannot take the answer of a question, as the TUI
/// writes it.
pub const TOO_LARGE: &str = "not sent: the answers are over 16 KiB";

/// One key of the window, as the form reads it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Key<'a> {
    Up,
    Down,
    /// Space marks the option under the cursor; on the Other line it types a
    /// space.
    Space,
    /// Enter takes the answer of the question and moves on, or sends the
    /// answer at the last question.
    Enter,
    /// The text of the Other line.
    Text(&'a str),
    Backspace,
}

/// What a key of the form gives.
#[derive(Debug, Clone, PartialEq)]
pub enum Outcome {
    /// The form stays open.
    None,
    /// The answer of the ask.
    Answer(Json),
    /// An answer does not fit any more: the form stays open with `error`.
    TooLarge,
}

/// The ask that the window answers.
#[derive(Debug, Clone, PartialEq)]
pub struct Panel {
    pub ask_id: String,
    pub block: UiBlock,
    pub kind: Kind,
}

#[derive(Debug, Clone, PartialEq)]
pub enum Kind {
    Form(FormState),
    /// An approval, with the fields that the window draws: Allow sends
    /// `{"decision": "allow"}`, and Deny sends `{"decision": "deny"}`.
    Approval(Approval),
}

/// The state of a form: the answers of the questions before the current one,
/// the question that the keys act on, and the cursor over its options and its
/// Other line. It follows the state of the TUI picker.
#[derive(Debug, Clone, PartialEq)]
pub struct FormState {
    pub questions: Vec<Question>,
    /// The answers of the questions before `current`, in order.
    answers: Vec<FormAnswer>,
    /// The labels marked for a multiple pick of the current question.
    marks: Vec<String>,
    pub current: usize,
    /// The option under the cursor, or the option count for the Other line.
    pub option: usize,
    /// The text of the Other line of the current question, within the bound
    /// of an answer.
    other: Text,
    /// Why the last Enter did not send.
    pub error: Option<String>,
}

impl Panel {
    /// The ask that the window answers, when the open asks changed: the
    /// oldest ask of a kind that it can read, without the asks in `skip`,
    /// whose answers are on the way or answered. The panel keeps its state
    /// while that ask stays open.
    pub fn settle(current: Option<Panel>, asks: &[Ask], skip: &[&str]) -> Option<Panel> {
        let next = (asks.iter())
            .filter(|ask| !skip.contains(&ask.ask_id.as_str()))
            .find_map(Panel::read);
        match (current, next) {
            (Some(panel), Some((ask_id, ..))) if panel.ask_id == ask_id => Some(panel),
            (_, next) => next.map(|(ask_id, block, kind)| Panel {
                ask_id,
                block,
                kind,
            }),
        }
    }

    fn read(ask: &Ask) -> Option<(String, UiBlock, Kind)> {
        let block = ask.block()?;
        let kind = match &block.view {
            View::Form(form) => Kind::Form(FormState::new(form)),
            View::Approval(approval) => Kind::Approval(approval.clone()),
            View::Text => return None,
        };
        Some((ask.ask_id.clone(), block, kind))
    }

    /// Whether the window can answer this ask: the oldest open ask of a
    /// kind that it reads is the one it shows.
    pub fn answers(ask: &Ask) -> bool {
        ask.block()
            .is_some_and(|block| !matches!(block.view, View::Text))
    }

    /// The id of the oldest open ask that the window answers.
    pub fn answering(asks: &[Ask]) -> Option<&str> {
        (asks.iter())
            .find(|ask| Panel::answers(ask))
            .map(|ask| ask.ask_id.as_str())
    }

    /// The line under the block of an ask: the one that takes the keys is
    /// answered below; one behind it waits; one that the window cannot read
    /// waits for another client. An ask with no kind is not drawn.
    pub fn note(ask: &Ask, answering: Option<&str>) -> Option<&'static str> {
        ask.block()?;
        match (Panel::answers(ask), answering == Some(ask.ask_id.as_str())) {
            (false, _) => Some("this app cannot answer this ask; another client can"),
            (true, true) => Some("answer it below"),
            (true, false) => Some("answer the earlier ask first"),
        }
    }

    /// The answer of an approval.
    pub fn approval(&self, allow: bool) -> Json {
        debug_assert!(matches!(self.kind, Kind::Approval(_)), "an approval panel");
        approval_answer(allow)
    }

    /// One key of the form.
    pub fn press(&mut self, key: Key<'_>) -> Outcome {
        let Kind::Form(form) = &mut self.kind else {
            return Outcome::None;
        };
        form.press(key)
    }

    /// A click on the option `option` of the question `question`: for a
    /// single pick it answers and moves on, and for a multiple pick it marks
    /// or unmarks.
    pub fn choose(&mut self, question: usize, option: usize) -> Outcome {
        let Kind::Form(form) = &mut self.kind else {
            return Outcome::None;
        };
        if form.current != question {
            return Outcome::None;
        }
        form.option = option.min(form.questions[form.current].options.len());
        match form.questions[form.current].multi_select {
            true => form.press(Key::Space),
            false => form.press(Key::Enter),
        }
    }

    /// The marks of `question`, by the index of its option: only the current
    /// question has marks, and only a multiple pick keeps them.
    pub fn marked(&self, question: usize) -> Vec<bool> {
        match &self.kind {
            Kind::Form(form) => {
                if question != form.current {
                    return vec![false; form.questions[question].options.len()];
                }
                (form.questions[question].options.iter())
                    .map(|option| form.marks.contains(&option.label))
                    .collect()
            }
            Kind::Approval(_) => vec![],
        }
    }

    /// The Other line of the current question, as it is typed and drawn.
    pub fn other(&self) -> Option<&Text> {
        match &self.kind {
            Kind::Form(form) => Some(&form.other),
            Kind::Approval(_) => None,
        }
    }

    /// Why the form did not send its answer, and that the answer operation
    /// was refused.
    pub fn error(&self) -> Option<&str> {
        match &self.kind {
            Kind::Form(form) => form.error.as_deref(),
            Kind::Approval(_) => None,
        }
    }

    /// Sets the line of the form, after the core refused its answer.
    pub fn fail(&mut self, text: &str) {
        if let Kind::Form(form) = &mut self.kind {
            form.error = Some(text.to_owned());
        }
    }
}

impl FormState {
    pub fn new(form: &Form) -> FormState {
        FormState {
            questions: form.questions.clone(),
            answers: vec![],
            marks: vec![],
            current: 0,
            option: 0,
            other: Text::bounded(MAX_ANSWER_BYTES),
            error: None,
        }
    }

    fn press(&mut self, key: Key<'_>) -> Outcome {
        match key {
            Key::Up => self.option = self.option.saturating_sub(1),
            Key::Down => {
                self.option = (self.option + 1).min(self.questions[self.current].options.len());
            }
            Key::Space => self.space(),
            Key::Text(text) => self.type_other(text),
            Key::Backspace => {
                self.other.backspace();
            }
            Key::Enter => return self.enter(),
        }
        Outcome::None
    }

    /// Space marks or unmarks the option under the cursor, and types a space
    /// on the Other line.
    fn space(&mut self) {
        let question = &self.questions[self.current];
        let Some(option) = question.options.get(self.option) else {
            self.type_other(" ");
            return;
        };
        // Space marks only a multiple pick, as in the TUI: a single pick is
        // the option under the cursor at Enter.
        if !question.multi_select {
            return;
        }
        let label = option.label.clone();
        match self.marks.iter().position(|l| *l == label) {
            Some(at) => {
                self.marks.remove(at);
            }
            None => self.marks.push(label),
        }
    }

    /// A typed text goes to the Other line, which takes the cursor.
    fn type_other(&mut self, text: &str) {
        self.other.insert(text);
        self.option = self.questions[self.current].options.len();
    }

    fn enter(&mut self) -> Outcome {
        let Some(answer) = self.current_answer() else {
            return Outcome::None;
        };
        let mut answers = self.answers.clone();
        answers.push(answer);
        // An answer goes on only while the answers so far and the longest
        // option of each later question fit, so each later question can still
        // be answered; else the question stays, as in the TUI.
        let later = self.questions[self.current + 1..].len();
        if !fits(&self.questions, &answers, later) {
            self.error = Some(TOO_LARGE.into());
            return Outcome::TooLarge;
        }
        self.error = None;
        if self.current + 1 < self.questions.len() {
            self.answers = answers;
            self.current += 1;
            self.option = 0;
            self.marks.clear();
            self.other.clear();
            return Outcome::None;
        }
        Outcome::Answer(form_answer(&answers))
    }

    /// The labels marked for the current question, in the order of its
    /// options, whichever order the user marked them.
    fn marked_labels(&self) -> Vec<String> {
        let question = &self.questions[self.current];
        (question.options.iter())
            .filter(|option| self.marks.contains(&option.label))
            .map(|option| option.label.clone())
            .collect()
    }

    /// The answer of the current question at the cursor, or none when the
    /// cursor is on an empty Other line. On a multiple pick, Enter takes the
    /// marks, or the option under the cursor when none is marked.
    fn current_answer(&self) -> Option<FormAnswer> {
        let question = &self.questions[self.current];
        let other = self.other.text();
        if self.option == question.options.len() {
            if other.is_empty() {
                return None;
            }
            let selected = match question.multi_select {
                true => self.marked_labels(),
                false => vec![],
            };
            Some(FormAnswer {
                selected,
                other: Some(other.to_owned()),
            })
        } else if question.multi_select && !self.marks.is_empty() {
            Some(FormAnswer {
                selected: self.marked_labels(),
                other: None,
            })
        } else {
            Some(FormAnswer {
                selected: vec![question.options[self.option].label.clone()],
                other: None,
            })
        }
    }
}

/// The rule of the TUI: the answers so far, and the longest option of each of
/// the `later` questions after them plus its comma, fit the bound of an
/// answer.
fn fits(questions: &[Question], answers: &[FormAnswer], later: usize) -> bool {
    let so_far = form_answer(answers).encode().len();
    let room: usize = (questions.iter().rev())
        .take(later)
        .map(|question| longest(question) + 1)
        .sum();
    so_far + room <= MAX_ANSWER_BYTES
}

/// The bytes of the longest single-option answer of `question`.
fn longest(question: &Question) -> usize {
    (question.options.iter())
        .map(|option| {
            form_answer_item(&FormAnswer {
                selected: vec![option.label.clone()],
                other: None,
            })
            .encode()
            .len()
        })
        .max()
        .unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::{Key, Kind, Outcome, Panel, TOO_LARGE};
    use helyx_client_core::json::{Json, decode};
    use helyx_client_core::message::Ask;
    use helyx_client_core::operation::{
        FormAnswer, MAX_ANSWER_BYTES, approval_answer, form_answer,
    };
    use helyx_client_core::vocabulary::{Choice, Form, Question, UiBlock, View};

    fn question(header: &str, multi: bool) -> Question {
        Question {
            question: format!("{header}?"),
            header: header.into(),
            options: vec![
                Choice {
                    label: "Yes".into(),
                    description: "take it".into(),
                },
                Choice {
                    label: "No".into(),
                    description: "leave it".into(),
                },
                Choice {
                    label: "Other".into(),
                    description: "say it".into(),
                },
            ],
            multi_select: multi,
        }
    }

    fn panel(questions: Vec<Question>) -> Panel {
        let form = Form { questions };
        let block = UiBlock {
            kind: "form".into(),
            text: "a form".into(),
            cut: false,
            view: View::Form(form.clone()),
        };
        Panel {
            ask_id: "a1".into(),
            block,
            kind: Kind::Form(super::FormState::new(&form)),
        }
    }

    fn answers(answer: &Json) -> &Json {
        answer.get("answers").unwrap()
    }

    fn current(panel: &Panel) -> usize {
        match &panel.kind {
            Kind::Form(form) => form.current,
            Kind::Approval(_) => 0,
        }
    }

    fn ask(request: &str) -> Ask {
        Ask {
            ask_id: "a1".into(),
            call_id: "c1".into(),
            tool: "t".into(),
            request: decode(request).unwrap(),
        }
    }

    fn form_ask(ask_id: &str) -> Ask {
        Ask {
            ask_id: ask_id.into(),
            ..ask(
                r#"{"kind":"form","text":"1 question","questions":[{"question":"q","header":"h","options":[{"label":"a","description":""},{"label":"b","description":""}],"multi_select":false}]}"#,
            )
        }
    }

    #[test]
    fn a_single_pick_answers_each_question_in_order() {
        let mut panel = panel(vec![question("one", false), question("two", false)]);
        assert_eq!(panel.press(Key::Enter), Outcome::None);
        assert_eq!(panel.press(Key::Down), Outcome::None);
        assert_eq!(panel.press(Key::Down), Outcome::None);
        let Outcome::Answer(json) = panel.press(Key::Enter) else {
            panic!("the last question sends the answer");
        };
        assert_eq!(
            answers(&json),
            &decode(r#"[{"selected":["Yes"]},{"selected":["Other"]}]"#).unwrap()
        );
        assert_eq!(panel.other().unwrap().text(), "");
    }

    #[test]
    fn a_multiple_pick_marks_the_options_and_enter_takes_the_marks() {
        let mut panel = panel(vec![question("one", true)]);
        assert_eq!(panel.press(Key::Space), Outcome::None);
        assert_eq!(panel.press(Key::Down), Outcome::None);
        assert_eq!(panel.press(Key::Space), Outcome::None);
        assert_eq!(panel.marked(0), [true, true, false]);
        // The cursor is on `No`, which is marked: Enter takes the marks, and
        // does not add the option under the cursor again.
        let Outcome::Answer(json) = panel.press(Key::Enter) else {
            panic!("the last question sends the answer");
        };
        assert_eq!(
            answers(&json),
            &decode(r#"[{"selected":["Yes","No"]}]"#).unwrap()
        );
        // On an option that is not marked, with marks elsewhere, Enter keeps
        // the marks and does not add the option under the cursor.
        let mut panel = super::tests::panel(vec![question("one", true)]);
        panel.press(Key::Space);
        panel.press(Key::Down);
        panel.press(Key::Down);
        let Outcome::Answer(json) = panel.press(Key::Enter) else {
            panic!("the last question sends the answer");
        };
        assert_eq!(
            answers(&json),
            &decode(r#"[{"selected":["Yes"]}]"#).unwrap()
        );
        // With no mark, Enter takes the option under the cursor.
        let mut panel = super::tests::panel(vec![question("one", true)]);
        panel.press(Key::Down);
        let Outcome::Answer(json) = panel.press(Key::Enter) else {
            panic!("the last question sends the answer");
        };
        assert_eq!(answers(&json), &decode(r#"[{"selected":["No"]}]"#).unwrap());
    }

    #[test]
    fn a_second_space_unmarks() {
        let mut panel = panel(vec![question("one", true)]);
        panel.press(Key::Space);
        panel.press(Key::Space);
        assert_eq!(panel.marked(0), [false, false, false]);
    }

    #[test]
    fn the_other_line_is_the_answer_of_a_single_pick() {
        let mut panel = panel(vec![question("one", false)]);
        panel.press(Key::Text("it is"));
        panel.press(Key::Text(" fine"));
        assert_eq!(panel.other().unwrap().text(), "it is fine");
        panel.press(Key::Backspace);
        let Outcome::Answer(json) = panel.press(Key::Enter) else {
            panic!("the last question sends the answer");
        };
        assert_eq!(
            answers(&json),
            &decode(r#"[{"other":"it is fin"}]"#).unwrap()
        );
    }

    #[test]
    fn space_marks_a_multiple_pick_and_types_on_the_other_line() {
        let mut panel = panel(vec![question("one", true)]);
        // The cursor starts on an option of a multiple pick: Space marks it.
        panel.press(Key::Space);
        assert_eq!(panel.marked(0), [true, false, false]);
        // A typed character moves the cursor to the Other line, where Space
        // is a space.
        panel.press(Key::Text("x"));
        panel.press(Key::Space);
        assert_eq!(panel.other().unwrap().text(), "x ");
        assert_eq!(panel.marked(0), [true, false, false]);
    }

    #[test]
    fn space_on_a_single_pick_does_nothing() {
        let mut panel = panel(vec![question("one", false)]);
        panel.press(Key::Space);
        assert_eq!(panel.marked(0), [false, false, false]);
        // Enter answers the option under the cursor, which Space did not
        // change.
        let Outcome::Answer(json) = panel.press(Key::Enter) else {
            panic!("the last question sends the answer");
        };
        assert_eq!(
            answers(&json),
            &decode(r#"[{"selected":["Yes"]}]"#).unwrap()
        );
    }

    #[test]
    fn the_marks_of_a_multiple_pick_go_out_in_option_order() {
        let mut panel = panel(vec![question("one", true)]);
        // Mark `No`, then `Yes`, in that order.
        panel.press(Key::Down);
        panel.press(Key::Space);
        panel.press(Key::Up);
        panel.press(Key::Space);
        let Outcome::Answer(json) = panel.press(Key::Enter) else {
            panic!("the last question sends the answer");
        };
        assert_eq!(
            answers(&json),
            &decode(r#"[{"selected":["Yes","No"]}]"#).unwrap()
        );
    }

    #[test]
    fn the_marks_belong_to_the_question_that_has_them() {
        let mut panel = panel(vec![question("one", true), question("two", true)]);
        panel.press(Key::Space);
        panel.press(Key::Down);
        assert_eq!(panel.marked(0), [true, false, false]);
        // The next question has no marks of the first.
        assert_eq!(panel.marked(1), [false, false, false]);
    }

    #[test]
    fn the_other_line_keeps_the_marks_of_a_multiple_pick() {
        let mut panel = panel(vec![question("one", true)]);
        panel.press(Key::Space);
        panel.press(Key::Text("also"));
        let Outcome::Answer(json) = panel.press(Key::Enter) else {
            panic!("the last question sends the answer");
        };
        assert_eq!(
            answers(&json),
            &decode(r#"[{"selected":["Yes"],"other":"also"}]"#).unwrap()
        );
    }

    #[test]
    fn an_empty_other_line_does_not_answer() {
        let mut panel = panel(vec![question("one", false)]);
        // Up at the first option keeps the cursor there; move to the Other
        // line with a typed text and erase it.
        panel.press(Key::Text("x"));
        panel.press(Key::Backspace);
        assert_eq!(panel.press(Key::Enter), Outcome::None);
    }

    #[test]
    fn a_click_answers_a_single_pick_and_marks_a_multiple_one() {
        let mut panel = panel(vec![question("one", false), question("two", false)]);
        let Outcome::None = panel.choose(0, 2) else {
            panic!("the first question moves on");
        };
        // The keys are on the second question, which has no mark yet.
        assert_eq!(panel.marked(0), [false, false, false]);
        let Outcome::Answer(json) = panel.choose(1, 1) else {
            panic!("the last question sends the answer");
        };
        assert_eq!(
            answers(&json),
            &decode(r#"[{"selected":["Other"]},{"selected":["No"]}]"#).unwrap()
        );
        let mut panel = super::tests::panel(vec![question("one", true)]);
        panel.choose(0, 1);
        assert_eq!(panel.marked(0), [false, true, false]);
        let Outcome::None = panel.choose(0, 1) else {
            panic!("a mark does not send the last question before Enter");
        };
        assert_eq!(panel.marked(0), [false, false, false]);
    }

    #[test]
    fn an_answer_that_leaves_no_room_for_a_later_question_stays() {
        let mut panel = panel(vec![question("one", false), question("two", false)]);
        // The answer of the first question, and the longest option of the
        // second with its comma, pass the bound: the question stays.
        let big = "x".repeat(16_380);
        panel.press(Key::Text(&big));
        assert_eq!(panel.press(Key::Enter), Outcome::TooLarge);
        assert_eq!(panel.error(), Some(TOO_LARGE));
        assert_eq!(current(&panel), 0);
        // A smaller answer goes on.
        let mut panel = super::tests::panel(vec![question("one", false), question("two", false)]);
        panel.press(Key::Text("small"));
        let Outcome::None = panel.press(Key::Enter) else {
            panic!("the first question moves on");
        };
        assert_eq!(current(&panel), 1);
    }

    #[test]
    fn an_answer_over_the_bound_stays_with_a_line() {
        let mut panel = panel(vec![question("one", false), question("two", false)]);
        let first = "x".repeat(9_000);
        let second = "y".repeat(9_000);
        panel.press(Key::Text(&first));
        assert_eq!(panel.press(Key::Enter), Outcome::None);
        panel.press(Key::Text(&second));
        assert_eq!(panel.press(Key::Enter), Outcome::TooLarge);
        assert_eq!(panel.error(), Some(TOO_LARGE));
        // The panel stays on the last question, with its text, so the user can
        // cut it and send again.
        assert_eq!(panel.other().unwrap().text().len(), second.len());
    }

    #[test]
    fn the_other_line_is_bounded() {
        let mut panel = panel(vec![question("one", false)]);
        // A multibyte text is cut at the bound, at a character boundary.
        panel.press(Key::Text(&"é".repeat(9_000)));
        assert_eq!(panel.other().unwrap().text().len(), MAX_ANSWER_BYTES);
        assert_eq!(panel.other().unwrap().text(), "é".repeat(8_192));
    }

    #[test]
    fn the_note_of_an_ask() {
        let a = form_ask("a1");
        let b = form_ask("a2");
        assert_eq!(Panel::answering(&[b.clone(), a.clone()]), Some("a2"));
        assert_eq!(
            Panel::note(&a, Panel::answering(&[a.clone(), b.clone()])),
            Some("answer it below")
        );
        assert_eq!(
            Panel::note(&b, Panel::answering(&[a, b.clone()])),
            Some("answer the earlier ask first")
        );
        let diff = ask(r#"{"kind":"diff","text":"x"}"#);
        assert_eq!(
            Panel::note(&diff, None),
            Some("this app cannot answer this ask; another client can")
        );
        let no_kind = ask(r#"{"questions":[]}"#);
        assert_eq!(Panel::note(&no_kind, None), None);
    }

    #[test]
    fn only_an_ask_of_a_form_or_an_approval_is_read() {
        let approval =
            ask(r#"{"kind":"approval","text":"allow bash?","tool":"bash","arguments":"{}"}"#);
        let mut panel = Panel::settle(None, std::slice::from_ref(&approval), &[]).unwrap();
        assert_eq!(panel.approval(true), approval_answer(true));
        assert_eq!(panel.approval(false), approval_answer(false));
        assert_eq!(panel.press(Key::Enter), Outcome::None);
        let form = form_ask("a1");
        assert!(Panel::settle(None, std::slice::from_ref(&form), &[]).is_some());
        // A kind that the window does not answer, and a request with no kind,
        // keep their text and stay open for another client.
        assert!(Panel::settle(None, &[ask(r#"{"kind":"diff","text":"x"}"#)], &[]).is_none());
        assert!(Panel::settle(None, &[ask(r#"{"questions":[]}"#)], &[]).is_none());
        // The state of an ask stays while that ask is open.
        let mut open = Panel::settle(None, std::slice::from_ref(&form), &[]).unwrap();
        open.press(Key::Space);
        let again = Panel::settle(Some(open.clone()), std::slice::from_ref(&form), &[]);
        assert_eq!(again, Some(open.clone()));
        // Another ask starts anew, with no state of the first.
        let fresh = Panel::settle(Some(open), &[form_ask("a2")], &[]).unwrap();
        assert_eq!(fresh.ask_id, "a2");
        assert_eq!(fresh.marked(0), [false, false]);
        // A skipped ask does not open: its answer is on the way.
        assert!(Panel::settle(None, &[form], &["a1"]).is_none());
    }

    #[test]
    fn a_form_answer_is_the_shape_of_the_vocabulary() {
        let one = question("one", false);
        let mut panel = panel(vec![one.clone()]);
        panel.press(Key::Space);
        let Outcome::Answer(json) = panel.press(Key::Enter) else {
            panic!("the last question sends the answer");
        };
        let selected = form_answer(&[FormAnswer {
            selected: vec!["Yes".into()],
            other: None,
        }]);
        assert_eq!(json, selected);
    }
}
