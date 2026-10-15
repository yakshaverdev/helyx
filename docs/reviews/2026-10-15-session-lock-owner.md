# Review: #589 the session server takes its own lock

Invariant: `Helyx.Session.start/2` and `resume/2` with `:sessions_dir` take the session writer lock only in the `init/1` of the session server process, which owns the lock port from its open to its close. So no death of the caller and no failure of the supervisor leaves the lock held with no live owner. `start/2` and `resume/2` keep their error shapes: a second resume in the same Core still gives `{:session_locked, id}`. A session is returned only when its lock port is still open at the end of the open, as far as the BEAM sees the end of perl.

Files: `lib/helyx/session.ex`, `lib/helyx/session/server.ex`, `lib/helyx/session/lock.ex`, `lib/helyx/core.ex`, `test/helyx/session/lock_test.exs`, `test/helyx/session/persistence_test.exs`, `docs/features/session-lock.md`, `docs/agents/review-checklist.md`.

Red first: the test "a caller killed during its open leaves the lock free" failed on the old code with `{:error, {:session_locked, id}}`.

Bounds sensor: round 1 `bounds sensor: 2 candidate functions, 0 flagged, 0 without an answer`; round 2 `bounds sensor: 1 candidate functions, 0 flagged, 0 without an answer`.

## Simplify (round 1)

The four agents first ran as background agents by mistake, and then ran again in the foreground. Both runs gave the same findings.

