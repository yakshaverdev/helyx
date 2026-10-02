# Review: precommit in 20 to 25 s (#295)

Date: 2026-10-02. Base: `origin/master` at `4661e13`. Scope: the root `mix.exs`, `plugins/bundled/mix.exs`, `apps/coding_agent/mix.exs`, the three `test_helper.exs` files, the split test modules and their support modules, `precommit.sh`, the orchestrate skill, and `AGENTS.md`.

## Invariant

The root `precommit` alias runs the root and every `plugins/*` and `apps/*` project in parallel. Each project runs `deps.get --check-locked`, format, and compile, then Dialyzer and test in parallel, and the root also runs Credo. Each step prints its output below a line that names the project and the step, and the run fails with the names of the failed steps. Tests tagged `:slow` run only with `HELYX_SLOW=1`, which `/ship` and the merge gate of `/orchestrate` set. No production code changes. The split test modules keep every test of the deleted modules.

Deviations from the ticket:

- Change 1: a PATH dispatcher in the bundled `test_helper.exs` replaces a program path option in `HarnessIO.find/1`. It meets the goal (async provider tests, one small sync module for PATH) with no production change.
- Change 5: `max_cases` at 10, 20, and 40 gave no gain, so it is not changed.
- Change 7: no Core API that a slow test calls has a timeout argument. Those tests have the `:slow` tag, and no test-only option was added.

Accepted holes:

- A test with a fixed wait can fail under heavy load, because the tests share the CPU with Dialyzer and Credo. See the devlog for the failures seen.
- A `kill` of the parent `mix precommit` process leaves running child steps. Ctrl-C and the remote host stop the whole process group.
- Two worktrees that run Dialyzer on one project on a machine with no core PLT can write that project's core PLT in the Mix home at the same time. On master all projects of all worktrees shared one core PLT, so the hole is not new. It opens after an OTP or Elixir upgrade, and once after this change until a run fills the new folders. Dialyxir reads the core PLT only when it builds a project PLT. The local folders were filled before the merge; on the precommit host they fill at the first run that builds a project PLT.
- Root Credo can read a plugin file while the format step of that plugin writes it. On master, Credo also read plugin files before their format step, so this is not new.

## Round 1 (full)

Bounds sensor: `bounds sensor: 0 candidate functions, 0 flagged, 0 without an answer` (no `lib/` code changed).

Simplify (4 agents). Fixed: `replied?/1` moved to `Helyx.Test.HarnessDriver`, `messages/1` and `of_type/2` to `Helyx.Test.Events`; `count_z/1` is private to its one test; the steps carry their own `nice`; printing and the failure list are separate; the Dialyzer path dependencies come from `deps()`; `loop_test.exs` uses `start_core/1`; a stale `AGENTS.md` sentence about a forced PLT check is removed; `preferred_envs` is removed. Skipped: one `perl` per fake run (the fake is moved code, and the gain is CPU, not the critical path); one Dialyzer analysis of `helyx` in place of three (a PLT for path dependencies is more machinery; the bundled step also checks its `test/support`); `vm_kill_test.exs` async (0.4 s); fail-fast (failure path only); the slow tier in `/ship` (a decision for the owner: after the review, the owner chose to run it in `/ship`); the differing helper names of the two fakes (moved code).

