# Review: no drain between turns; the session monitors its provider (#361)

Date: 2026-10-03. Base: `origin/master` at `820aa57` (round 1), `a923517` (round 2, after the rebase onto #365).

Invariant: between two turns the session waits only for the hands' answer to the turn cleanup, the answer to an interrupt or an idle close, and the hands' `:provider_down` of a provider process that ends, and it never starts a provider process before the hands released the last one. Entry points: the turn end (normal, abort, failure, bad action), the idle close, the model switch, the session's `:DOWN` of its provider process, and the hands' `:provider_down`. Accepted hole: a turn that starts before the session reads the `:DOWN` of its current provider process fails at the hands' `:provider_down`.

## Simplify

Applied: the aliases on one line, one queue clause for `:rejected` of `:sent` and `{:ended, _}`, `Tools.send_result/5`, the comment wrap in `provider_process.ex`, a comment on the idle `:provider_down` clause. Skipped: the altitude finding "monitor only, remove the hands' `:provider_down`" (`Hands.start_provider/3` is a call with the 5,000 ms timeout and a release takes up to 20,000 ms); one shared close-turn pipeline (the three ends differ); "settle only when a steer was requeued" (small gain).

## Round 1

Bounds sensor (after the rebase onto `820aa57`): `bounds sensor: 6 candidate functions, 1 flagged, 0 without an answer` with `lib/helyx/session/provider_process.ex:71  SIZE+WAIT  defp loop(proc) do`. The loop has no own bound now; the session bounds each request kind (Bounds table).

| Axis | Finding | Resolution |
|---|---|---|
| Codex | Approve, no material finding | none |
| Failure path | A provider that ends right after its terminal fails a queued follow-up (reproduced with a suspended session) | Accepted hole, stated in "Built in #361" |
| Failure path | The `{:error, ...}` branch of the hands-answer clause is dead: the new `:DOWN` catch-all takes the request's `:DOWN`; its comment was false (reproduced) | Fixed: branch removed; the hands' linked `:EXIT` stops the session, as before; comments corrected |
| Standards | `Helyx.Session.Server.Wait` in `state.ex` breaks "the path follows the module name" | Fixed: `lib/helyx/session/server/wait.ex` |
| Standards | `Tools.end_turn/2` called `late/4`, whose name is for requests of another turn | Fixed: calls `send_result/5` |
| Standards | "(#361)" history tags in code comments | Fixed |
| Standards | `is_tuple/1` guard in `Queue.answer/3`; `if activity == :idle` in the `:DOWN` clause; `interrupt/2` name; repeated end-of-turn pipeline; queue tests read `queue.sent`; stale sentences in older "Built in" sections | Judgement calls, not taken: the server.ex line budget, and the old sections are history with "(Changed in #361)" notes |
| Spec | The next turn still waits for the hands' `:provider_down`, and a `:DOWN` in a turn is ignored | Kept, recorded in "Built in #361" (call timeout) |
| Spec | No count of the catch-all clauses | Fixed: listed in "Built in #361" |
| Spec | The steer ledger changed (`{:ended, turn_id}`), late `:rejected` in the next turn, idle abort notices ended steers, aborted answers before the hands kill the call | Kept: needed so that no steer answer is awaited; recorded in "Built in #361" |

The `.credo.exs` allowance of `server.ex` went from 622 to 616, its new size.

## Round 2

Full round (code changed). Bounds sensor not rerun: the round 1 fixes removed lines only in functions it already saw.

| Axis | Finding | Resolution |
|---|---|---|
| Codex | Approve, no material finding | none |
| Failure path | A prompt that waits in the mailbox while the idle provider process ends starts its turn on the dead process; the turn fails (reproduced). The sentence "a prompt after an idle provider process ended starts a new one" was too wide | Accepted: the same hole as round 1, wider. The old `Process.alive?/1` check only made the window smaller. Hole text and the sentence corrected (doc only) |
| Spec | `one-provider-path.md` "Stops" and "A fresh context" still named `@max_open` and `{:error, :busy}` | Fixed |
| Spec | Close the hole with a `down?` flag on `ProviderConn` | Rejected: the provider sends its terminal before it exits, so the session reads the terminal before the `:DOWN`; the flag is never set in time |
| Standards | The comment "Idle" on the last `:provider_down` clause names the wrong state | Rejected: the clauses above it take a Wait and a Turn, so only `:idle` reaches it |

Round 2 reproduced only the accepted hole, now stated in full; its fixes are doc only, so no round 3.
