# Review: steer delivery into the running turn (#202)

Date: 2026-09-29. Base: `48e97fb` (the branch base; `origin/master` has one docs-only merge more). Invariant: a steer on a connected turn reaches the harness at most once. The session sends `{:steer, turn_id, steer_id, text}` only in `submitted`. Steers queued in `preparing` join the prompt, and steers queued in `submitting` go out after the `:ok` of the turn. The session queues a steer again only on a confirmed `:rejected`: for Claude Code, the turn already ended and nothing was written; for Codex, `turn/completed` already came, or the answer is the exact error code -32600 with the message `no active turn to steer`. After `:ok` the session waits for `{:user_message, steer_id, text}`. Any error, the loop answer `:busy` over 8 open requests, and the 2,000 ms steer deadline are unknown: a `:steer_unconfirmed` notice, and no second send. Sent steers count in the 32 steers. A Claude turn never ends while a written steer has no `command_lifecycle` `started`: a 5,000 ms wait after a held `result`, then the harness process stops with `:steer_not_started`. At a normal end, the session waits for the unanswered steer replies before the next turn starts. Entry points: `Session.steer/2`, the `harness_reply` and `user_message` handlers of `Helyx.Session.Server`, `Helyx.Session.Harness`, and `harness_request/3` and `harness_info/2` of `Helyx.Provider.ClaudeCode` and `Helyx.Provider.Codex`. Accepted holes: a Codex turn id mismatch error is unknown, not rejected; a held Claude error `result` is lost when the steer's turn then succeeds; the steers of a Claude lost-session relaunch are dropped with notices. Documented exception: a reply that the loop makes at the bound can still be followed by the armed kill. Open tickets: #224, #234.

## Simplify

- Reuse: the user line of a steer and of a turn were built twice in the Claude provider. Fixed: `user_line/2`.
- Reuse: `take_steer/2` and `close_assistant/3` both aborted the open calls. Fixed: `abort_turn_calls/1`.
- Simplification: the steer answer was `:ok` or `:unknown`, but no code read the difference. Fixed: `:answered`.
- Simplification: the `Turn.steers` comment named a map. Fixed.
- Simplification: `held?` in the Claude turn was always `wait != nil`. Fixed: removed.
- Efficiency: `submit/1` took the steers back out of the transcript with `Enum.take/2`. Fixed: `append_steers/1` returns the texts.
- Efficiency: the Claude steer timer was not cancelled at the start of a steer. Fixed in round 1 (see below).
- Skipped: `steer_room?/2` repeats the limit test of `push/4`, and a `held` field inside `Queues`. The session derives `held` from the turn and the wait, so a field would be a second copy of that state.
- Skipped: one store for the steers of the turn and of the wait. It is a larger change of the wait; the two stores are documented.
- Skipped: the `user_message` event with no text. The event shape is in the design doc; the session already uses its own text.
- Skipped: `message_end` before `user_message` as a provider rule. The session closes the message itself, so a provider that does not close it cannot put a message between a call and its result.
- Skipped: one bound in the session for the 8 open requests. The loop bound protects every request kind, not only steers.

## Round 1 (full)

Bounds sensor: `bounds sensor skipped: TYPESAFE_API_KEY is not set`.

