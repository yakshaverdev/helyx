//! The block and answer surface of the bindings (`docs/features/ios-app.md`,
//! "What the Swift views need"): a block read into an owned view, the answers
//! of a `form` and an `approval`, and the open ask of a session. Each rule is
//! the rule of `helyx_client_core`, so the host parses no JSON and builds no
//! answer itself.

use crate::types::{Ask, BlockView, FormAnswerItem, FormOption, FormQuestion};
use helyx_client_core::operation::{self, FormAnswer};
use helyx_client_core::ui_block;
use helyx_client_core::vocabulary::{self, View};

/// Reads the JSON text of a UI block into the view that a host draws: the
/// view of `vocabulary::UiBlock::read`, with the fields of the core.
///
/// It never fails. A text that is not a block gives a `Text` view with an
/// empty kind and the text itself, cut to `ui_block::MAX_BYTES` at a character
/// boundary, so a text that no block bounds cannot fill the view.
#[uniffi::export]
pub fn read_block(json: String) -> BlockView {
    let block = helyx_client_core::json::decode(&json)
        .ok()
        .and_then(|value| vocabulary::UiBlock::read(&value).ok());
    match block {
        Some(block) => match block.view {
            View::Form(form) => BlockView::Form {
                text: cut(block.text),
                questions: form.questions.into_iter().map(question).collect(),
            },
            View::Approval(approval) => BlockView::Approval {
                text: cut(block.text),
                tool: approval.tool,
                provider: approval.provider,
                arguments: approval.arguments,
            },
            // The bindings have no diff view yet, so a `diff` shows its text,
            // the fallback of the kind (`docs/features/ui-blocks.md`).
            View::Text | View::Diff(_) => BlockView::Text {
                kind: block.kind,
                text: cut(block.text),
            },
        },
        None => BlockView::Text {
            kind: String::new(),
            text: cut(json),
        },
    }
}

/// The answer of a `form` as its JSON text, from one item for each question
/// in order: the builder of `core::operation`, which the desktop app uses.
#[uniffi::export]
pub fn form_answer(items: Vec<FormAnswerItem>) -> String {
    let items: Vec<FormAnswer> = items
        .into_iter()
        .map(|item| FormAnswer {
            selected: item.selected,
            other: item.other,
        })
        .collect();
    operation::form_answer(&items).encode()
}

/// The answer of an `approval` as its JSON text: allow or deny.
#[uniffi::export]
pub fn approval_answer(allow: bool) -> String {
    operation::approval_answer(allow).encode()
}

/// The id of the ask that the host answers now: the oldest open ask of a kind
/// that the host reads, `form` or `approval`.
///
/// The desktop app follows the same rule (`app/src/ask.rs`,
/// `Panel::answering`); a later ticket makes it call this function, so the two
/// hosts decide the open ask in one place.
pub fn answering(asks: &[Ask]) -> Option<String> {
    (asks.iter())
        .find(|ask| answers(ask))
        .map(|ask| ask.ask_id.clone())
}

/// Whether the host can answer `ask`: its request has a kind whose fields the
/// core reads.
fn answers(ask: &Ask) -> bool {
    matches!(
        read_block(ask.request.clone()),
        BlockView::Form { .. } | BlockView::Approval { .. }
    )
}

/// `text` cut to the bound of a block, at a character boundary.
fn cut(text: String) -> String {
    vocabulary::head(&text, ui_block::MAX_BYTES).0.to_owned()
}

fn question(question: vocabulary::Question) -> FormQuestion {
    FormQuestion {
        question: question.question,
        header: question.header,
        options: question
            .options
            .into_iter()
            .map(|option| FormOption {
                label: option.label,
                description: option.description,
            })
            .collect(),
        multi_select: question.multi_select,
    }
}
