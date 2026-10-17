# 2026-10-17: audit of the steps after `assert_receive {:DOWN, ...}` (#670)

Scope: every `assert_receive {:DOWN, ...}` in the root, `plugins/bundled`, and `apps/*` tests and test support (`apps/coding_agent` has none). One exit gives a `:DOWN` to each monitor and an exit signal to each link, with no order between the receivers (AGENTS.md, #605). A site is racy when the step after it needs a message or a cleanup that another receiver of the same exit owns.

Facts that decide many sites:

- **Registry.** `Helyx.Session.pid/1` (`GenServer.whereis/1` through the Registry) and the register of a start check `Process.alive?/1` for a unique key (Elixir 1.19 `registry.ex`, `whereis_name/2` and `register_key/4`). A step that looks up or registers a session id does not need the Registry to have handled the exit.
- **Lock after a normal stop.** `GenServer.stop/1` returns after `terminate/2`, which releases the lock and waits for perl's exit (`docs/features/session-lock.md`, row "owner stops normally"). A step after the stop finds the lock free, except past the release bound of 1000 ms under load, the ceiling that the feature doc states.
- **Lock after a kill.** perl exits after the port closes, with no order to any `:DOWN`. Both sites that kill a session and take its lock again poll for the free lock.
- **The session's wait.** After an idle close or a close of a switch, the session holds every client message until the hands' `:provider_down` (`Helyx.Session.Server.Wait`). A prompt in that window cannot reach the ended process.
- **A suspended session that is resumed** handles its mailbox in order. If the session's own `:DOWN` of its provider process is not in the mailbox at the resume, it can end the turn, start the queued follow-up, and send `{:turn, ...}` to the ended process before its `:DOWN` comes (the race of #620).

## Sites

Line numbers are of `aabf8050`, before this change.

| Site | Step after the `:DOWN` | Decision |
| ---- | ---------------------- | -------- |
| `test/support/session_case.ex:67` `stop_session/2` | polls the Registry; callers then resume or check the lock | Safe: Registry checks liveness; a normal stop frees the lock before it returns; the two kill callers poll for the lock (`persistence_test.exs:302`, `lock_test.exs:98`) |
| `test/support/shared/late_client.ex:45` `disconnect/1` | callers send `:go` to a stream or end | Safe: the session sends to a dead subscriber at worst, which is a no-op; no step reads its subscribers |
| `test/helyx/provider/loop_test.exs:273` | `pump/2` reads the test's own mailbox | Safe: the test process is the only monitor of the model Task |
| `test/helyx/provider/loop_test.exs:305` | collects the events of the session | Safe: reads the test's own mailbox with a bounded wait; the test sends nothing after |
| `test/helyx/session/persistence_test.exs:181` | resumes the supervisor, polls its memory | Safe: polls the state it needs |
| `test/helyx/session/instance_test.exs:45` | `Session.resume/2` | Safe: the `:DOWN` is the test's subscription; `stop_session/2` before it ran a normal stop (lock free) and the resume registers through the liveness check |
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
| `plugins/bundled/test/helyx/tui/switch_test.exs:55` `saved/4` | callers resume or switch to the session | Safe: normal stop, lock free; Registry checks liveness |
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
