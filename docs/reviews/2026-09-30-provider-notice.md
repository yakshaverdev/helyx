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

## Codex round 2 (coordinator, after the rebase on #246)

| Axis | Finding | Resolution |
| --- | --- | --- |
| Codex | a program turn's error `result` (`origin.kind` `task-notification`) after a held success overwrote `held`, so the steer start sent "the turn before the steer failed" for a turn that succeeded | fixed: `held/2` keeps `turn.held` for a program turn's `result`. Tests: "a program turn's error result after a held success gives no notice" and "a program turn's success result keeps a held error"; both fail without the fix |

## Round 2 (reduced, by the coordinator's order)

The fix changes 14 lines of one code file, and `held/1` became `held/2`; by the arity rule this is a full round. The coordinator ordered a reduced round (spec and failure path). Invariant: only a `result` of a Helyx line can become the held error; a program turn's `result` never changes `held`.

| Axis | Finding | Resolution |
| --- | --- | --- |
| Spec | none: the fix, the doc, and the tests match the research note "Program turns" | none |
| Failure path | a program `result` with an `origin` other than exactly `{"kind": "task-notification"}` (another kind, a non-string kind, `null`) still counts as a Helyx `result` | accepted hole in the feature doc, with its reproduction: the research saw no such program `result` (roll-forward rule: a finding that needs a program behaviour the research did not see) |

The loop ends after round 2.

## Codex round 3 (coordinator)

Codex approved with no material findings. The gate sentence named the accepted hole of round 2.
