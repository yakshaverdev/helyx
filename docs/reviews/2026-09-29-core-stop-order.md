# Review: Core stop order of the hands (#219)

Date: 2026-09-29. Base: `origin/master` at `09d22d7`.

## Invariant

At every session end, a Core stop too, the session ends its hands before it ends itself (`Helyx.Session.Server.terminate/2`). The Core stops its session supervisor before its task supervisor. So every release Task of the hands starts while the task supervisor runs. Bounds: the close of an idle harness process (5,000 ms, armed kill), then the wait for the hands (22,000 ms, then a kill). The session's shutdown bound is 30,000 ms. Accepted hole: over 22,000 ms the hands are killed and run no release; the port closes with the harness process, and the watchdog ends the program group. During a turn the harness process ends with the hands, with no release, as before.

## Round 1 (full)

- Simplify: 4 agents. Reuse and simplification proposed a shared monitor-and-wait helper with `stop_watch/1` in `Helyx.Session`. Skipped: the two waits differ (a timed stop, then a kill), and the helper would cross two modules. Efficiency proposed a parallel close of the harness and the hands. Skipped: the order is the fix; the hands must take the end of the harness process first. Altitude: the fix is at the right depth.
- Bounds sensor: `bounds sensor skipped: TYPESAFE_API_KEY is not set`.
- Standards: 0 hard violations. Judgement: the shutdown value was a separate literal. Fixed: it is now `5_000 + @hands_stop_ms + 3_000`.
- Spec: 0 findings. All three acceptance items are met.
- Failure path: 0 reproduced findings. Probes: suspended hands are killed at 22,002 ms, and no release runs; 20 repeats of the two new tests. Note: the comment on the order of the harness end and the session's `:DOWN` did not say what happens if the order changes. Fixed: the comment now states it (no release, no crash).
- Codex adversarial review: approve, no findings. A suspended-hands probe confirmed that the Core keeps its task supervisor until the hands are gone.

Round 1 reproduced no defect, so the loop ends. The two fixes are wording and a derived constant.

## Round 2 (full): the Codex gate finding after the rebase on #195

Finding (Codex gate, confirmed): the idle close of #195 sets a `%Wait{}`, so the idle clause of `terminate/2` did not match. The hands then killed the harness process with no release. Fix: at a session end with no turn, the session closes the current harness process and the one its wait is for, in parallel, and waits for both `:DOWN`s. Fix size: 19 added and 8 removed lines in one code file. Full round.

- Simplify: 4 agents. One change: the pid list is inline, not a helper.
- Bounds sensor: `bounds sensor skipped: TYPESAFE_API_KEY is not set`.
- Standards: 0 hard violations. Judgement: the `&&` list mixes a `%Connection{}` and a bare pid. Kept.
- Spec: 1 gap. No test for a stop during a switch close, the one wait where `state.harness` is nil. Fixed: test "a Core stop during a switch close closes and releases the program" with a new `late_close` test model. It fails without the fix.
- Codex adversarial review: approve, no findings.
- Failure path: 1 reproduced defect, open. The armed kill of the request that the wait is for (the interrupt of an abort, or an idle close) is still armed when the session sends its close. When that kill fires first, it kills the harness process before its close finishes: the `:DOWN` reason is `:killed`, not `:normal`. The release still runs. Reproduction: a provider that never answers the interrupt and answers the close after 300 ms, `interrupt: 200`, `close: 5_000`, a Core stop during the abort. Proposed fix: a `:close` request in `Helyx.Session.Harness.loop/1` cancels the kills of all open requests.

Decision (coordinator): the failure-path finding is an accepted hole, not a defect. The release still runs, and both programs end their commands on TERM in less than 1 s (research notes), so nothing leaks. The cost is only the gentler end of input. `harness.ex` does not change. The hole is stated in both #219 rows of the feature doc.

## Invariant after round 2

At every session end with no turn, also during a wait (an idle close, a switch close, an abort, a failed connected turn), each harness process that the session holds or waits for gets a close, and the hands release it before the session stops them (`terminate/2`, `end_work/1`). Bounds: the close 5,000 ms (armed kill), the hands 22,000 ms then a kill, the session shutdown 30,000 ms. Documented exception: during a turn the harness process ends with the hands, with no release. Accepted holes: over 22,000 ms the hands are killed and no release runs; at a session end during an abort or an idle-close wait, the close is bounded by what is left of the kill of the waited request, and when that kill fires first the program gets TERM, not end of input.
