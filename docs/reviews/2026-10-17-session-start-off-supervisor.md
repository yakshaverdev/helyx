# Review: session start off the supervisor (#605)

Scope: `Helyx.Session.Server.start/3`, `init/1`, `handle_continue/2`, `terminate/2`; `docs/features/session-lock.md`.

Invariant: the session supervisor waits only for an `init/1` that does no work that can wait; the lock take and the open run in the session process after a go from its caller, `start/2` and `resume/2` return every open error synchronously, and a caller that ends before the open result leaves no session process and no lock.

## Round 1 (full)

Bounds sensor (base `origin/master`):

```
bounds sensor: 2 candidate functions, 0 flagged, 0 without an answer
```

Simplify: the caller monitor became `Process.alive?/1` (reverted in the fix below), a duplicate test went, a path is bound once. Skipped: an idle-session reclaim (out of scope), one teardown path through `Stop.run/1` (needs two nil clauses there for one line here).

| # | Source | Finding | Resolution |
| - | ------ | ------- | ---------- |
| 1 | Codex | The caller monitored the session after `start_child` returned; an open that crashed first gave `{:error, :noproc}` in place of `{:error, {exception, stacktrace}}`. Reproduced by Codex with a probe | Fixed: the session waits for a go message that the caller sends after its monitor (`await_open/3`); the caller monitor of the session is back in `init/1`. Test "an open that raises gives the crash as an error, and the lock is free" |
| 2 | Spec | A caller that ends between the check after the open and its receive gets a session that runs; for `start/2` nobody has its id | Accepted, stated in the States table: the window is the same as a caller that ends right after `start/2` returns. An ack from the caller moves the window, it does not close it |
| 3 | Spec | "Bound the startup and its cancellation": a caller that ends during a slow resume read leaves the lock until the read ends; the read has no time bound | Accepted for the scope comment, which names the property "leaves no lock and no process". Recorded as open in the Bounds table; needs a ticket |
| 4 | Spec | A Core stop during the open: `start/2` can return `{:ok, session}` for a session that then stops | Stated in the Bounds table. Before #605 the same start returned after the `init/1` and the session then stopped |
| 5 | Standards, spec, failure path | Comments said the take and the open run in the init: `session.ex`, `core.ex`, `lock.ex`, two tests | Fixed |
| 6 | Standards | The rows "the open raises" and "the session crashes after the open" had no test | The raise row has the new test. The crash after the open has no test: no boundary makes `Hands.start_link/1` fail |
| 7 | Standards | `Process.alive?/1` raises for a remote pid | Gone with the fix of 1: a monitor |
| 8 | Standards | The test helper builds `Server.State` by hand | Kept: no public entry takes an open function, and the held open makes the tests deterministic |
| 9 | Failure path | No defect. Probes: Core stop during a held open (the kill at `shutdown_ms`, lock free), an open that raises, perl and the caller killed during the open, an open error, perl killed during the open, two resumes of one id | none |

## Round 2 (full)

The fix of round 1 adds functions and passes 15 lines, so a full round. Bounds sensor (base `e7543466`, the merge base; `origin/master` moved):

```
bounds sensor: 5 candidate functions, 0 flagged, 0 without an answer
```

Simplify: one helper for the repeated lock-free wait in the tests. Skipped: the monitor ref as the reply tag (the caller's monitor does not exist at the init), the removal of the check after the open (it holds the property of the scope comment).

Codex: approve, no finding. Failure path: no defect; probes of an open that raises at once (20 runs), a throw, `exit(:normal)`, a bad return, and a Core stop during a held open. Spec: no defect; probes of a caller killed before the go, 40 raising opens, a crash in the hands start, a Core stop during the open. No round reproduced a defect, so the loop ends.

| # | Source | Finding | Resolution |
| - | ------ | ------- | ---------- |
| 1 | Standards, spec, failure path | The open bound row said "no ticket yet"; the checklist asks for a ticket | Ticket #665; the row names it |
| 2 | Standards | `docs/agents/review-checklist.md` said the resume read runs in the `init/1` | Fixed |
| 3 | Standards, spec | No test for "a caller that ends before the go leaves no take" | Test "a caller killed before its start reaches the supervisor leaves no session and no lock": the file keeps its missing newline |
| 4 | Spec | The raise test raised after the go of the test, so it did not guard round 1 | The open raises at once, in the test process |
| 5 | Standards | "a caller that ends during its open" read the lock once after the stop; the release can pass its bound under load | It waits with `await_lock_free/2` |
| 6 | Standards | `open/5` had an argument `open` | Renamed `run_open/5` |
| 7 | Standards | The comment on `start/3` named the ticket | Dropped |
| 8 | Standards, spec | The row "the session crashes after the open" had no test | The row says that a probe shows it: no boundary makes the hands start fail |
| 9 | Spec | The window after the check also covers the hands start | Accepted, as round 1, finding 2. Judgement: a check after the hands start makes it smaller, not closed; not done after the last round |
| 10 | Spec | `error -> error` left `Server.start/3`; another `start_child` error raises `CaseClauseError` | Kept at first: the claim was that no boundary gives another error. Wrong, see round 3 |
| 11 | Spec | A second resume of one id in one Core during a first open that then fails gets `{:session_locked, id}`; before #605 it waited and could succeed | Consistent with two Cores (session-lock.md, "Interface changes") |

## Round 3 (a Codex check of the Markdown claims)

| # | Source | Finding | Resolution |
| - | ------ | ------- | ---------- |
| 1 | Codex | A Registry partition that stops while its meta stays readable fails the registration before the `init/1` with `{:error, {:noproc, stacktrace}}`; with `error -> error` gone, `Session.start/2` raised `CaseClauseError`, where the base returned the error. Reproduced by Codex with a probe that held the Registry restart open | Fixed: the clause is back, as in the base (one line). No test: holding a Registry restart open needs a probe of its internals. Round 2, finding 10 was wrong |

The fix meets the conditions of the small-fix round (one line, one file, no function, arity, or return shape changed), so one reduced round follows.

## Small-fix round (reduced: spec and failure path)

No defect in this diff. The failure path reproduced the fix: with the session supervisor parked and the sessions Registry killed, `Session.start/2` returns `{:error, {%ArgumentError{}, stacktrace}}`. Spec: every `start_child` result gives a tuple; 200 pairs of a failed open and an immediate retry of the same id gave the open error both times.

Open, older than this change (also in `e7543466`): when the sessions Registry of the Core is down, `Helyx.Core.plugins/2` in `Server.start/3` and the plugin lookups before it raise `ArgumentError` out of `Session.start/2` and `resume/2` in place of an error tuple; `Session.set_model/2` rescues the same raise. Not in the scope of #605; reported to the orchestrator.

Precommit (`HELYX_SLOW=1`): the first run failed on Credo (nesting depth of the test helper `await_lock_free/2`); the helper's predicate became `lock_free?/1`, a test-only change, and the second run passed.
