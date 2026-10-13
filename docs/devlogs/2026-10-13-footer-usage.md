# 2026-10-13: usage values in the footer (#558)

## Done

- `Helyx.TUI.SessionUsage` folds the session totals and the context estimate. `ViewModel.add_message/2` calls it for every message, on the live path and from a snapshot. The fold is its own module because `view_model.ex` went over the 400-line limit with it, and the module owns its state.
- `Helyx.TUI.Footer` writes row 2 as spans: the model, the run state, `in <n> out <n>`, `cache <p>%`, the cost, the context % (dim, yellow over 70, red over 90), the queue counts, and `scrolled`. Each value has its capped form. A token count is cut to tenths, not rounded. A cost form is chosen on the rounded value.
- `footer_usage_test.exs` checks each provider from recorded values (Claude Code `Meter`, Codex `Items`), and OpenCode Go and Zen from a chunk of the shape of the feature doc. Each row is checked on the live path and from a snapshot after a session file round trip.
- The docs: `coding-agent.md` describes row 2; `usage-and-limits.md` states the forms and names `SessionUsage`.

## What broke

- The first precommit failed on Dialyzer: with the usage first in `add_message/2`, the spec of `SessionUsage.add/2` narrowed the role, and the fallback clause of `add_cells/2` looked unreachable. The cells now come first.

## Open

- #559 brings the Codex and OpenCode costs and the OpenCode window. The tests of those providers then get a cost case.
- No OpenCode usage chunk is recorded. A recorded chunk of each gateway replaces the shaped chunk of the test.
