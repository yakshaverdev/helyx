# Review: #595 A background start answer can come after turn_end

Invariant: a start answer of a background run that the hands take before the cleanup request of a turn reaches the session before the `turn_end` of that turn, and the snapshot at a `seq` equals the fold of the events up to that `seq` (ADR 0006, section 3). `Wait.finish/2` holds `turn_end` in the wait while a Helyx tool call of the turn runs (`ToolQueue.running`). `Wait.cleanup/2` emits it after the hands answer, before the notice of a failed cleanup. While it is held, `Events.snapshot/1` shows the turn as running with `partial` nil (`Wait.snapshot_turn/1`). A turn with no running call gets `turn_end` at once, also at an abort or a failure (owner decision of #595, option 1).

Files: `lib/helyx/session/server/wait.ex`, `lib/helyx/session/server/events.ex`, `lib/helyx/data/session/snapshot.ex`, `lib/helyx/session.ex`, `test/helyx/session/provider_process_tools_test.exs`, `test/helyx/session/sweep_test.exs`, `test/support/interfaces.ex`, `docs/features/session-lifecycle.md`, `docs/features/print-background-wait.md`. `turn_loop.ex` does not change (400 lines).

Accepted holes:

- The run whose start answer the hands took first lives, although its call got `aborted`. Option 1 orders the events. It does not stop the run. The half of the user story "a background run never outlives a turn that already gave its call the `aborted` result" stays open. Print mode counts the run and waits for its end.
- The release of the running call delays `turn_end`: the 500 ms TERM grace of a `bash` process group at an abort, and up to the release deadline for a stuck release. Before, `turn_end` went out at once and only the abort call waited.
- Hands that die in the wait, and a stop of the session in it, end the session with no `turn_end`, as a session that stops in a turn does. The client gets the end of the session.

Bounds sensor, round 1 and round 2:

```
bounds sensor: 0 candidate functions, 0 flagged, 0 without an answer
```

## Round 1 (full)

Base `HEAD` (`f17c104`). Codex ran with `--base origin/master`; master had moved by docs only (#566), and Codex reviewed the working tree.

Simplify, four agents. Applied: the `gated_start` flag of the test tool is one line in its default clause, not a clause of its own; two plain assignments for a tuple. Skipped: one shared gate forwarder for two test files (optional, in an unrelated test). Efficiency: none. Altitude: the release delay and the live run, now recorded as accepted holes.

| # | Axis | Finding | Resolution |
| - | ---- | ------- | ---------- |
| 1.1 | Codex | Approve, no findings | n/a |
| 1.2 | failure path | While `turn_end` is held, a second subscribe gets a snapshot with `turn: nil`, and then a `turn_end` arrives: the fold of the events up to the snapshot `seq` has a turn open (reproduced: suspended hands, a running `slow` call, `{:finish, turn_id}`). ADR 0006, section 3, covers the run state | Fixed: the snapshot shows the held turn with `partial` nil (`Wait.snapshot_turn/1`). Test: the subscribe in the new test of `provider_process_tools_test.exs` |
| 1.3 | failure path, spec | Hands that die in the wait drop `turn_end` | Accepted hole, stated in `session-lifecycle.md`; only a bug kills the hands, and the session stops with them |
| 1.4 | spec | The run lives although its call got `aborted` | Accepted hole (option 1 of the owner) |
| 1.5 | spec | At an abort or a failure with a running call, `turn_end` now waits too | Owner decision: option 1 waits for the cancel; the doc states it |
| 1.6 | spec | No test that the run lives and its end waits for a later turn | Fixed: the new test opens the gate and checks `running: 0, waiting: 1` |
| 1.7 | spec | The comment "between the turns" in `sweep_test.exs` is stale | Fixed |
| 1.8 | standards | Step 5 of `session-lifecycle.md` still said `turn_end` goes out there | Fixed: step 5 points at step 6 |
| 1.9 | standards | `running && data` | Fixed: `if(running, do: data)` |
| 1.10 | standards | The field name `turn_end` | Not changed: the struct comment says what it holds |

Round 1 reproduced one defect (1.2). The fix touches two code files and adds a function, so round 2 is a full round.

## Round 2 (full)

Base: the working tree of round 1. Fix diff: `events.ex` +3 lines, `wait.ex` +9 lines (`snapshot_turn/1`), a moduledoc sentence.

Simplify, four angles in two agents. Applied: the first form matched the `Wait` keys in `Events` (a struct match deadlocks the compile, because `Wait` imports `Events`); `Wait` now owns the rule with a struct match, and `Events` calls it. Skipped: an open turn id in `State` set by `turn_start` and cleared by `turn_end`, wider than the ticket.

| # | Axis | Finding | Resolution |
| - | ---- | ------- | ---------- |
| 2.1 | Codex | Approve, no findings | n/a |
| 2.2 | failure path | No defect. Probed: a follow-up and an abort in the held wait, `{:fail}` with a call running, the provider process killed in the held wait | n/a |
| 2.3 | spec | No defect. Probed the snapshot fold in the held wait, a failure with and without a running call, a compaction admitted while a call runs | n/a |
| 2.4 | standards, spec | "Hands that die in the wait stop the session with no `turn_end`" had no test | Fixed: `refute_received` of `turn_end` after the `:DOWN` in `sweep_test.exs` |
| 2.5 | spec | A failure with no running call has no committed test | Not changed: the abort test covers the same branch (`!done?` with no running call); the spec agent probed the failure |
| 2.6 | spec | The `bash` grace delay has no test | Not changed: the same path as the stuck release of `sweep_test.exs` |
| 2.7 | standards | `@spec snapshot_turn(term())` | Fixed: `:idle` or `t()` |
| 2.8 | standards | The doc list named the count and `queue_update` as two events | Fixed |
| 2.9 | standards | `Task.await/1` with the default timeout | Fixed: `wait_ms()` |

Round 2 reproduced no defect, so the loop ends. The fixes are wording, a spec, and tests.

## Round 3 (reduced, after the rebase)

The branch is rebased on `origin/master` (`98fb1103`) with no conflict. Two merges under it change the same modules: #562 (PR #610) monitors the prepare Task before it runs (`turn_loop.ex`, `wait.ex`), and #589 (PR #611) takes the writer lock in the session server's own `init/1` (`session.ex`, the server). Spec and failure-path agents only. Base `98fb1103` for the change, `f17c104b..98fb1103` for the merges. The brief named the three invariants: the start answer before `turn_end`, the snapshot equal to the fold, and `turn_end` at once with no running call.

| # | Axis | Finding | Resolution |
| - | ---- | ------- | ---------- |
| 3.1 | failure path | No defect. Probed: a context request holds a prepare Task in `submitted` while a `slow` call runs, then `{:finish}` with the hands suspended, with the Task alive, killed before, and killed after the finish; the session stopped while `turn_end` is held, with the lock of `init/1`. Ten repeats of the two changed test files and the probes: 0 failures | n/a |
| 3.2 | spec | No defect. Probed the prepare Task `:DOWN` and its late reply in the held wait, for `{:finish}` and `{:fail}`: the catch-all `:DOWN` clause of `TurnLoop` comes before the cleanup clause, so the `:DOWN` is dropped. A turn that fails in `preparing` with a call running cannot occur: a new turn has an empty tool queue. `init/1` emits no event, and the lock-lost notice has no turn id | n/a |
| 3.3 | spec | A session stop while `turn_end` is held gives no `turn_end` (reproduced with a session file and its lock); the docs named only the hands that die | Fixed: `session-lifecycle.md` and the accepted holes above name the stop too |

`lib/helyx/session.ex` has 399 lines. Round 3 reproduced no defect, so the loop ends.

## Gate (orchestrator, 2026-10-15)

Codex adversarial review on `e2a35d06` (rebased on `98fb1103`). Gate r1 (Codex): verdict approve, no finding. It did not run tests (read-only workspace). The test failure of the first round 3 precommit is in the lock test of #589, not in this change: #612.
