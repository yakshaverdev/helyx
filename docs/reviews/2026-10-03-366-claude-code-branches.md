# Review: remove the Claude Code branches that no run showed (#366)

Date: 2026-10-03. Base: `origin/master` at `a923517`.

Invariant: `Helyx.Provider.ClaudeCode` takes the program's output only through `translate/2` (stdout lines) and `Helyx.Provider.ClaudeCode.Mcp.message/3` (SDK MCP messages). An `init` line without both `interrupt_cancel_queued_v1` and `msg_lifecycle_v1` stops the provider process with `{:missing_capabilities, missing}`. Accepted: an error `result` held for an unresolved steer is lost with no notice; `control_cancel_request` is ignored as any unknown line; an `initialize` without `params.protocolVersion` gets the generic -32601 answer; a `result` before any `init` and before `started` is skipped; a `tasks` value other than `[]` keeps the program at an idle close. Kept with evidence: the 5 s steer wait, the lost-session relaunch, `notified?`, the `started` gate (#240), the replay chunks (#248), `notifications/cancelled`, the exact `still_queued` and `queued_turn_count` checks, the wait for `init`, and the interrupt wait for `started` after a replay (it needs a probe first). Out of scope: `harness_io.ex` and the `used` call-id sets (#369).

## Simplify

Round 1, four agents. Applied: `missing = @caps -- caps` bound once (efficiency, simplification, altitude); `cancel_call/2` inlined into the `notifications/cancelled` clause, its only caller after the removal of `cancel_request/2` (simplification, altitude); a comment in `turn.ex` rewrapped; three feature-doc lines that still said `:no_msg_lifecycle` marked superseded. Reuse: clean.

## Round 1

Bounds sensor: `bounds sensor: 29 candidate functions, 0 flagged, 0 without an answer`.

| Axis | Finding | Resolution |
|---|---|---|
| Failure path | `claude_code.ex` has 557 lines, `.credo.exs` says 556: Credo fails, so precommit fails. Reproduced with `mix credo --strict` | Fixed: the entry is 557 (down from 573) |
| Failure path | Probes through stdout passed: a non-list or absent `tasks` answers `:busy`; an `init` without either capability stops the provider and writes no interrupt; a non-list `capabilities` stops it; `initialize` with `params: %{}` gets -32601 | none |
| Codex | A `result` with a program-turn `origin` and `num_turns` 0 now writes the next replay chunk; it asks for a stop on that combination | Rejected: Codex states that no run showed it, and before #366 the code did not stop on it either (it held the chunk). A handler for one case of contract-breaking output needs evidence (`docs/agents/review-checklist.md`, "Inputs from plugins"). The research note and the probe below show `num_turns` 1 for a turn with a model call |
| Spec | "Every observed `init` listed both" was not shown by the research note for the later `init` lines of one process, and the check runs at every `init` | Probe on 2026-10-03 (`claude` 2.1.287, haiku, two turns on one process): both `init` lines listed both capabilities, and each `result` had `num_turns` 1. Recorded in the research note, "One process, many turns", and cited in "Built in #366" |
| Spec | "Built in #246" kept the old test name; its "fails safe" bullet contradicted the superseded note; the `num_turns` 1 claim did not say "1 run"; the doc did not say that `protocolVersion` is echoed with any type | Fixed (doc only) |
| Standards | `@caps` names the content, not the purpose | Fixed: `@required_caps` |
| Standards | "below" for sections above; "stops the program" against "stops the provider process" | Fixed (doc only) |
| Standards | `tasks` keeps a raw, unchecked value | Judgement call, not taken: only `[]` lets an idle close stop the program, so any other value keeps it (the old `:unknown` behaviour), with no sentinel |
| Standards | `{:missing_capabilities, missing}` is a reason of its own | Judgement call, not taken: it replaces two reasons (`:no_cancel_queued`, `:no_msg_lifecycle`) with one boundary check, and the process stops on the generic path |
| Standards | The list of deleted tests in the feature doc | Kept: the ticket asks to say which tests were deleted |

The fixes after round 1 renamed one attribute (2 lines in `claude_code.ex`), rewrapped one comment in `turn.ex`, and changed one count in `.credo.exs`. Two code files, so round 2 is a full round.

## Round 2

Simplify (one agent, four angles, over the round 1 fixes): clean.

Bounds sensor (base `origin/master`; no commit holds the round 1 tree): `bounds sensor: 8 candidate functions, 0 flagged, 0 without an answer`.

| Axis | Finding | Resolution |
|---|---|---|
| Codex | Approve: no material finding | none |
| Failure path | No code defect. Probes through stdout passed: an `init` with `capabilities` null, a string, a map, `[]`, or one capability, during a turn, between turns, and as a second `init` of one turn, stops the provider and lets no later event out; a `control_cancel_request` gives no `cancel_tool`. Credo passes. Doc: "Built in #359" still said an error `result` goes out as a notice | Doc fixed: marked as removed by #366 |
| Spec | "Built in #241", "#248", and "#240" still described `held`, the notice, the `origin` clause of `release/2`, the round 4 probe, and `caps` nil as current; "#248" cited a test assertion that the diff removed | Fixed (doc only): each passage marked superseded by #366, or rewritten |
| Standards | The `init` comment said "a program ... stops" for a stop of the provider process; the "renamed by #366" note was inside the quotes of a test name | Fixed (comment and doc only) |
| Standards | Judgement calls: the capability test lives in `replay_test.exs`; the comment on `@required_caps` cites the research note | Not taken: the test is the old `msg_lifecycle_v1` test with a new expectation, and the comment names which capability each part needs |

Round 2 reproduced no defect, so the loop ends.