| Axis | Findings | Reproduced defects | Resolution |
|----|----|----|----|
| Standards | 0 hard, 1 probable (no feature doc), 2 standards judgement calls, 6 smells | 0 | The `MIX_EXS` comment is at its line. The `fresh` thread-id macro of `CodexFake` is `fresh_tid`, because `fresh/5` sets up a run. No feature doc: a tooling ticket has none (#294, the `chore(ship)` changes), and the ticket holds the design; the devlog and this record hold the deviations. Not changed: `start_core/1` with two clauses (the ExUnit setup form); the `HELYX_SLOW` rule in five files (separate Mix projects and a shell script). |
| Spec | 0 missing, 2 partial, 4 scope notes | 0 | A hung step left the log empty: each step now prints when it ends. Two runs in one checkout could truncate a dispatcher script: it is written only when its content changes. The flakes under load are an accepted hole. |
| Failure path | 2 | 2 | The same two defects as the spec axis, reproduced: an empty log after 40 s with one step that does not end, and 44 of 799 dispatcher runs with empty output during a rewrite. Both fixed. Not reached: the shared core PLT, a format during a compile, the property tier. |
| Codex adversarial | 1 medium | 1 (by source) | The three Dialyzer runs shared the core PLT files in the Mix home, which Dialyxir writes with no lock. Each project now has its own core PLT folder, so the core PLT builds once for each machine and project, not for each worktree. |

Round 1 reproduced defects. The fix changes four code files, so round 2 is a full round.

## Round 2 (full)

Base: the tree after the simplify fixes of round 1. Fix count without tests and Markdown: 4 code files (`mix.exs`, `plugins/bundled/mix.exs`, `apps/coding_agent/mix.exs`, `plugins/bundled/test/test_helper.exs`), so a full round. The briefs named the three restored invariants: no two Dialyzer runs of one precommit write one core PLT; a step that hangs does not hide the output of the others; a test run never runs a part of a dispatcher script.

Bounds sensor: `bounds sensor: 0 candidate functions, 0 flagged, 0 without an answer`.

Simplify (4 agents). Fixed: the dispatcher writes a temporary file and renames it, which also covers a change of the script content. Skipped: one shared core PLT with a serial `mix dialyzer --plt` before the fan-out (a serial step on every run); a core PLT in each `_build` (see round 2 failure path).

| Axis | Findings | Reproduced defects | Resolution |
|----|----|----|----|
| Standards | 1 hard, 3 judgement calls | 0 | Hard: the race between worktrees on one core PLT was not stated as a hole. It is now stated here and in the devlog. Not changed: the `plt_core_path` line in three `mix.exs` files (separate Mix projects); the root literal `"dialyxir/helyx"` (the root has no `dialyzer_paths/1`); a temporary file left in `_build` when a run stops between the write and the rename. |
| Spec | 2 partial, 1 wrong, 1 scope note | 0 | The temporary name used the OS pid, which repeats across the pid namespaces of the precommit host: it is now random. `AGENTS.md` says that a new project sets its own `plt_core_path`. The first run after this change builds three core PLTs: stated in the devlog. A raise of `System.cmd` does not name its project: older than this change, `mix` is always on PATH. |
| Failure path | 1 | 0 new | Two worktrees with no PLT built `dialyxir/helyx` at the same moment. This is the stated hole. Its new part, the empty folders after the merge, is closed locally: one run with no project PLTs filled them. On the precommit host it stays open until a first run fills them. The two files that the probe built at the same time were removed, so one run builds them again. Invariant 2 held in a probe; invariant 3 needed no probe. |
| Codex adversarial | 0 | 0 | Approve. A probe showed the output of a step that ended while another step was blocked. |

Round 2 reproduced no new defect, so the loop ends.

## Round 3 (reduced)

After round 2, the owner chose to run the slow tier in `/ship`, and the first `HELYX_SLOW=1` run of `/ship` failed two tests (see the devlog). Fix count without tests and Markdown: 1 code file (`precommit.sh`), 6 lines, no function. So a reduced round: the spec and failure-path agents. The briefs named the invariant: a test counts only its own work and passes under the parallel precommit load, and `/ship` passes only 0 or 1 as `HELYX_SLOW` to the remote shell.

Bounds sensor: `bounds sensor: 0 candidate functions, 0 flagged, 0 without an answer`.

| Axis | Findings | Reproduced defects | Resolution |
|----|----|----|----|
| Spec | 2 partial, 1 scope note, 1 stale comment | 0 | Two waits had no stated margin: the 200 ms `:DOWN` wait in `claude_code/limits_test.exs`, now async, is `@load_down_ms`; the grace test in `watchdog_test.exs` checked at 800 ms of a 1 s grace and is now a 2 s grace in `@load_grace_ms`, checked at 1 s, with 3 s for the KILL. The two `test_helper.exs` comments name `/ship`. Scope: the ticket asks for the slow tier at the merge gate only; the owner chose `/ship` too, so an orchestrated ticket runs it twice. No other test counts calls for the whole VM. |
| Failure path | 1 | 1 | `loop_test.exs`, the test of an integer over the digit limit, made its folder in the shared OS temp folder with `System.unique_integer/1`, which repeats across runs. A folder that a killed run left made `[path] = Path.wildcard(...)` fail, and its `on_exit` could delete the folder of another run. Reproduced with planted folders. The test came from `session_test.exs` on master. It now uses `@tag :tmp_dir`. Held: the `HELYX_SLOW` pass-through, the trace test (5 runs next to `tui/`), the margins of the slow tests. Not reached: the 250 to 400 ms `@load_ms` margins of `sweep_test`, `group_test`, and `wall_clock_upper_bound_test` under the parallel load (a probe needs a load generator). |

Round 3 reproduced a defect. The fix is two lines in one test file, older than this change. By the loop rule, nothing more is committed without the owner. The gate passed after the fix: `HELYX_SLOW=1 precommit.sh` in 40 s, with 394, 499, and 17 tests and no failure. The log has teardown lines from tests that are not changed: a `Helyx.Provider.Fake` stream task that ran when its test stopped the core, and a killed `Hands` server in `tui_test.exs`.

## Round 4 (full)

The owner then ordered: "Don't commit if the tests are flaky. Make it correct, speed can come later. Fix that, then commit to master." This is the owner's decision past the loop cap. The pass makes every test wait safe under the parallel load: one cap of 30 s for every wait that must happen (`Helyx.Test.Events.wait_ms/0`), order through `Helyx.Test.Gate` or a stated `@load_` margin for every wait that must not happen. The briefs named the invariant: each changed test passes under the parallel precommit load, and still fails on the bug it names.

Bounds sensor: `bounds sensor: 0 candidate functions, 0 flagged, 0 without an answer`.

Simplify (4 agents). Fixed: the dead `%{"slow" => ms}` clause of the hold release in `test/support/interfaces.ex` (it also put the function over the Credo complexity limit); `wait_free` in `harness_test.exs` is now `Helyx.Test.SessionCase.stop_session/2`. Skipped: the cap comment in three `test_helper.exs` files (three Mix projects); one poll helper for five poll loops.

| Axis | Findings | Reproduced defects | Resolution |
|----|----|----|----|
| Standards | 1 hard, 9 judgement calls | 1 (the hard one) | Hard: `sweep_test.exs` did not assert the `set_model` result, so a call that waited for the sweep passed. Every call must now answer. The idle test has `@idle_ms` apart from `@load_idle_ms`. Not changed: `Gate.wait/1` has no cap (the test exit ends it); `apps/coding_agent` does not exclude `:slow` (it has no such test); the literal `refute_receive` windows (an accepted hole); two ways to send a gate name; the place of `wait_ms/0`. |
| Spec | 5 wrong, 3 partial | 3 | The 30 s `gone_within?` cap equalled the `sleep 30` of the test programs: now a 10 s deadline. The `set_model` result: as in Standards. "no wait passes the deadline" in `group_test.exs` passed with a grace that ignored the deadline: now a 10 s grace. Seven `Task.await/1` calls with the 5 s default now use the cap. The prepare bound of 200 ms in `harness_test.exs` is now `@load_prepare_ms` 2,000, `:slow`. Not changed: `loop_test.exs` waits 3 s for an event that takes milliseconds, against 5.8 s for the bug; "with one deadline" left the name of the parallel release test, because two releases that start together share their deadline; the PATH dispatcher in place of a `HarnessIO.find/1` option (see the devlog). |
| Failure path | 2 | 2 | The `set_model` result and the grace of `group_test.exs`, as above. Held: the gate of the parallel release, the retry bound of `hands_test.exs`, `@load_down_ms`, the steer and idle timers, the 5,500 ms refute of `end_signal_test.exs`. |
| Codex adversarial | 2 | 2 | The `gone_within?` cap, as above. The order test of `harness_tools_test.exs` selected `c1` from the mailbox: it now takes the results in their order. |

Probes after the fixes: a watchdog with no KILL fails "a command that ignores TERM is killed after the grace period"; a `set_model` that blocks during a sweep fails the abort sweep test. The full local run with the slow tier then failed "a longer grace holds the KILL until its limit": its check at 1 s ran after the end of the 2 s grace. The grace is now 10 s (see the devlog).

The gate is 10 fast and 3 `HELYX_SLOW=1` runs of `precommit.sh` on the precommit host, every log kept.

## Round 5 (the watch)

The acceptance after round 4 failed once in 13 runs: the TUI test "a lost subscription rebuilds the view from a new snapshot" got `{:error, :session_not_found}` after the lost signal. The cause is a production race older than this ticket. `Helyx.Session.Watch` sent the lost signal after an answer of the Registry supervisor, and assumed that the supervisor had the exit of the partition before the call of the watch. Signals from two processes have no order. The watch now checks the partition pid (`docs/features/end-signal.md`, "The watch"). The owner's order ("Don't commit if the tests are flaky") covers this fix: it is the cause of a failing test.

New tests in `end_signal_test.exs`: "the lost signal waits for a new partition, not for an answer of the supervisor" sends the exit to the watch while the partition still runs, and fails on the old watch; "a stopped events Registry gives the lost signal at once".

| Axis | Findings | Reproduced defects | Resolution |
|----|----|----|----|
| Failure path | 3 | 2 | The first loop had no pause and no end when a product stops the Registry (`terminate_child`): one scheduler at full use, forever, also after the subscriber ended. A deleted partition child crashed the watch with a `MatchError`, with no signal. Now: a 10 ms pause, a stop with no signal on the `:DOWN` of the subscriber, and the lost signal at once when the child is `:undefined` or gone, in the Registry or in the Core. Held: the two restart tests with `:sys.suspend`, and the test that counts the queued messages of the supervisor. |
| Codex adversarial | 1 | 1 | A new partition that died before the watch read the answer passed the pid check. The check now also asks `Process.alive?/1`. A crash after the last check is the accepted case "a subscribe while the Registry restarts", now named in the doc. No regression test: it needs the watch suspended with a queued reply, and the window stays after any check. |

Second Codex pass on the final loop: 1 finding, 0 defects. While a supervisor call blocks (a suspended supervisor), the watch does not see the `:DOWN` of the subscriber, and after the answer it sends the lost signal to the dead subscriber. The old watch did the same, and a send to a dead process does nothing; the watch then stops. Not changed; the doc now says it. The loop ends here: the round reproduced no new defect.
