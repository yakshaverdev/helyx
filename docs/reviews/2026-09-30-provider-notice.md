# Review: provider notice event (#241)

Date: 2026-09-30. Base: `origin/master` at `d065f38`. Invariant: a provider notice `{:notice, text}` enters Core only through `Helyx.Session.Stream.check/2` (the stream Task and the harness loop), passes only as valid UTF-8 of at most 2,000 bytes and is a malformed event otherwise, becomes a `:notice` event only and never joins the transcript, the session file, or the model replay, and the TUI renders it through the sanitizing `styled_lines/3`; the Claude Code provider keeps the error `result` that it holds for an unresolved steer and sends it as a notice, cut to 2,000 bytes, at the start of the steer. Accepted holes (feature doc, "Built in #241"): an interrupt of a held turn, the `:steer_not_started` stop, an exit of the program during the wait, and a second held `result` before one steer start each lose the held error.

## Simplify

- Reuse, efficiency: clean.
- Simplification: a helper for the `String.valid?` branch that the notice and the delta clauses share. Skipped: a one-line body; a helper adds a name and saves nothing.
- Altitude: a generic "held terminal" in Core in place of `held` in the Claude Code provider. Skipped: only the provider knows why a `result` is not the terminal; Core sees only the events. Codex (#243) uses the same `{:notice, text}` event.

## Round 1 (full)

Bounds sensor: `bounds sensor skipped: TYPESAFE_API_KEY is not set`.

| Axis | Finding | Resolution |
| --- | --- | --- |
| Standards | `held` is a terse name | skipped: the `Turn` comment defines it |
| Standards | `held/1` matches the shape that `terminal/2` builds | skipped: same file, and no third shape exists |
| Spec | the cut of the held error in the provider has no test at the bound | added: "a held error over the notice bound is cut to 2,000 bytes" (1,500 "é"), and "a success result held for the steer gives no notice" |
| Spec | the reproductions of two accepted holes read as existing tests | reworded: each says which test to change and what it shows |
| Failure path | an exit of the program during the steer wait loses the held error, and the doc did not list it | added to the accepted holes, with the reproduction |
| Failure path | no defect: the notice bound held for multibyte subtypes and texts at 1,999, 2,000, and 5,000 bytes; a stale notice is dropped; no notice reaches the session file; the TUI drops control characters | none |
| Codex | approve, no material findings | none |

No reproduced defect: the loop ends after round 1. The fixes changed only tests and Markdown.
