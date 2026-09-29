# Review: a duplicate item/started of a tool item (#234)

Date: 2026-09-29. Base: `origin/master` at `48e97fb`. Invariant: each tool item of the running turn gives at most one tool call event. An `item/started` of the running turn with the id of an item that has a tool call (from an earlier `item/started`, or from an `item/completed` that came with no start) stops the harness process with `{:malformed, "item/started"}` in `malformed/2`, before any state changes.

## Simplify

- Reuse, simplification: the `MapSet.put(state.started, id)` update is in two clauses. Skipped: a helper for one expression saves nothing.
- Efficiency: the test starts the fake program three times. Skipped: the ticket asks for a test through the fake program, one run for each case.
- Altitude: the moduledoc listed the cases, not the rule. Fixed.

## Round 1 (full)

Bounds sensor: `bounds sensor skipped: TYPESAFE_API_KEY is not set`.

| Axis | Finding | Resolution |
| --- | --- | --- |
| Standards | the `again?/3` comment said "of a tool item", but it checks the id only | fixed: the comment says that only tool items are in `started` |
| Standards | the moduledoc and the feature doc used two terms for "has a tool call" | fixed: one term |
| Spec | the feature doc said a second `item/completed` with no start gives no second tool call, and no test covers it | fixed: the claim is removed from the doc |
| Spec | the test checks the `tool_call` events, not the session transcript | no change: the transcript is built from these events |
| Failure path | an `item/started` of a non-tool item with the id of a tool item stops the harness process, but the docs named tool items only. Reproduced through the fake program | fixed as wording: the docs now say "the id of an item that has a tool call". The stop is the rule of #201 for a line that does not fit. The case needs one id for two item types, a new kind of bad line |
| Failure path | no other reproduced failure. Probed: a turn id not known yet, the reset of `started` at the turn end, the `started` check in `item/completed` | none |
| Codex | approve, no material finding | none |

No reproduced defect: the loop ends after round 1.

## Precommit

Passed once, after round 1: root 310 tests, `plugins/bundled` 1 property and 427 tests, `apps/coding_agent` 17 tests, 0 failures.
