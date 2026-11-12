//! The drawing of a `diff` UI block (`docs/features/ui-blocks.md`, "Rendering
//! in the client kit"): the path with its counts, each hunk's header, and the
//! lines with a gutter of old and new line numbers. The model is
//! `vocabulary::Diff`, and this file draws it.

use gpui::{Div, FontWeight, div, prelude::*, rgb};
use helyx_client_core::ui_block::MAX_BYTES;
use helyx_client_core::vocabulary::{Diff, DiffLine, Hunk, LineKind, MAX_TITLE_BYTES, head};

use super::{DIM, FAILED, OK};

/// The bytes of one drawn line: the server cuts a line of a block at 1,000
/// bytes (`Helyx.Diff.line_bytes/0`), so this never cuts a line that the
/// server makes, and it bounds a line of a block that the client did not
/// check for size.
const MAX_LINE_BYTES: usize = 1_024;

/// A `diff`: the path and the counts, then the lines of its hunks in a
/// monospace box. A diff with no hunk draws its `text` in the place of the
/// lines. A diff over `SHOWN_DIFF_LINES` draws its first lines and one line
/// with the count of the rest.
pub fn body(diff: &Diff, text: &str) -> Div {
    let body = div().flex().flex_col().gap_1().child(header(diff));
    let (hunks, more) = diff.shown();
    if hunks.is_empty() {
        let (text, _) = head(text, MAX_BYTES);
        return body.child(boxed().child(dim(text)));
    }
    let width = gutter_width(&hunks);
    let mut lines = boxed();
    for (hunk, shown) in hunks {
        lines = lines
            .child(dim(&format!(
                "@@ -{},{} +{},{} @@",
                hunk.old_start, hunk.old_lines, hunk.new_start, hunk.new_lines
            )))
            .children(shown.iter().map(|line| line_row(line, width)));
    }
    if more > 0 {
        lines = lines.child(dim(&format!("… {more} more lines")));
    }
    body.child(lines)
}

fn header(diff: &Diff) -> Div {
    let (path, more) = head(&diff.path, MAX_TITLE_BYTES);
    let path = if more {
        format!("{path}…")
    } else {
        path.to_owned()
    };
    div()
        .flex()
        .gap_2()
        .child(div().font_weight(FontWeight::BOLD).child(path))
        .child(div().text_color(rgb(OK)).child(format!("+{}", diff.added)))
        .child(
            div()
                .text_color(rgb(FAILED))
                .child(format!("−{}", diff.removed)),
        )
}

fn boxed() -> Div {
    div().flex().flex_col().p_1().bg(rgb(0x26262e))
}

/// The gutter of the widest line number that the diff draws: each number is
/// right-aligned in it, so the columns of the lines line up.
fn gutter_width(hunks: &[(&Hunk, &[DiffLine])]) -> usize {
    hunks
        .iter()
        .flat_map(|(_, lines)| lines.iter())
        .flat_map(|line| [line.old, line.new])
        .flatten()
        .map(|number| number.to_string().len())
        .max()
        .unwrap_or(1)
}

fn line_row(line: &DiffLine, width: usize) -> Div {
    let (sign, color) = match line.kind {
        LineKind::Context => (" ", DIM),
        LineKind::Removed => ("-", FAILED),
        LineKind::Added => ("+", OK),
    };
    let number = |number: Option<u64>| number.map(|n| n.to_string()).unwrap_or_default();
    let (text, _) = head(&line.text, MAX_LINE_BYTES);
    div()
        .font_family("Menlo")
        .text_color(rgb(color))
        .child(format!(
            "{:>width$} {:>width$} {sign}{text}",
            number(line.old),
            number(line.new),
        ))
}

fn dim(text: &str) -> Div {
    div()
        .font_family("Menlo")
        .text_color(rgb(DIM))
        .child(text.to_owned())
}
