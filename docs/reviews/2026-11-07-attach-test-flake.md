# Review: the flake of attach_test.exs:298

Base: `610a8d41` (merge base). No ticket: the owner asked for it in chat on 2026-11-07. Change: the test "a server of this VM that stops during the wait gives a line" in `apps/coding_agent/test/coding_agent/attach_test.exs`. No `lib/` code changes.

## Cause

The test waited only until `CodingAgent.Serve` registered, then suspended the client. Registration is the first step of the server. If the test process ran late, the server finished its start, and the client attached in that time. The fun `& &1` of the client then returned, and `Attach.serve/3` called `Serve.stop/1`, which runs `Task.Supervisor.terminate_child/2`. The server stops in order (`shutdown: :infinity`), so it stayed registered while it stopped. The `Process.whereis(Serve)` of the test still found it. The `terminate_child` of the test waited in the supervisor's queue behind the client's call, then got `{:error, :not_found}`, because `DynamicSupervisor` had deleted the child by then. A `nil` from `whereis` would raise `FunctionClauseError`, not this `MatchError`. Only `serve/1` registers the name, always under `CodingAgent.Servers`, so the found pid could not be of another instance. The cause is in the test. The production code works as documented: `Attach.serve/3` stops its server when `fun` returns.

## Fix

The test makes the data folder and holds its lock before it starts the client, and releases the lock only after it suspends the client. While the test holds the lock, the server cannot take the lock, so it cannot write `server.json`. Without that file the client cannot attach. So the client is held before its first welcome, and nothing other than the test stops the server. The assertions are unchanged.

## Deterministic reproduction

The throwaway file `apps/coding_agent/.scratch/attach-race/attach_race_test.exs` (not committed) holds the window between the wait and the suspend open, using events only:

- "before" runs the old lines 295-298. The fun of the client tells the test that it was called, then waits for `:go`. The test waits for that message, which means the client attached. A helper process suspends the server. The test lets the client go into `Serve.stop/1`, and waits until the supervisor is in `DynamicSupervisor.wait_children/4`. A second helper resumes the server once the `terminate_child` call of the test is in the supervisor's mailbox. Result, in 6 of 6 runs: `(MatchError) no match of right hand side value: {:error, :not_found}` at the old `terminate_child` line.
- "after" runs the new lines. The test is late at the same point until the client has read the server file three more times (a call trace on `Serve.read_file/1`). The client did not attach (`three reads, server file there: false`), and the test passes, in 6 of 6 runs.

With the final form of the fix: the changed module gave `17 tests, 0 failures (2 excluded)` in 4 runs, and the changed test alone gave `1 test, 0 failures (18 excluded)` in 10 runs.

Bounds sensor, round 1: `bounds sensor: 0 candidate functions, 0 flagged, 0 without an answer`.

## Round 1 (full: simplify, standards, spec, failure path, Codex)

Simplify: moved the comment to the line of the lock, and removed a captured server pid. The client is suspended, so `Process.whereis(Serve)` names the same server, as in the other tests.

| # | Axis | Finding | Reproduced | Resolution |
|---|---|---|---|---|
| 1 | Codex | Approve, no material findings | n/a | None |
| 2 | Failure path, spec | The test still fails after a stall of `Serve.wait_ms/0` (5,000 ms). The server gives up its wait for the lock if the test is 5,100 ms late before the release; `whereis` is then `nil`, and the test fails with `FunctionClauseError`. The client returns the line of its wait if the test is 5,100 ms late before `terminate_child`. The old test had the client's window too | yes, by an injected delay of 5,100 ms | Not a defect: this is the wait of the product under test, and every test of the module that starts a server depends on it. The checklist says a race is closed structurally or stated as a hole, and the test cannot close a production deadline. So the comment now states it as the margin for load. With the old test, a delay of 300 ms was enough to fail it |
| 3 | Standards | Unclear wording: "a client that attached would stop the server itself" | n/a | Fixed: "so the client cannot attach and stop the server first" |
| 4 | Standards | Duplicated code: `data_folder`, `hold_lock` and `Lock.release` now appear in six tests | n/a | Kept, as the reviewer advises: here the release must come between the suspend and the stop, so a helper would not fit |
| 5 | Spec | The reproduction is two tests, not one body run against both versions. "before" changes the fun of the client to hold it | n/a | Accepted. With the fix, no hold can make the client attach, so one hold cannot end the same way in both versions. The fun is test code, and holding it only delays the client between its attach and its stop, which is a real interleaving |
| 6 | Standards | Outside the diff: `terminate_child` finds the server by its name | n/a | Safe while the client is suspended: only one server runs in the VM, and nothing else stops it. Not changed |

The round reproduced no defect, so the loop ends. The comment edits of findings 2 and 3 get no further round.
