# Review: idle close of the harness program (#195)

Date: 2026-09-29. Base: `origin/master` at `f61ced3`. Invariant: the session sends `:idle_close` only when its current idle timer fires while it holds a ready harness process with no turn and no wait, and it holds every message until the answer; `:ok` ends the program, `:busy` keeps it and arms the timer again, any other answer or the 5,000 ms armed kill stops it; the Claude Code provider answers `:ok` only when its last `background_tasks_changed` `tasks` value is exactly `[]`.

## Simplify

- Efficiency: every arm left the earlier timer running. Fixed: `:erlang.start_timer/3`, and the arm cancels the earlier timer. Its ref is the token of the message.
- Altitude: the `Wait` comment did not name `idle`. Fixed.
- Altitude: one generic "pending answer" slot in `Wait` for the interrupt and the idle close. Skipped: the two read `:ok` in opposite ways, so the slot needs a kind tag and saves nothing.
- Reuse, simplification: clean.

## Round 1 (full)

Bounds sensor: `bounds sensor skipped: TYPESAFE_API_KEY is not set`.

| Axis | Finding | Resolution |
| --- | --- | --- |
| Standards | the `Wait` comment was not rewrapped | fixed |
| Standards | the fake's `kind/1` has two clauses where the loop has a guard | skipped: a test double, clear as it is |
| Standards | `idle` names the timer in `State` and the `from` in `Wait` | skipped: each is documented where it is defined |
| Spec | the provider reads only `background_tasks_changed`, not the `task_*` lines | the feature doc states why: the program's schema calls the line the level signal of the set, and the `task_*` lines are its edges |
| Spec | no test of the default and of the arm at the end of a wait | added: "is 30 minutes by default", "the end of an abort arms the timer again" |
| Spec | an `ambient` task keeps the program | stated in the feature doc; safe for #194. For the owner, if a housekeeping task turns out to live for the session |
| Spec | a program turn that a task notification starts can be ended by an idle close | the known gap in the feature doc, #194 |
| Failure path | no reproduced failure. Probed: an old timer message behind a new arm, a prepare, a prompt, a steer, a model switch, and an abort during an open idle close, the answers nil, `{:error, _}`, `:rejected`, `{:busy, _}`, `:busy` to a close and to a turn, and the wait for the `:harness_down` | none |
| Failure path | a line that is not JSON is dropped by `HarnessIO.lines/3`, so it does not set `:unknown` | the feature doc states it |
| Codex | during the idle-close wait a steer goes before an earlier prompt | not a defect of this change: the feature doc ("Built in #199") states that a steer in such a wait queues as a steer and steers go first, and the model-switch close does the same |

No reproduced defect: the loop ends after round 1.

## Precommit

Precommit failed only on `plugins/bundled/test/helyx/watchdog/harness_stop_test.exs:64` ("input over the watchdog stdin cap stops the program group and fails the turn"), with `:harness_timeout` in place of `{:harness_stop, _}`, in 3 of 3 runs. Clean `origin/master` (`f61ced3`) fails the same test with the same seed, 209683. The test passes alone. #228 fixes it. Everything else passed: format, compile with warnings as errors, Credo, Dialyzer, 274 root tests, and the other plugin tests. The merge gate runs precommit again after the rebase on the #228 fix.
