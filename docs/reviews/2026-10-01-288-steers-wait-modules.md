# Review: pure Steers and Wait modules, one activity field (#288)

Date: 2026-10-01. Base: `origin/master` at `ad22e1b`. Scope: `lib/helyx/session/server.ex`, the new `steers.ex` and `wait.ex`, `turn.ex`, the tests that read the ledger or the wait with `:sys.get_state`, and the new `steers_test.exs` and `wait_test.exs`.

## Invariant

This is a refactor with no behaviour change. The steer ledger is `Helyx.Session.Steers`. It has the named states `:sent`, `:taken`, `:answered`, `:ended`, and `:noticed` in place of the `nil` and `:answered` tuple sentinels. It returns the effects `{:take, text}`, `{:requeue, text}`, and `{:notice, turn_id, text}`, and the session applies them in order. The wait is `Helyx.Session.Wait`. `next/2` names the request to send and `sent/3` records its ref. `turn` and `aborting` are now one field, `activity :: :idle | %Turn{} | %Wait{}`. The entry points are the `Session.Server` callbacks. Every event, notice, requeue, abort reply, and harness request keeps its order. A wait ends only when `hands`, `reply`, and `harness` are nil, `steers.open` is empty, and `results` is empty (the `{:done, callers}` clause of `Wait.next/2`).

Accepted changes:

- Two paths in a wait now run `progress/1`: a stale harness reply, and the `:harness_down` of the current harness process when no request is open. In both cases `progress/1` changes nothing in a wait at rest. Every place that builds a wait without running `progress/1` leaves `hands`, `idle`, or `harness` set.
- A second answer to a steer in `:answered` crashes the session. Before, it was dropped. The harness loop answers each request once, so only a bug can send a second answer.

The ledger and the wait take their own structs, never the whole `State`. `handle_info/2` was not split. One wait clause replaces three `harness_reply` clauses.

## Size

`server.ex`: 1,376 lines before, 1,183 after (−193). `steers.ex` has 124 lines and `wait.ex` has 164.

## Round 1 (full)

Bounds sensor: `bounds sensor: 19 candidate functions, 2 flagged, 0 without an answer` (`server.ex:393` and `:406`, SIZE, the two `:tool_result` clauses; the diff only renames `turn` to `activity` there).

Simplify (4 agents). Fixed: `Steers.map/2` uses `Enum.flat_map_reduce/3`; `Wait.after_turn/3` takes the harness pid, not a boolean; `close_turn/1` is deleted; `turn_id/1` and `wait_pid/1` replace the `is_struct` checks. Skipped: one ledger for tool requests (S1, out of scope); moving `interrupt/2` into `Wait` (only the abort uses it); one `:harness_down` clause with a guard (a guard on a nil `harness` fails, so two clauses stay); returning the timeout key from `Wait.next/2` (documented that the request tag is the key in `harness_ms`).

| Axis | Findings | Reproduced defects | Resolution |
|----|----|----|----|
| Standards | 0 hard, 7 judgement calls | 0 | `Steers.drop/1` renamed to `Steers.abort/1`. `Wait.t` has field types. Not changed: the 4-tuple entry (the AGENTS.md rule names maps); `next/2` returns the pid that it got (it says which pid the request goes to); no `CONTEXT.md` entry for Wait (an internal state, not a domain term). |
| Spec | 0 missing, 4 partial, 0 scope creep, 2 nits | 0 | See "Replaced tests". `wait_test.exs` passes a pid or nil to `after_turn/3`. |
| Failure path | 0 | 0 | One scratch probe through `Steers` and `Wait` passed. Not reached: a `:harness_down` racing an interrupt reply with real harness processes. |
| Codex adversarial | 0 | 0 | Approve. Its scratch test showed that open tool requests leave all 32 steer places free in a wait. |

No round reproduced a defect, so the loop ends after round 1.

## Replaced tests

Each `:sys.get_state` read of the ledger or the wait in `harness_test.exs` is replaced:

| Test | Old check | Replacement |
|----|----|----|
| a turn that ends as its harness process ends waits for the release | the wait holds the old harness pid | the snapshot shows no turn and the follow-up still queued, and the session answers while the hands are suspended; `wait_test`: a wait for an ended harness process lasts until its `:harness_down` |
| rejected after the terminal waits for its answer | the wait holds 1 steer | `steers_test` and `wait_test`: a normal end keeps the steer, `:rejected` queues it and ends the wait |
| an abort in the wait for a steer answer | 1 steer, then no wait and no queued steer | `wait_test`: the abort gives the notice and keeps the request; `Task.await` and the snapshot (0 steers) |
| an abort in the wait for a taken steer's answer | 1 steer and 1 caller | `wait_test`: the abort keeps the taken steer with no notice, and the wait ends with the caller after the answer |
| taken before its answer | the wait holds 1 steer | the snapshot shows the follow-up still queued before the answer; `steers_test`: a taken steer stays until its answer |
| hang / steer_error | no wait, no queued steer | the snapshot (0 steers), and a follow-up starts a turn with no queue update; `wait_test`: an answered steer gets its notice and the wait ends |
| an abort with a steer that has no answer | 1 steer, then no wait | `steers_test`: an abort gives the notice and keeps the request; `Task.await` and the snapshot |
| a failed turn with a steer that has no answer | 1 steer | `steers_test` and `wait_test` (abort or failure); the late `:rejected` still starts the follow-up and not the steer |
| the harness_down in the wait after an abort | no wait, no queued steer | `wait_test`: the `:harness_down` ends the requests with no second notice; `Task.await` and the snapshot |

The open item of #287 (an open tool request in a wait leaves room for one more steer) now has a pure test in `wait_test.exs`.

## Open

- Nothing.
