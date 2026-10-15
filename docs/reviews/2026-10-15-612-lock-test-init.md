# Review: #612 The lock test resumes before the session init takes the lock

Invariant: the test "a caller killed during its open leaves a running session that holds the lock" (`test/helyx/session/lock_test.exs`) resumes from the other Core only after the session init has taken the lock. `:sys.get_state(sup)` waits behind the parked `start_child` request in the session supervisor, and that start returns only after `Helyx.Session.Server.init/1` returns. Test only (owner decision of #612).

Files: `test/helyx/session/lock_test.exs`.

Accepted holes: none.

Bounds sensor, round 1:

```
bounds sensor: 0 candidate functions, 0 flagged, 0 without an answer
```

## Round 1 (full)

Base `5c90d7e3`, the merge base with `origin/master`. Master had moved by docs only (#615).

Simplify, four agents. Applied: `:sys.get_state(sup)` replaces the poll on the session name and the `:sys.get_state` on the session pid. The parked start is the only message in the supervisor queue (`park_start/2`), so one call waits for the end of the init. Reuse, efficiency, altitude: none. Altitude checked every test in `test/`, `plugins/bundled/test/` and `apps/*/test/`: this test is the only one that waits on a session name after an asynchronous start. The triage names `server_test.exs`; no such file exists.

| # | Axis | Finding | Resolution |
| - | ---- | ------- | ---------- |
| 1.1 | Codex | Approve, no findings | n/a |
| 1.2 | failure path | No defect. Probe: after `:sys.get_state(sup)`, the supervisor queue is empty and the session state holds a lock port; 20 of 20 runs | n/a |
| 1.3 | spec | No defect. The ticket's "for example `:sys.get_state/1` on the session pid" allows the supervisor form; 20 repeats pass | n/a |
| 1.4 | standards | The comment did not say that the call is the barrier | Fixed: "This call waits behind the parked start" |
| 1.5 | standards | `_ =` before `:sys.get_state`, where `loop_test.exs` uses the bare call | Not changed: both forms occur, no rule |
| 1.6 | failure path | If the init fails, the assertion shows `{:ok, _}`, not the cause | Not changed: the test still fails, and a failed init is not this ticket |

Round 1 reproduced no defect, so the loop ends.
