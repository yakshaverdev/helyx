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
