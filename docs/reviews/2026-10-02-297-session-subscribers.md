# Review: the session holds its subscribers (#297)

Scope: `git diff origin/master` on `ticket/297-session-subscribers`. Spec: `docs/features/session-subscribers.md`.

Invariant: every event that a session emits after the snapshot of a subscribe reaches that subscriber exactly once, until the session ends, the subscriber unsubscribes, or the subscriber dies; a caller gets at most one end signal for a session id, the tagged monitor message of its current subscription. Entry points: `Helyx.Session.subscribe/1`; the `{:subscribe, pid}` call, the `{:unsubscribe, pid}` message, and the subscriber `:DOWN` in `Helyx.Session.Server`; the end signal clause of `Helyx.TUI`. Accepted holes (feature doc): events sent before a failed or timed-out subscribe can stay in the mailbox, and the client drops them by `seq` and `instance_id`; the subscribers of one session are unbounded (#116); the flush of end signals at a subscribe matches the id only, so it can remove an unread signal of an ended session with the same id in another Core.

Line budget: `lib/helyx/session/server.ex` is listed in `.credo.exs` and must not grow (#294). The subscriber map adds about 20 lines, so the snapshot of a turn (`snapshot_turn/1`, `started_calls/1`) moved to `Helyx.Session.Turn.snapshot/1`, where the data it reads lives, and five one-expression clauses take the `do:` form. The file goes from 1183 to 1182 lines. For the same reason the snapshot keeps an inline `if(match?(%Turn{}, ...))` and the unsubscribe a `ref &&` demonitor; two clauses each would pass the limit.

## Round 1 (full)

Simplify: four agents. Fixed: stale comments and traps for the old Registry link in `plugins/bundled/test/helyx/tool/bash_test.exs` and `apps/coding_agent/lib/mix/tasks/helyx.graph.ex` (`stop/1` removed); a note at the top of `session-snapshot.md`. Skipped: a shared `queued?` test helper (an older pattern, outside the change); the `Process.put/2` form of the dictionary write (S5 removes the old monitor first); the clause collapses and the `Turn.snapshot/1` move (the line budget above).

Bounds sensor: `bounds sensor: 5 candidate functions, 0 flagged, 0 without an answer`

| Axis | Finding | Resolution |
|---|---|---|
| Failure path | The caller's process dictionary grows by one entry for each session that ended: the old `leave/2` removed the entries of dead watches, the new code had no replacement. Reproduced: 50 sessions, 50 stale keys | Fixed (`.credo.exs`: `session.ex` 489 on master, now 470, so the list still shrinks): each subscribe removes the entries whose session process is dead (round 2 changed the check to the monitor list), then removes the end signals for the id from the mailbox, as `leave/2` did. The entry value is `{ref, pid}`. Tests: "the entries of ended sessions go at the next subscribe", "a subscribe after a resume drops the signal of a forgotten entry". Feature doc S5 and the bounds table updated |
| Codex | A `:DOWN` with a reference that is not the one of the entry crashes the session; S4 says it changes nothing | Not reproduced through a boundary: the probe sent a forged message. The `:DOWN` of an entry removes it, an unsubscribe demonitors with `[:flush]`, and a repeated subscribe makes no monitor, so no subscriber can make such a `:DOWN`. A no-op clause would be a fallback for a state no caller can make (AGENTS.md). S4 now states this |
| Standards | `if(match?(%Turn{}, ...))` and `ref &&` in place of clauses | Kept: the line budget above |
| Standards | "S5" in a comment names no doc | Fixed: the comment cites the feature doc |
| Standards | Stale dictionary entries | Same as the failure-path finding |
| Spec | The new test "a subscribe to another session keeps the end signal of the first" has no row; "a subscribe while the Core stops" has two rows; the removed traps in `helyx.graph.ex` and `bash_test.exs` have no row | Fixed in the feature doc |
| Spec | The `Turn.snapshot/1` move and the clause collapses are not asked for | Recorded here: the line budget |
| Spec | The PR must list every test row | The commit message lists them |

Changed in the build, recorded in the feature doc: `instance_test.exs` and the TUI test of #204 assumed that the entry of a subscriber crosses a resume. The entry ends with the session process, so both tests subscribe again.

## Round 2 (full: the fix adds two functions)

Fix diff: `lib/helyx/session.ex`, 25 lines added, 3 removed. Simplify: four agents, no change applied. Skipped: a delete of the entry where the client handles the signal (the client owns that message, `subscribe/1` does not); folding the flush into the prune (a later subscribe after a resume must still flush, when the entry is already gone).

Bounds sensor: `bounds sensor: 6 candidate functions, 0 flagged, 0 without an answer`

| Axis | Finding | Resolution |
|---|---|---|
| Failure path | `Process.alive?/1` is false before the `:DOWN` of the process arrives, so the prune could drop an entry whose signal was still in transit, and after a resume the old signal reached the new subscription. Reproduced 2 of 4 runs with 30,000 monitors on the session | Second finding on the prune, so the mechanism changed: the prune keys on the caller's monitor list, which a monitor leaves only when its `:DOWN` is in the mailbox. Probe: 20,000 kills, the `:DOWN` was in the mailbox every time the monitor had left the list. S5 and the bounds row updated |
| Codex | none (approve, on the tree with the round 2 fix) | — |
| Standards | `session.ex` grew in `.credo.exs`; the `{ref, pid}` entry is a bare tuple; the flush scans the mailbox; S5 is long | The count is below master (489). The tuple stays private to `subscribe/1`. The flush got a bounds row. S5 kept as one rule |
| Spec | S8 said 30 lines; the new test row name differed from the test | Fixed in the feature doc |
| Spec | A foreign `:DOWN` that crashes the session has no test | Kept: no subscriber can make one (round 1, Codex) |

## Round 3 (full: the second finding on the prune)

Fix diff: `lib/helyx/session.ex`, 8 lines added, 3 removed. Simplify: four agents, no change applied. Skipped: a list of pids in place of the `MapSet` (the monitor list can hold entries of other shapes).

Bounds sensor: `bounds sensor: 6 candidate functions, 0 flagged, 0 without an answer`

| Axis | Finding | Resolution |
|---|---|---|
| Failure path | None reproduced. The round 2 reproduction, reordered so that the caller's signal comes last, opened the window in 4 of 5 runs and gave no old signal after the new subscription in 5 of 5 | — |
| Codex | none (approve) | — |
| Standards | Another monitor of the same pid keeps an entry; the prune cost is not in the bounds table; "changed the test" in the round 1 row | Doc fixes: S5 states the kept entry, a bounds row for the prune, the row says "the check" |
| Spec | The kept entry under another monitor of the same pid is not in S5 | Fixed with the standards finding |
| Spec | No test holds the in-transit `:DOWN` window | Kept as a probe only: the window needs tens of thousands of monitors on the session, a load the test suite must not make |

The round reproduced no defect, so the loop ends.

## Precommit

The first `HELYX_SLOW=1` run failed one test: in "subscribe and events in one step", a client under load could subscribe after the test stopped the session. Test-only fix: the test waits for each client's subscribe before the stop. It changes no code, and the round limit allows no fourth round, so no agent reviewed it.