| Axis | Finding | Resolution |
| --- | --- | --- |
| Failure path | an abort in the wait after a normal end, then a late `:rejected`, queued the steer again, and a turn started after the abort (reproduced) | fixed: the abort in the wait gives the notices of the waiting steers and clears them (`drop_wait_steers/1`); test "an abort in the wait for a steer answer gives its notice, and a late :rejected starts no turn" |
| Codex | a `user_message` before the steer's answer removed the steer, so the normal end did not wait for the open request, and its armed kill could end the next turn (reproduced in callback probes) | fixed: a taken steer with no answer stays in the turn with a nil text until its answer; it gets no notice; test "taken before its answer: the turn end waits for the answer, with no notice" |
| Spec | the 5,000 ms Claude wait had no test of its value | fixed: the timer is `:erlang.start_timer/3`, the test reads its remaining time (margin `@load_ms` 2,000), and the start of a steer cancels it |
| Spec | no Claude test of a steer that starts after a tool result | added: "that starts after a tool result gives user_message after the result" |
| Spec | a late `:rejected` after an abort or a failure is not queued; not stated | stated in "Built in #202" |
| Spec | a `:rejected` during the turn can change the order against a later steer | stated in "Built in #202" as accepted |
| Spec | Claude depends on `started` after the tool results (#198) | no change: the research note records it; the new test covers the order |
| Standards | the event doc had an incomplete sentence | fixed |
| Standards | the Claude error-`result` hole names no ticket | reported to the owner in the worker report |
| Standards | duplicated drain in `append_steers/1` and `send_local_steers/1`; `unconfirmed/2` takes an atom that acts as a flag; steer state in tuples | skipped: judgement calls, each short and documented |

Round 1 changed more than 15 code lines in more than one file: round 2 is a full round.

## Round 2 (full)

Simplify on the round 1 fix: the `user_message` handler used an `if` on the answer (fixed: two clauses); the abort in the wait rebound the wait (fixed: `update_in/2`). Skipped: the cancel of the Claude steer timer is kept, so no stale timer message stays (round 1 efficiency finding).

Bounds sensor: `bounds sensor skipped: TYPESAFE_API_KEY is not set`.

| Axis | Finding | Resolution |
| --- | --- | --- |
| Codex | `user_message` before the answer, normal end, abort in the wait, next prompt: the abort cleared the open request, and its armed kill could end the next turn (reproduced) | mechanism fix, see below |
| Spec | the same hole after an abort or a failure during the turn: the open steer requests were not in the wait | mechanism fix, see below |
| Failure path | no reproduced defect; 7 probes (harness killed in the wait, abort with a held steer, crossed answers, model switch in the wait, a steer in the wait, 9 held steers) | none |
| Standards | the `wait/2` comment did not name `steers` | fixed |
| Standards | the Claude error-`result` hole names no ticket | reported to the owner |
| Standards | layout of the `Turn.steers` comment and of `prompt_line` | fixed |
| Standards | `unconfirmed/2` took an atom that acts as a flag; steer state in tuples; duplicated drain | the flag is gone with the mechanism fix (`end_steers/2` takes `normal?`); the rest skipped as judgement calls |
| Standards | the 5,000 ms test reads the remaining time with a lower limit | kept: the margin is stated in `@load_ms` |

Two findings on one mechanism (the open steer requests after the turn): the fix is the mechanism, not the path. At every end of a turn, `end_steers/2` puts each steer request that has no answer into the wait, by its `from`. After an abort or a failure the steer has its notice already and a nil text, so its answer only ends the wait. An abort in the wait gives the notices and keeps the requests (`drop_wait_steers/1`). A `:harness_down` ends all of them (`end_wait_steers/1`), and a failure at the `:harness_down` puts none in the wait. Tests: "an abort with a steer that has no answer gives a notice" (the abort now returns only after the answer), "an abort in the wait for a taken steer's answer starts no turn before the answer".

The fix changes more than 15 code lines: round 3 is a full round, and the last one.

## Round 3 (full, the last)

Simplify on the round 2 fix: no finding.

| Axis | Finding | Resolution |
| --- | --- | --- |
| Codex | no reproduced defect; 96 lifecycle probes (late answers, harness down, repeated aborts, model switch with open steer requests); verdict approve | none |
| Failure path | no reproduced defect; 11 probes (harness down in the wait, model switch then a late `:rejected`, abort in `submitting`, failure at the `:harness_down`, 32 steers with 8 open at an abort, two aborts in the wait, a steer kill in the wait, a taken steer then an abort) | none |
| Spec | no test of a failure that is not a `:harness_down` with an open steer request | added: "a failed turn with a steer that has no answer gives a notice; a late :rejected starts no turn" (the connected test model has `{:fail, turn_id}`) |
| Spec | no test of a `:harness_down` in the wait after an abort with an open steer request | added: "the harness_down in the wait after an abort ends its open steer requests" |
| Standards | the comments on `wait/2`, on the wait steer answer, and on the 32-steer count (`held/1`, the steer call) named only the normal end | fixed |
| Standards | the wait steer answer uses `if` on `:rejected` and the text; no `refute` for a second notice | skipped: judgement calls |
| Standards | an ambiguous "which" in the "Built in #202" doc | fixed |

No reproduced defect: the loop ends.
