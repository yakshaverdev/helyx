//! The usage model of the client: the forms of the footer, the context
//! percent and its level, and the saturating sums
//! (`docs/features/usage-and-limits.md`, "The footer").

mod common;
use common::j;
use helyx_client_core::message::Message;
use helyx_client_core::usage::{
    BAD_PERCENT, Context, Level, Totals, WARN_PERCENT, context_percent, cost_text, level,
    tokens_text,
};
use serde_json::json;

fn totals(cost: Option<f64>, unknown: bool, list: bool) -> Totals {
    Totals {
        cost,
        unknown,
        list,
        ..Totals::default()
    }
}

fn context(tokens: u64, window: u64, model: &str) -> Context {
    Context {
        tokens: Some(tokens),
        window: Some(window),
        model: Some(model.to_owned()),
        bytes: 0,
    }
}

#[test]
fn a_token_count_keeps_a_capped_form() {
    assert_eq!(tokens_text(999), "999");
    assert_eq!(tokens_text(1_000), "1.0k");
    assert_eq!(tokens_text(999_999), "999.9k");
    assert_eq!(tokens_text(1_000_000), "1.0M");
    assert_eq!(tokens_text(1_000_000_000), "1.0B");
    assert_eq!(tokens_text(999_999_999_999), "999.9B");
    assert_eq!(tokens_text(1_000_000_000_000), ">999B");
    assert_eq!(tokens_text(u64::MAX), ">999B");
}

#[test]
fn a_cost_shows_the_known_sum_and_its_marks() {
    assert_eq!(
        cost_text(&totals(Some(1.23), false, false)).as_deref(),
        Some("$1.23")
    );
    assert_eq!(
        cost_text(&totals(Some(1.23), true, false)).as_deref(),
        Some("≥$1.23")
    );
    assert_eq!(
        cost_text(&totals(Some(1.23), false, true)).as_deref(),
        Some("$1.23 list")
    );
    // Only unknown costs.
    assert_eq!(cost_text(&totals(None, true, false)).as_deref(), Some("$?"));
    // No usage at all.
    assert_eq!(cost_text(&totals(None, false, false)), None);
    // A cost under $0.01 shows four decimals.
    assert_eq!(
        cost_text(&totals(Some(0.0042), false, false)).as_deref(),
        Some("$0.0042")
    );
    // The top form.
    assert_eq!(
        cost_text(&totals(Some(100_000.0), false, false)).as_deref(),
        Some(">$99999")
    );
}

#[test]
fn the_context_percent_needs_the_model_and_both_counts() {
    let model = "fake/echo";
    assert_eq!(
        context_percent(&context(WARN_PERCENT, 100, model), model),
        Some(WARN_PERCENT)
    );
    assert_eq!(
        context_percent(&context(WARN_PERCENT + 1, 100, model), model),
        Some(WARN_PERCENT + 1)
    );
    assert_eq!(
        context_percent(&context(BAD_PERCENT, 100, model), model),
        Some(BAD_PERCENT)
    );
    assert_eq!(
        context_percent(&context(BAD_PERCENT + 1, 100, model), model),
        Some(BAD_PERCENT + 1)
    );
    // Over 999% keeps the exact percent; the display caps it.
    assert_eq!(
        context_percent(&context(1_000, 100, model), model),
        Some(1_000)
    );
    // A model that differs has no percent.
    assert_eq!(
        context_percent(&context(50, 100, "other/model"), model),
        None
    );
    // Both counts are needed.
    let no_tokens = Context {
        tokens: None,
        ..context(50, 100, model)
    };
    assert_eq!(context_percent(&no_tokens, model), None);
    let no_window = Context {
        window: None,
        ..context(50, 100, model)
    };
    assert_eq!(context_percent(&no_window, model), None);
}

#[test]
fn a_context_percent_has_a_level_at_each_bound() {
    assert_eq!(level(WARN_PERCENT), Level::Normal);
    assert_eq!(level(WARN_PERCENT + 1), Level::Warn);
    assert_eq!(level(BAD_PERCENT), Level::Warn);
    assert_eq!(level(BAD_PERCENT + 1), Level::Bad);
}

#[test]
fn a_sum_past_the_largest_u64_saturates() {
    let message = Message::parse(&j(&json!({
        "id": "a1", "role": "assistant", "content": [],
        "usage": {"input": u64::MAX, "output": u64::MAX,
                  "cache_read": u64::MAX, "cache_write": u64::MAX}
    })))
    .unwrap();
    let mut totals = Totals::default();
    totals.add(&message);
    totals.add(&message);
    assert_eq!(totals.input, u64::MAX);
    assert_eq!(totals.output, u64::MAX);
    assert_eq!(totals.cache_read, u64::MAX);
    assert_eq!(totals.cache_write, u64::MAX);
    // The usage has no cost, so the sum marks the cost as unknown.
    assert!(totals.unknown);
    assert_eq!(totals.cost, None);
}
