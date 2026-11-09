//! The models of the UI block vocabulary (`docs/features/ui-blocks.md`, "The
//! vocabulary"), read from a block that `ui_block` checked: each kind that the
//! document defines, `form` and `approval`, and the fallback text for any
//! other kind, or for a known kind whose fields the client cannot read
//! (ADR 0011 §2). A read never fails on a field of a kind: the envelope is
//! the contract of the wire, the fields of a kind are not.

use crate::check::Checked;
use crate::json::Json;
use crate::message::Ask;
use crate::ui_block::envelope;

/// The bytes of the arguments of an approval that a client draws: the bound
/// of the gate's own request, as the TUI keeps (`Helyx.TUI.Approval`), so a
/// block of another emitter, up to the 65,536 bytes of an ask, draws no more.
pub const MAX_ARGUMENTS_BYTES: usize = 16_384;
/// The bytes of the title of an approval, its `text`, that a client draws on
/// one line, as the TUI does (`docs/features/approval-gate.md`).
pub const MAX_TITLE_BYTES: usize = 1_024;
/// The bytes of the `tool` and of the `provider` of an approval that a client
/// draws: the cut of the gate.
pub const MAX_NAME_BYTES: usize = 256;

/// A UI block as a client draws it.
#[derive(Debug, Clone, PartialEq)]
pub struct UiBlock {
    pub kind: String,
    /// The fallback text.
    pub text: String,
    /// The block was cut, by the server or by its emitter: a client draws a
    /// cut mark.
    pub cut: bool,
    pub view: View,
}

/// How a client draws a block: natively for a kind that it knows and whose
/// fields it can read, else as its text.
#[derive(Debug, Clone, PartialEq)]
pub enum View {
    Form(Form),
    Approval(Approval),
    /// A kind that the client does not know, or a known kind whose fields it
    /// cannot read: it shows `text`.
    Text,
}

/// `form`: an input block, the request of an ask.
#[derive(Debug, Clone, PartialEq)]
pub struct Form {
    /// 1 to 4 questions.
    pub questions: Vec<Question>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct Question {
    /// 1 to 1,000 bytes.
    pub question: String,
    /// 1 to 12 code points.
    pub header: String,
    /// 2 to 4 options, with labels unique in the question.
    pub options: Vec<Choice>,
    pub multi_select: bool,
}

#[derive(Debug, Clone, PartialEq)]
pub struct Choice {
    /// 1 to 60 bytes.
    pub label: String,
    /// At most 300 bytes.
    pub description: String,
}

/// `approval`: an input block, the request of an ask of the approval gate.
#[derive(Debug, Clone, PartialEq)]
pub struct Approval {
    /// The tool name of the call.
    pub tool: String,
    /// None for a Helyx tool call, else the provider whose own tool it is.
    pub provider: Option<String>,
    /// The JSON text of the arguments of the call.
    pub arguments: String,
}

impl UiBlock {
    /// The model of `value`. A value that fails the envelope is not a UI
    /// block: every block that the core holds passed it.
    pub fn read(value: &Json) -> Checked<UiBlock> {
        envelope(value)?;
        let kind = value.get("kind").and_then(Json::as_str).unwrap_or_default();
        let view = match kind {
            "form" => form(value).map(View::Form),
            "approval" => approval(value).map(View::Approval),
            _ => None,
        };
        Ok(UiBlock {
            kind: kind.to_owned(),
            text: (value.get("text").and_then(Json::as_str))
                .unwrap_or_default()
                .to_owned(),
            cut: value.get("cut").and_then(Json::as_bool) == Some(true),
            view: view.unwrap_or(View::Text),
        })
    }
}

impl Ask {
    /// The input block of the ask: its request when it has a `kind`. A
    /// request with no kind is an ask of a tool that is not on the
    /// vocabulary, which this client does not draw (ADR 0011 §4).
    pub fn block(&self) -> Option<UiBlock> {
        self.request.get("kind")?;
        UiBlock::read(&self.request).ok()
    }
}

/// The head of `text` that a client draws: at most `max` bytes, cut at a
/// character boundary, and whether a part is left out. A field of a block
/// from the wire can be as long as its frame (an ask request has no size
/// check in the client), so each drawn text has a bound.
pub fn head(text: &str, max: usize) -> (&str, bool) {
    let mut end = text.len().min(max);
    while !text.is_char_boundary(end) {
        end -= 1;
    }
    (&text[..end], end < text.len())
}

fn form(value: &Json) -> Option<Form> {
    let questions = value.get("questions")?.as_array()?;
    if !(1..=4).contains(&questions.len()) {
        return None;
    }
    let questions = questions.iter().map(question).collect::<Option<_>>()?;
    Some(Form { questions })
}

fn question(value: &Json) -> Option<Question> {
    let question = text(value, "question", 1, 1_000)?;
    let header = value.get("header")?.as_str()?;
    if !(1..=12).contains(&header.chars().count()) {
        return None;
    }
    // Absent is a single pick, as the TUI reads it; null is not a boolean.
    let multi_select = match value.get("multi_select") {
        None => false,
        Some(flag) => flag.as_bool()?,
    };
    let options = value.get("options")?.as_array()?;
    if !(2..=4).contains(&options.len()) {
        return None;
    }
    let options: Vec<Choice> = options.iter().map(choice).collect::<Option<_>>()?;
    let unique = (options.iter().enumerate())
        .all(|(at, a)| options[..at].iter().all(|b| b.label != a.label));
    unique.then(|| Question {
        question,
        header: header.to_owned(),
        options,
        multi_select,
    })
}

fn choice(value: &Json) -> Option<Choice> {
    Some(Choice {
        label: text(value, "label", 1, 60)?,
        description: text(value, "description", 0, 300)?,
    })
}

fn approval(value: &Json) -> Option<Approval> {
    let provider = match value.get("provider") {
        None | Some(Json::Null) => None,
        Some(provider) => Some(provider.as_str()?.to_owned()),
    };
    Some(Approval {
        tool: value.get("tool")?.as_str()?.to_owned(),
        provider,
        arguments: value.get("arguments")?.as_str()?.to_owned(),
    })
}

/// The string of `key`, of `min` to `max` bytes.
fn text(value: &Json, key: &str, min: usize, max: usize) -> Option<String> {
    let text = value.get(key)?.as_str()?;
    (min..=max).contains(&text.len()).then(|| text.to_owned())
}
