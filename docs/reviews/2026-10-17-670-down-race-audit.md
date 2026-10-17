# 2026-10-17: audit of the steps after `assert_receive {:DOWN, ...}` (#670)

Scope: every `assert_receive {:DOWN, ...}` in the root, `plugins/bundled`, and `apps/*` tests and test support (`apps/coding_agent` has none). One exit gives a `:DOWN` to each monitor and an exit signal to each link, with no order between the receivers (AGENTS.md, #605). A site is racy when the step after it needs a message or a cleanup that another receiver of the same exit owns.

Facts that decide many sites:

- **Registry.** `Helyx.Session.pid/1` (`GenServer.whereis/1` through the Registry) and the register of a start check `Process.alive?/1` for a unique key (Elixir 1.19 `registry.ex`, `whereis_name/2` and `register_key/4`). A step that looks up or registers a session id does not need the Registry to have handled the exit.
- **Lock after a normal stop.** `GenServer.stop/1` returns after `terminate/2`, which releases the lock and waits for perl's exit, but only up to the release bound of 1000 ms (`Helyx.Session.Lock.release_ms/0`; `docs/features/session-lock.md`, row "owner stops normally"). Past the bound, perl holds the lock after the stop returns (`lock_test.exs`, "a stop past the release bound returns"). So a step after a normal stop that opens the same file again needs the lock that perl frees, and waits for it (corrected by the merge gate, see "Merge gate").
- **Lock after a kill.** perl exits after the port closes, with no order to any `:DOWN`. Both sites that kill a session and take its lock again poll for the free lock.
- **The session's wait.** After an idle close or a close of a switch, the session holds every client message until the hands' `:provider_down` (`Helyx.Session.Server.Wait`). A prompt in that window cannot reach the ended process.
- **A suspended session that is resumed** handles its mailbox in order. If the session's own `:DOWN` of its provider process is not in the mailbox at the resume, it can end the turn, start the queued follow-up, and send `{:turn, ...}` to the ended process before its `:DOWN` comes (the race of #620).

## Sites

Line numbers are of `aabf8050`, before this change.

| Site | Step after the `:DOWN` | Decision |
| ---- | ---------------------- | -------- |
| `test/support/session_case.ex:67` `stop_session/2` | polls the Registry; callers then resume or check the lock | **Racy past the release bound, fixed**: it now waits until the lock of the file is free (`Helyx.Test.SessionFile.await_lock_free/2`), after a normal stop and after a kill. Registry: liveness checks |
| `test/support/shared/late_client.ex:45` `disconnect/1` | callers send `:go` to a stream or end | Safe: the session sends to a dead subscriber at worst, which is a no-op; no step reads its subscribers |
| `test/helyx/provider/loop_test.exs:273` | `pump/2` reads the test's own mailbox | Safe: the test process is the only monitor of the model Task |
| `test/helyx/provider/loop_test.exs:305` | collects the events of the session | Safe: reads the test's own mailbox with a bounded wait; the test sends nothing after |
| `test/helyx/session/persistence_test.exs:181` | resumes the supervisor, polls its memory | Safe: polls the state it needs |
| `test/helyx/session/instance_test.exs:45` | `Session.resume/2` | Safe for the `:DOWN`: it is the test's subscription. The lock: `stop_session/2` before it now waits for the free lock (merge gate) |
| `test/helyx/session/hands_test.exs:142` | none | Safe |
| `test/helyx/session/file/scan_test.exs:150` | none | Safe |
| `test/helyx/session/file_test.exs:811`, `:873` | asserts on the reason of the same `:DOWN` | Safe |
| `test/helyx/session/background_delivery_test.exs:309` | resumes the suspended session, which ends the turn and starts the follow-up | **Racy, fixed**: waits for the session's `:DOWN` of `old` in its mailbox (`await_down/3`) before the resume |
| `test/helyx/session/provider_process_test.exs:71` `stop_seen/2` | polls the session state | Safe: waits for `:ending` already (#620) |
| `test/helyx/session/provider_process_test.exs:150`, `:162`, `:163`, `:195`, `:196`, `:1163`, `:1164`, `:1191`, `:1313`, `:1416`, `:1417`, `:1438`, `:1439` | none, or another `:DOWN` of the test | Safe |
| `test/helyx/session/provider_process_test.exs:207` | collects events; the prompt was sent before | Safe: the switch close wait holds the prompt |
| `test/helyx/session/provider_process_test.exs:224`, `:241` | resumes the hands and the session, collects events | Safe: the test sends nothing after; the session ends the turn when its `:DOWN` comes, in any order |
| `test/helyx/session/provider_process_test.exs:459` | waits for the session state, then continues the prepare Task | Safe: fixed by #620 |
| `test/helyx/session/provider_process_test.exs:488` | resumes the suspended session, which starts the queued follow-up | **Racy, fixed**: `await_down/3` before the resume |
| `test/helyx/session/provider_process_test.exs:586` | resumes the suspended session, collects events | Safe: the test sends nothing after; the turn ends with the error in any order |
| `test/helyx/session/provider_process_test.exs:867` | collects events | Safe |
| `test/helyx/session/provider_process_test.exs:887` | resumes the suspended session, which starts the follow-up | **Racy, fixed**: `await_down/3` before the resume |
| `test/helyx/session/provider_process_test.exs:1079` | `Session.prompt/2` of the next turn on the same provider process | Safe for the `:DOWN`: the killed process is the prepare Task of the ended turn; the session's `:DOWN` of it matches no later turn (`TurnLoop.handle/2` drops it). Fixed beside it: the `refute_received` of a context of the first turn ran before the context of the next turn from the same sender, so it could pass with no proof (#592); it now runs after that context |
| `test/helyx/session/provider_process_test.exs:1326` | `turn/2` of the next prompt | Safe: the idle close wait holds the prompt until the hands' `:provider_down` |
| `test/helyx/session/provider_process_test.exs:1450` | collects events; the prompt was sent before | Safe: the idle close wait holds the prompt |
| `test/helyx/session/provider_process_tools_test.exs:100` | none | Safe |
| `test/helyx/session/lock_test.exs:209` `park_resume_and_kill_caller/2` | callers kill the supervisor, or resume it and poll | Safe: the parked start request reaches no session before the caller died; a session that starts after monitors a dead caller and gets `:noproc` at once |
| `test/helyx/session/lock_test.exs:220` | lists the folder | Safe: the supervisor died with the start request in its mailbox, so no session runs |
| `test/helyx/session/lock_test.exs:291`, `:314` | none, or polls the lock | Safe |
| `test/helyx/session/lock_test.exs:301` | sends `:go` to the session | Fixed by #605; now uses `await_down/3` |
| `test/helyx/session/end_signal_test.exs:57` | operations on the dead registered session | Safe: the Registry partitions are suspended on purpose; the operations meet a dead pid |
| `test/helyx/session/end_signal_test.exs:93`, `:171` | reads the test's mailbox | Safe: the events and the `:DOWN` come from one sender |
| `test/helyx/session/loop_test.exs:285`, `:301`, `:331`, `:332` | none | Safe |
| `test/helyx/session/sweep_test.exs:162` | `refute_received` of a session event, `Task.await/2` | Safe: one sender; the abort Task gets its own reply |
| `plugins/bundled/test/helyx/tui/switch_test.exs:55` `saved/4` | callers resume or switch to the session | **Racy past the release bound, fixed**: the stop is `Helyx.Test.SessionFile.stop/1`, which waits for the free lock. Registry: liveness checks |
| `plugins/bundled/test/helyx/tui/switch_test.exs:363` | starts a new session | Safe: a new id, no shared state with the ended Task |
| `plugins/bundled/test/helyx/tui/switch_test.exs:389` | passes the `:DOWN` to the TUI function | Safe: the test is the receiver |
| `plugins/bundled/test/helyx/model_info/catalog_test.exs:71` | none | Safe |
| `plugins/bundled/test/helyx/provider/claude_code/limits_test.exs:246`, `plugins/bundled/test/helyx/provider/harness_epipe_test.exs:119`, `plugins/bundled/test/helyx/watchdog/harness_stop_test.exs:50`, `:60`, `plugins/bundled/test/helyx/tool/bash_test.exs:220` | polls the OS for the program group or pid | Safe: polls the state it needs |
| `plugins/bundled/test/helyx/tui_test.exs:401`, `:410` | passes the `:DOWN` to the TUI function | Safe |
| `plugins/bundled/test/helyx/tui_test.exs:446` | resumes the caller of `run/1` | Safe: `Helyx.TUI.Start.run/1` blocks on the `:EXIT` over the link when the TUI is gone |
| `plugins/bundled/test/helyx/tui_test.exs:512` | `Session.pid/1`, `TUI.mount/1` | Safe: Registry checks liveness |

Three sites need the same wait, and `lock_test.exs:301` had it inline, so the wait is one helper, `Helyx.Test.SessionCase.await_down/3` (the ticket allows a helper at three sites).

## Simplify

Four agents (reuse, simplification, efficiency, altitude). Applied: at the three fixed sites, the test's own monitor of `old` and its `assert_receive {:DOWN, ...}` went, because `await_down/3` already proves that `old` ended. Skipped: a `what` text built from the pids (`await_down/2`), because the text of a timeout reads better; and the removal of the comment at each fixed site, because AGENTS.md puts the reason for an order at the line that needs it.

## Round 1 (full)

Bounds sensor (base `origin/master`), as it printed:

```text
bounds sensor: 0 candidate functions, 0 flagged, 0 without an answer
```

| # | Axis | Finding | Resolution |
| - | ---- | ------- | ---------- |
| 1 | Spec | `loop_test.exs:305` (`assert_receive({:DOWN, ...})` with parentheses) was not in the table | Added; Safe. A grep for the form with parentheses finds no other site |
| 2 | Spec | The move of the `refute_received` at `provider_process_test.exs:1086` is a #592 fix, not a `:DOWN` race | Kept: one line at a site that the ticket names, and the check had no proof before |
| 3 | Standards | The name `await_down/3` reads as "wait until `pid` is down" | Not changed: judgement; the comment of the helper and its `what` text say whose mailbox it reads |
| 4 | Standards | The comment above the moved `refute_received` read as if a context of the first turn is sent | Reworded: "would come before" |
| 5 | Standards | The repeated comment at the three fixed sites | Kept: AGENTS.md puts the reason for an order at the line that needs it |
| 6 | Failure path | No defect reproduced. `await_down/3` sees the `:DOWN` in the mailbox of a suspended process (probe); the five changed tests passed 21 runs with `--repeat-until-failure 20`. If the watched process dies during the wait, the helper crashes with a `MatchError` in place of the timeout text, as the inline form of #605 did | No change: the test fails either way |
| 7 | Codex | Approve, no material findings | none |

The round reproduced no defect, so the loop ends. The changes after it are wording only (a comment and this record).

Precommit (`HELYX_SLOW=1`): passed on the first run (root 593 tests, `apps/coding_agent` 77, `plugins/bundled` 782 and 2 properties, 0 failures; Credo and Dialyzer clean).

## Merge gate

| # | Finding | Resolution |
| - | ------- | ---------- |
| 1 | [medium, Codex, confirmed by the orchestrator] The record called the callers of `stop_session/2` and the TUI `saved/4` safe because a normal stop frees the lock. `Lock.release/1` returns after 1000 ms with perl still holding the flock, so a resume right after a normal stop can get `{:session_locked, id}` on a loaded machine | Fixed. The one form of the wait is now `Helyx.Test.SessionFile.await_lock_free/2` in `test/support/shared`, which the root, `plugins/bundled`, and `apps/coding_agent` all compile; `lock_test.exs` lost its private copy. `Helyx.Test.SessionFile.stop/1` stops a session normally and then waits for it. The production release bound is unchanged |

Sites of the fix (line numbers of `60188802`). Each one opens the file of a session again, or takes its lock, after the session or its Core stopped:

| Site | Change |
| ---- | ------ |
| `test/support/session_case.ex` `stop_session/2`: its callers in `persistence_test`, `instance_test`, `background_delivery_test`, `lock_test`, `end_signal_test`, `boundary_test`, `message_identity_test` | waits for the free lock when the session had a file |
| `test/helyx/session/lock_test.exs:98`, `test/helyx/session/persistence_test.exs:302` (kill) | the resume poll went: `stop_session/2` waits for the free lock |
| `test/helyx/session/compaction_test.exs:216`, `:246` | `SessionFile.stop/1` |
| `plugins/bundled/test/helyx/tui/switch_test.exs:54` | `SessionFile.stop/1` |
| `plugins/bundled/test/helyx/provider/codex/turns_test.exs:115`, `:145` | `SessionFile.stop/1` |
| `plugins/bundled/test/helyx/provider/claude_code/turn_test.exs:127`, `:145`, `:190`; `compact_test.exs:110`, `:142`, `:184`; `meter_test.exs:462`, `:515`, `:553` | `SessionFile.stop/1` |
| `apps/coding_agent/test/coding_agent_test.exs:55` | `SessionFile.stop/1` |
| `apps/coding_agent/test/coding_agent/print_test.exs:692` | `SessionFile.stop/1`; the poll for a gone pid went (the stop returns after the exit, and the Registry checks liveness) |
| `apps/coding_agent/test/coding_agent/print_test.exs:231` (two resumes after a print run), `:272` (a lock take after a print run) | `await_lock_free/2` before each: the run stops its Core, and perl frees the lock after the stop |

Left as they are:

- `lock_test.exs` "a normal stop frees the lock before it returns" resumes right after `GenServer.stop/1`. It tests the release wait itself, the guarantee of session-lock.md, and a wait would remove its claim. Accepted ceiling: it fails when perl needs more than 1000 ms to exit after its byte.
- `lock_test.exs` "a resume that fails after the lock frees it" takes the lock right after the failed resume. It tests that the error branch of `Lock.hold/2` releases the lock, with the same bound and the same accepted ceiling.
- `boundary_test.exs:85`, `:180`: the resumes fail at the tool spec check, before the lock.
- `print_test.exs:295`: the renamed file is skipped, so the resume takes no lock.
- The other direct stops (`provider_process_test`, `end_signal_test`, the codex and claude_code `helyx_tools_test`, `claude_code/turn_test.exs:70`, `bash_test`, `tui_test.exs:527`, `claude_code_real_test`, `print_test.exs:730`, `switch_test.exs:216`, `:416`) open no file of the stopped session after the stop.

The fix is 104 changed lines of test code, without this record; the wider scope (16 direct stops and the print runs, beyond the callers that the finding names) was reported before the reduced round.

### Reduced round (spec, failure path)

The fix counts as test code only, so the round is reduced, as the orchestrator set.

| # | Axis | Finding | Resolution |
| - | ---- | ------- | ---------- |
| 1 | Failure path, spec | `plugins/bundled/test/helyx/tui_test.exs:463` stops the session with `DynamicSupervisor.terminate_child/2` and resumes it at once. Reproduced: with perl held by `kill -STOP`, the resume gave `{:error, {:session_locked, id}}` on the first run | Fixed: `await_lock_free/2` on the file before the resume; the supervisor shutdown stays, as the test shows a resume after it |
| 2 | Spec | The probe of `await_lock_free/2` released its own lock with `Lock.release/1`, which waits for perl only up to 1000 ms, so the wait could return while the probe's perl still held the lock (from the code; not run) | Fixed: the probe sends the byte and waits for its own perl's `exit_status` within `Events.wait_ms/0` |
| 3 | Spec | `lock_test.exs` "a resume that fails after the lock frees it" was in no list | Added to "Left as they are", with the accepted ceiling |
| 4 | Spec | The line count of the fix included no note that the record is left out | Reworded |
| 5 | Failure path | `SessionFile.stop/1` and `stop_session/2` hold: with perl stopped and continued 1500 ms later, the resume after each returned `{:ok, _}` | none |

The two defect fixes are 7 lines of test code; after them, the changed test files pass, the slow tests of `lock_test.exs` included. No further round, as the orchestrator set.

Precommit after the merge-gate fix (`HELYX_SLOW=1`): passed on the first run (root 593 tests, `apps/coding_agent` 77, `plugins/bundled` 782 and 2 properties, 0 failures; Credo and Dialyzer clean).
