# Review: #407, the snapshot through the live fold on array storage

Branch `ticket/407-snapshot-fold`, base `origin/master` `277f346`.

Invariant: the TUI view model stores every cell in an Erlang `:array` by position and keeps a map from call id to a queue of open cell positions, so `apply/2` (`message_end`, `tool_execution_end`) and `from_snapshot/1` pair results by one function, `add_message/2`: a result closes the oldest open cell with its call id, each new cell and each result costs O(log n), and a result with no open cell crashes (owner decision, ADR 0006 revision of 2026-10-03). `Helyx.TUI.Transcript` folds the array in position order, O(n) per frame. Accepted: notices and text-only partial replies of failed or aborted turns are not in a snapshot; `transcript/1` of the test support compares cells as lists without the open positions.

## Round 1 (full)

Simplify: one agent for the four angles. Applied: one position read for each new open cell (`Map.update/4`, no second `:array.size/1`). Skipped: the crash on a result with no open cell (owner decision, see the failure-path row), the O(n) frame fold (the ticket keeps it), and the test-only `cells/1` (needed: the tests read cells as lists).

Bounds sensor:

```
bounds sensor: 5 candidate functions, 0 flagged, 0 without an answer
```

| Axis | Finding | Resolution |
| --- | --- | --- |
| Failure path, spec | Reproduced: a session file edited by hand with a result whose id names no call, or a result after a later message, resumes with that result in the transcript (`Transcript.abort_unanswered/2` keeps it), and `TUI.mount` then raises `KeyError` in `add_message/2` at every mount of that session. Before #407, `results_in_call_order/1` dropped it | Open, waits for an owner decision. The ticket says only a bug makes this state; the disk boundary makes it too. The fix belongs at the resume boundary in Core (drop or reject the result), and a dropped message changes the resume-id counts of `abort_unanswered/2`, so it is a design decision. The feature doc row and the code comment state the hole. No fallback in the view model (AGENTS.md) |
| Spec | The bounds table had no row for `open` or for the snapshot fold at mount | Fixed: two rows |
| Spec | "O(log n)" stated as a fact while the benchmark grows faster than n log n | Fixed: the wording names the cost of each new cell and each result; the doc states the measured growth and that its cause is not measured |
| Standards | Moduledoc held a ticket tag and a history note | Fixed: a link to the feature doc |
| Standards | `open_items/1` collided with the `open` field | Fixed: `streaming_items/1` |
| Standards | Representation leaks into tests (`:array.from_list/1` in render tests); the role dispatch exists in `apply/2` and `add_message/2` | Kept: the render tests build a view model for the renderer only, and `apply/2` has to skip a `tool_result` at `message_end` |
| Codex | Approve, no findings | none |

Round 1 reproduced a defect that is not fixed in this ticket, so round 2 ran. The fix changed comments, a private name, and docs in two code files: a full round.

## Round 2 (full)

Bounds sensor: `5 candidate functions, 0 flagged, 0 without an answer`.

| Axis | Finding | Resolution |
| --- | --- | --- |
| Spec | Three sentences said "O(log n)" for a step; a message with k calls does k + 1 sets | Fixed: "each new cell and each result costs O(log n)" |
| Spec | The doc understated the growth from 30,000 to 300,000 cells | Fixed: the factors (80 to 160 times live, 40 to 95 times snapshot; n log n predicts 12) |
| Spec, failure path | The comment and the doc named the hole differently; no damage path without an edit was found | Fixed: the comment points to the doc, and the doc names only edits |
| Standards | The result comment held ticket numbers; `cells/1` did not say it is for tests | Fixed |
| Standards | The moduledoc holds reasons from before #407 (the message rule, the guards) | Kept: not part of this change |
| Failure path | No defect reproduced. Not reached: two processes that resume and append to one session file | none |
| Codex | Approve, no findings | none |

Round 2 reproduced no defect, so the loop ends.

## Round 3 (reduced)

The precommit run after round 2 failed Dialyzer: `contract_with_opaque` on `new/1`, because the struct default held an `:array` literal. Fix in one code file, 4 lines, no new function: the default of `cells` is nil, `new/1` sets `:array.new()`, and `from_snapshot/1` starts from `new/1`. A reduced round: spec and failure path.

| Axis | Finding | Resolution |
| --- | --- | --- |
| Spec | The `new/1` doc said "For tests"; `from_snapshot/1` now calls it at each mount | Fixed: the doc says `from_snapshot/1` starts from it |
| Spec | The review record had no entry for this round | Fixed: this section |
| Failure path | No defect reproduced: no code builds the view model from the bare struct literal | none |

Round 3 reproduced no defect, so the loop ends.
