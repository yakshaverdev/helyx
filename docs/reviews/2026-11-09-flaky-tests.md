# Review: four flaky tests

No ticket: the owner asked for it in chat on 2026-11-09 (fast mode: one review round, the Codex review and the failure-path agent). Each test failed under load on the precommit host and passed on rerun. Each cause is shown by a throwaway test that holds the window of the race by events. The old body fails there with the error seen on the host, and the new body passes, in 3 of 3 runs each. No production code changes.

| Test | Error on the host | Cause | Fix |
|---|---|---|---|
| `Helyx.Provider.Codex.PromptTest`, "a compaction of a stored thread opens it with the empty prompt" | `** (EXIT from #PID<…>) :epipe` (3 failed logs) | The answer of `thread/resume` was taken after the close. The provider then wrote `thread/compact/start` to a port whose watchdog had ended at the close, and the port closed with `:epipe`, which ends its owner, the test process (#390). | `settle` until the thread is open, then the close |
| `Helyx.Watchdog.GroupTest`, "a group that stays to the deadline does not keep the handles of gone groups" | all six handles held (3 logs) | The test process was late past the 300 ms deadline before the first probe. A skipped probe keeps its group held, by design. | When not every first probe ran, the run proves nothing and runs again with twice the room, up to `@load_ms` (2,000 ms) |
| `Helyx.Tool.BashTest`, "a start that did not start the command leaves no held handle (#802)" | `[watchdog: N]` held (6 logs) | The caller was late past the 100 ms release deadline of a failed start, so the probe was skipped, and the documented fallback kept the hold for the hands (`docs/features/tool-resource-release.md`, #802). | A return trace of `Helyx.Watchdog.Group.release/4` gives what the release confirmed: the hold must equal its return, and a returned watchdog must be gone |
| `hooks_test.exs:741`, "the hands send the answer of a hook killed while it asks with its pid, before the next record" | `assert_receive {:asking, hook}` timed out | A hook arms its limit first and then waits for the session's go, so the wait counts against the 100 ms limit (`docs/features/hooks.md`). Under load the hook was killed before its script ran. | See below |

**The hook tests that share the cause.** Every test of `Hook.Short` and `Hook.SettleShort` that needs the hook to reach its script before the kill has the same race. That includes "a hook killed at its limit gets a cancel release", which failed in a precommit of this branch on 2026-11-08.
- **No limit needed.** "the end of the hook Task ends its ask" and the test at :741 need a hook killed while it asks. The test kills the hook itself once it has asked. `deliver/3` in `lib/helyx/session/hands/hooks.ex` handles a crash and a limit kill alike for the ask end and the answer order; only the release mode and the text differ. The ask-end test now checks that the hook failed, not the text of the failure.
- **The limit is the subject.** "a hook killed at its limit gets a cancel release", "the limit holds while the hands are busy", and before_settle "a hook past its limit fails…" use a hook with the 2,000 ms limit (the margin for load) and are `@tag :slow`.
- **Removed:** `Hook.SettleShort`. `Hook.Short` stays for "a hook past its limit fails closed", which needs no script.

**The reproductions:**
- **Codex:** a helper stopped `erl_child_setup`, so the VM did not see the watchdog's exit until the test resumed it. That held the port open across the close.
- **Group:** a delay of 310 ms between the deadline and the call.
- **Bash:** a copy of `Helyx.Watchdog`, compiled in the test VM, that sleeps 150 ms between the deadline and the release.
- **Hooks:** the test held the call Task in a `before_tool` hook, suspended the session, let the call Task go on, and waited, by a monitor, for the kill of the `after_tool` hook while its go could not come.

## Review round

| # | Reviewer | Finding | Reproduced | Resolution |
|---|---|---|---|---|
| 1 | Codex, failure path | The first fix of the #802 test chose the strict assertion by the wall time of the whole start. A slow start with an on-time release then passed with the #802 bug (no `unhold`). | yes: a copy of `Helyx.Watchdog` without the `unhold` and with a 120 ms delay before the release passed 10 of 10 | Fixed: the return trace of the release decides. The same copy now fails, 3 of 3: `release returned []`, `[watchdog: N]` held |
| 2 | Failure path | The ask-end test checked `text =~ "it crashed"`, but a kill 2,000 ms or more after the start counts as a limit kill | yes, with a 2,100 ms delay before the kill | Fixed: the test checks that the hook failed |
| 3 | Failure path (not reproduced) | In `limit/2`, `started_ms` is taken in the hands after the Task starts, and the Task arms its kill first. A limit kill can look like a crash by a few ms, and get `:deliver`. | no | Outside this change. Recorded here for a later ticket; the slow cancel-release test could meet it |

While fixing finding 1, `:erlang.trace_pattern/3` returned 0 in a run where `Helyx.Watchdog.Group` was not loaded yet. The test loads it first with `Code.ensure_loaded!/1`.

The changed files passed: root, with `HELYX_SLOW=1`, `48 tests, 0 failures`; `plugins/bundled`, without the slow tests, `55 tests, 0 failures (12 excluded)`.

## Precommit

The precommit at the end of the branch failed on one Credo warning, `Helyx.Credo.WallClockUpperBound` at `group_test.exs:122`. The check counts `release_probed/2` as a time function, since it calls `deadline/1`, and so it read the `==` on its result, a list of handles, as an upper bound on time. The assertion is now a pattern match, `assert [command: 7] = release_probed(handles, 300)`, which is as strict for a list literal. The second run passed.
