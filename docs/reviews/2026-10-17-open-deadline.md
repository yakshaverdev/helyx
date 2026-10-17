# Review: a deadline on the session open (#665)

Scope: `Helyx.Session.Server.start/3`, `await_open/3`, `open_file/2`, `kill_after/1`, `cancel_kill/1`; `Helyx.Session.Server.State` field `open_ms`; the docs of `Helyx.Session.start/2` and `resume/2`; `CodingAgent` sentence for `:open_timeout`; `docs/features/session-lock.md`.

Invariant: the open of a session with a `sessions_dir` (the lock take plus the create or the resume read) ends within `open_ms` (25,000 ms), because a killer process kills the session process, whose port then closes so perl frees the lock; the caller gets `{:error, :open_timeout}`; the cancel waits for the `:DOWN` of the killer, so no kill reaches a session after its open.

## Round 1 (full)

Bounds sensor (base `origin/master`):

```
bounds sensor: 11 candidate functions, 0 flagged, 0 without an answer
```

Simplify: the deadline moved from a fourth argument of `Server.start`, threaded through `init/1` and `handle_continue/2`, to a `State` field `open_ms`, as `prepare_ms` (simplification and altitude agents). Skipped: the reflow of the `start/2` doc paragraph stays, because it keeps `lib/helyx/session.ex` at the 400-line limit. Reuse and efficiency: clean; `:timer.kill_after/1` does not fit, see finding 4.

Codex: approve, no finding.

| # | Source | Finding | Resolution |
| - | ------ | ------- | ---------- |
| 1 | Standards | The deadline tests used 50 ms and 200 ms, counted from before the perl take; a take slower than that under load kills the session before the open, and the test waits for `:in_open` until the receive timeout. An upper bound with no load margin (#193) | Fixed: `@load_open_ms 500` with its reason. Not reproduced |
| 2 | Standards | `start_held/3` repeated the default 25,000 ms of the state | Fixed: `start_held/3` takes fields of the state (`struct!/2`) |
| 3 | Standards | `kill_after/1` has the name of `:timer.kill_after/1` and works differently | Kept: the comment above it names the difference |
| 4 | Standards | The guarantee "no kill reaches a session after its open" has no test | A race of the BEAM scheduler has no deterministic test. Proof by probes: the failure-path agent ran 20 opens across the deadline (16 ok, all alive with their lock; 4 timeouts, all gone with the lock free); the spec agent ran 300 (243 ok, none killed after; 57 timeouts). The order holds by structure: a signal of a process to the session comes before the `:DOWN` of that process |
| 5 | Standards, spec | "the 30,000 ms that a wire client waits" (#656) names no code: #656 is an open docs ticket | Fixed: "that #656 plans for a wire client" |
| 6 | Spec | The `resume/2` doc did not name the deadline | Fixed |
| 7 | Spec | "the open is killed", "A kill ends the open": the resume read runs in an unlinked process (`load_bounded/4`) that ends its bounded read alone | Fixed: the comments say the session is killed; the Bounds row names the unlinked read |
| 8 | Spec | "Only the deadline kills the session before its result" is true only while `Stop.shutdown_ms/0` (31,000 ms) is longer than the deadline | Fixed: the comment and the `State` comment state the order; the States row says that any other kill maps to the same error |
| 9 | Spec | The Bounds row said a Core stop kills an open at its shutdown; the deadline now ends it first | Fixed |
| 10 | Spec | "leaves the lock at most until the deadline": perl frees the lock after the port closes, with no Helyx bound | Fixed: the session ends at the deadline; perl frees the lock as for a crash |
| 11 | Spec | No test calls `Session.start/2` or `resume/2` past the deadline; the tests call `Server.start/3` with a held open | Accepted: no public entry holds an open (as in the review of #605); both entries reach the deadline through `open_file/2` |
| 12 | Failure path | No defect. Probes: 20 opens across the deadline; a Core stop during a held open (the deadline kills at 24,995 ms, the caller gets `:open_timeout`); the lock tests | Not reached: a kill during a file operation that blocks in the OS. Stated as an accepted hole in the Bounds row |

No finding reproduced a defect, so the loop ends after round 1. The fixes above change tests, docs, and comments only.