Applied:
- The test for the same Core became a loop over both Cores in the test for another Core.
- `create_file/4` was renamed, because it creates nothing now.
- A comment wrap in `Lock` was fixed.
- `hibernate_after: 0` (#103) was removed from the session supervisor. The start message holds no transcript any more. The two #103 tests stay as guards.

Skipped:
- Removing `Resumed.session_id`: `Helyx.Session.File.resume/3` is public, and its tests read the field.
- A shared helper for the suspended-supervisor setup at that time. It was applied in round 2.
- The catch in `Lock.run/2`: it gives a confirmed release in place of an unconfirmed one.
- The placeholder `model: nil, provider: nil` of a resume `State`: the init fills both or stops.
- Moving the open to `handle_continue` so the supervisor does not wait. The owner's triage puts the take in `init/1`, with its error returned through the supervisor.

## Round 1 (full)

Base `ad87a11` (origin/master at the start). Reviewed state kept as commit object `b866b662`.

| # | Axis | Finding | Resolution |
| - | ---- | ------- | ---------- |
| 1.1 | failure path | perl that ends during the open in `init/1` (a long resume read) gave a session with no lock, and its lost-lock notice went to no client. Reproduced: a resume of 40k messages, the session process suspended in `load_bounded/4`, perl killed. On master, `Lock.own/1` refused this start | Fixed: `Lock.hold/2` checks the port after `fun` and gives `{:lock_failed, "the lock ended before the session started"}`. Test "an open whose perl ends during it fails" |
| 1.2 | Codex | Approve, no findings | n/a |
| 1.3 | standards, spec | "Replaced mechanism" had no row for the removed `Lock.own/1`, `Lock.unlink/1`, the caller's release, `hibernate_after: 0`, and the renamed test | Fixed: item 5 |
| 1.4 | standards, spec | The Bounds row cited `resume/3`, but the init calls `resume_picked/3`. It also said "not reached" for a read with no time bound | Fixed: the row names `resume_picked/3` and says that the read has no time bound (see 2.4) |
| 1.5 | standards, spec | State rows with no test: the raise in the open, the crash after the open, and the init that still runs after the death of its caller | The death row got the test "a caller killed during its open leaves a running session that holds the lock". The raise row cites the probe below. The crash row is the generic crash of a running session ("a killed session frees its lock") |
| 1.6 | standards | History in code comments (`#589: before ...`) | Fixed: the comments state the property, and the history is in the feature doc |
| 1.7 | standards | `review-checklist.md` said that `resume/2` resolves the model after `File.resume/2` | Fixed: it names `resume_picked/3` in the `init/1` |
| 1.8 | spec | User story: a caller that dies after its start request reached the supervisor leaves a running session that holds the lock, so a second open in the same node says "open in another process" | Accepted hole, stated in the doc. The ticket's "What" covers the case where no init runs. The behaviour is the same as on master |
| 1.9 | spec | A raise in the open now returns `{:error, {exception, stacktrace}}`, where before it raised in the caller | Accepted: only a bug raises there. Probe: an end-to-end raise through `Server.start/3` matched that shape |
| 1.10 | altitude, standards | The mapping of `{:already_started, pid}` to `{:session_locked, id}` treats an id that this Core runs from another folder (a hard link) as locked | Kept: the Registry is the lock inside one Core, and the doc states it in item 5 |

### Fix size

18 code lines without tests and Markdown, in 3 code files (`lock.ex` check, `server.ex` comment, `session.ex` rename). Round 2 is a full round.

## Round 2 (full)

Base `b866b662`. Reviewed state kept as commit object `32a114f6`.

Simplify, four agents: the shared setup of the three tests with a suspended supervisor became `park_start/2` and `park_resume_and_kill_caller/2`. The altitude agent said that the check only narrows the window of the notice, which is 1.1 again (see 2.1). Skipped: a helper for the "lock is free" check (4 copies, an older pattern).

| # | Axis | Finding | Resolution |
| - | ---- | ------- | ---------- |
| 2.1 | failure path, spec | perl that is dead, but whose port the BEAM has not closed yet (about 15 ms after `kill -9`), passes the check of 1.1. Reproduced: 6 of 8 runs through `Session.resume/2`, and 19 of 20 with a kill at the end of the open | Second finding on one mechanism (the check of a dead perl at the open), so no second patch (such as a ping to perl). This cell is the hole that master has too: perl that ends after the open and before the first subscribe sends its notice to no client. The doc states the cell as part of that accepted hole. The fix of the mechanism keeps the lost lock in the snapshot, which needs its own ticket |
| 2.2 | Codex | Approve, no findings | n/a |
| 2.3 | spec | Bounds row: "starts and stops wait". A probe showed that the stop of another session returned in 5 ms while a start waited 1412 ms | Fixed: the starts of the Core and a stop of the Core wait; the stop of a single session does not |
| 2.4 | spec | The Bounds row said that the owner accepted the missing time bound of the read in `init/1`. The triage did not decide that | Fixed: the row says "unbounded" and points here. Open: see the end |
| 2.5 | standards | The `Lock.hold/2` comment did not name the new `:lock_failed` return | Fixed |
| 2.6 | standards, spec | The row "perl ends during the open" is proven at `Lock.hold/2` (lock_test), not through `Session.start/2`. "A new session leaves its file with only its header" had no test | The init returns the error of `hold/2` as it returns every other open error (test "a resume that fails after the lock frees it"). The header clause is removed |
| 2.7 | standards | `create_spec` uses "spec", the word of tool specs | Not applied (judgement) |
| 2.8 | spec | Same Core with a linked file gives `{:session_locked, id}`: shown by a probe only | Accepted: the Registry rejection is tested for the same folder (`lock_test.exs`, the first test) |

### Fix size

3 code lines (a comment in `lock.ex`) and doc text. Round 3 is a reduced round.

## Round 3 (reduced)

Base `32a114f6`. The briefs named the invariant of the round: each changed text states what the code does.

| # | Axis | Finding | Resolution |
| - | ---- | ------- | ---------- |
| 3.1 | spec, failure path | The row "perl ends during the open" pointed to "the next row but one" for its hole; the hole is in the row "perl killed while the session runs" | Fixed: the row names that row |
| 3.2 | spec, failure path | The `Lock.hold/2` comment named a bare `:lock_failed` and only a perl that ends while `fun` runs | Fixed: a `:lock_failed` error; the inner comment names a perl that ends right before the check |
| 3.3 | spec | 2.4 pointed to an open list that this record did not have | Fixed: "Open" below |
| 3.4 | failure path | No defect. Probe: the supervisor killed while an `init/1` held the lock, 3 of 3 runs: the caller exits, the session runs `terminate/2`, and the lock is free. Probes of the spec agent: starts wait for an `init/1` (1524 ms behind 1500 ms), a stop of the Core waits (1516 ms), the stop of a single session does not (102 ms) | n/a |

The round reproduced no defect, so the loop ends.

## Precommit

Run 1 failed on Credo strict: `Function body is nested too deep (max depth is 2, was 3)` at `lib/helyx/session/lock.ex` `hold/2`. The port check moved into a private `held/2` with no change of behaviour. A reduced round (spec and failure path) over `git diff 32a114f6 -- lib/helyx/session/lock.ex` found nothing. Run 2: see the commit.

## Open

- The read of a resume in `init/1` has no time bound. A slow disk holds the starts of the Core and its stop as long as the read. Before #589 the same read ran in the caller and held only that caller. A time bound, or an open outside the supervisor's wait, needs an owner decision.
- The lost-lock notice before the first subscribe (2.1). A perl that ends right before the check at the open, or after it and before the first subscribe, leaves a session that runs without the lock, and no client sees the notice. Master has the same window. The fix of the mechanism keeps the lost lock in `Helyx.Session.Snapshot`.
- A perl stopped with SIGSTOP after its `flock` and before its answer holds the lock with no session after the 5000 ms bound. This was not reached in the budget, and it is older than #589.
