# Review: one set of cell rules for the live fold and the snapshot (#305)

Date: 2026-10-02. Base: `origin/master` at `2b81e15`. Scope: `plugins/bundled/lib/helyx/tui/view_model.ex`, the TUI view model tests, `.credo.exs`, ADR 0006, and `docs/features/session-snapshot.md`.

## Invariant

The live fold (`ViewModel.apply/2`) and `ViewModel.from_snapshot/1` give equal transcript cells at the same `seq`. One function, `tool_cell/2`, makes every tool cell. A tool result with no open cell gives a closed cell to the next call with its id in the last assistant message, after the cells of that id: the call that the snapshot gives the result. The entry points are the `tool_execution_start` and `tool_execution_end` events and `from_snapshot/1`. Notices and the partial reply of an aborted or failed turn stay outside the rule (ADR 0006, section 3). The rule depends on the session invariant that no message goes between a call and its result; every transcript writer in `server.ex` (`abort_turn`, `fail_turn`, `close_assistant`, `take_steer`, `end_turn`) records the open results before it adds a message.

Accepted:

- The snapshot keeps its bulk construction (the ticket). So the cell constructor is shared, and the result pairing is two implementations of one rule: `attach_result/2` with `unstarted_cell/2` live, and `results_in_call_order/1` in the snapshot. The snapshot tests guard the pair.
- A result event with no matching call in the last assistant message makes no cell, as before. No session path sends one.

## Size

`view_model.ex`: 406 lines before, 400 after. The `.credo.exs` entry is removed. To fit, the `harness_session` clause is shorter and `lost_text/1` is inlined; the notice texts do not change.

## Round 1 (full)

Bounds sensor: `bounds sensor: 3 candidate functions, 0 flagged, 0 without an answer`.

Simplify (4 agents). Fixed: a duplicate result in the new unit test; the item 4 text of the ADR consequences. Skipped: a cell for every call at `message_end`, or a `tool_execution_start` from the session for an aborted call (a change of behaviour, and the second is outside the TUI); a check at every `seq` mid-turn (a snapshot exists only for the current `seq`; the snapshot tests compare at each join).

| Axis | Findings | Reproduced defects | Resolution |
|----|----|----|----|
| Standards | 0 hard, 6 judgement calls | 0 | `provider` name restored in the `harness_session` clause; the `unstarted_cell/2` comment names the no-call case; the stale sentence of `session-snapshot.md` updated; `%Message.Text{}` in the second-client test; this record and a devlog added. Not changed: the positional tool cell tuple (the existing cell shape of the moduledoc). |
| Spec | 1 partial, 1 scope creep, 2 nits | 0 | Partial: attach is not shared (accepted above). Scope creep: the `harness_session` clause, done for the file length entry. No new fail-turn test: no test provider makes a call that never started before a failed turn. |
| Failure path | 0 | 0 | Five probes through the session (repeated ids with an abort, two dangling turns, `dup_id` abort, steer then abort) gave equal cells. Not reached: a failed connected turn with open calls, a resume with open calls, a reconnect during an abort, very long cell lists. |
| Codex adversarial | 0 | 0 | Approve. |

No round reproduced a defect, so the loop ends after round 1.
