# Review: /new and /resume in the TUI (#551)

Scope: the working tree against `HEAD` (`490b4413`), the branch point from `origin/master`. Feature doc: `docs/features/tui-session-switch.md`.

## Simplify

Four agents (reuse, simplification, efficiency, altitude).

| Finding | Resolution |
| ------- | ---------- |
| The `Wait` test tool copies `Helyx.TUI.Test.Tool.Slow` | Fixed: `Slow` moved to `test/support/tui_slow_tool.ex`, used by both test files |
| `CodingAgent.one_line/1` delegate has one caller | Fixed: removed; `clean_line/1` calls `SessionList.one_line/1` |
| The no-argument rule of `/new` and `/resume` is in `Command.run/2` and `Helyx.TUI` | Fixed: `Command.parse/1` gives `{:usage, name}` for an argument |
| `done/2` patches the `down` of the switch that `start/2` made | Fixed: `start/3` takes `down` |
| `Switch.cancel/1` has one caller | Fixed: inlined in `terminate/2` |
| `Footer.clean/1`, the composer box, and the room rule repeat | Skipped: `Footer.clean/1` keeps whitespace (another rule); the box and the room rule are three lines each |
| `Scan.list/2` in the TUI process | Skipped: stated in the bounds table |
| A full frame for an ignored key in the list | Skipped: one frame of at most 256 short lines |
| `Switch` takes the whole TUI state; `Start` is a move | Skipped: `Switch` owns the bind and the switch decisions; `Start` owns the start window |
| `queue_dropped` skip during a switch | Skipped: the ticket decides that the queue goes with the old session |
| The line format in a TUI module | Skipped: the bundled project cannot call the product, and the TUI shows the line |

## Round 1 (full)

Bounds sensor (`--diff HEAD`):

```
bounds sensor: 8 candidate functions, 1 flagged, 0 without an answer
  plugins/bundled/clients/tui/lib/helyx/tui/composer.ex:153  SIZE  defp join_draft(composer, texts) do
```

The failure-path agent found no defect in `join_draft/2`: the composer has no bound by design (#29), and the join is linear in its text.

| # | Axis | Finding | Resolution |
| - | ---- | ------- | ---------- |
| 1.1 | Codex, failure path, spec | A crash of the switch Task (a tool `check/0` that raises in the open) leaves `state.switch` set: ExRatatui traps exits, and the catch-all drops the `:DOWN`, so every Enter is rejected until quit. Reproduced | Fixed: the `:DOWN` of the Task ref is a failed open (`Switch.done(state, {:error, reason})`); test "a crash of the switch Task is a failed switch" |
| 1.2 | spec | The end signal of the old session can come after the error answer: the TUI stays on a dead session, then exits on the late signal instead of starting a new one | Fixed: a dead process at the answer counts as an end signal (`:noproc`); test "a session that died with its end signal still on the way" |
| 1.3 | spec | The rows bound said the transcript always keeps one row; at a room of 3 rows it has none | Fixed: doc states the rule of the composer; test at the limit |
| 1.4 | spec | The bounds table left out the unbounded stats of the scan | Fixed: row added |
| 1.5 | standards | `coding-agent.md` said only `/model` and `/compact` lines are not messages | Fixed |
| 1.6 | standards | Out of scope and the ownership holes name no ticket | Fixed: written as "no ticket" and "open, no ticket"; no ticket is opened in this run |
| 1.7 | standards, spec | No test for the abort in `terminate/2` and for a missing `:sessions_dir` | Fixed: tests |
| 1.8 | standards | `test/support/tui_slow_tool.ex` untracked | Fixed: added |
| 1.9 | spec | `{:session_locked, id}` for a session that runs in this Core reads "open in another process" | No change: it is the error that Core gives (`Server.start/3`) and the text that `CodingAgent` prints for it |
| 1.10 | spec | A failed `/new` after the old session ended exits with the end reason, not the start error | No change: the feature doc states it, and the exit is the existing end of the TUI |
| 1.11 | standards | `Start` split, `Switch` takes the TUI state, `SessionList` holds the CLI line | No change: see Simplify |

Fix size: 27 changed lines in two code files and one added function, so round 2 is full.

## Round 2 (full)

Simplify (four agents) on the round-1 fix:

| Finding | Resolution |
| ------- | ---------- |
| `running?/1` checks `Process.alive?` again, which the Registry already does in `Session.pid/1` | Fixed, with the next row |
| The `:noproc` reason makes a stopped session read "crashed"; the monitor is the one source of the end signal | Fixed: `Switch.done/2` waits for the `:DOWN` of the session monitor when `Session.pid/1` gives nil |
| `SessionList.rows/2` copies the room rule of `Composer.rows/2` | Fixed: `Composer.fit/2`, which both call |
| `coding-agent.md` says twice that `/new` and `/resume` switch the session | Fixed |
| `Scan.list/2` in a Task; `Raises` in `test/support`; split the terminate test; `Task.Supervisor.async_nolink` | Skipped: the bounds table states the scan; one test uses `Raises`; ExRatatui traps exits by design |

Bounds sensor (`--diff HEAD`): two flags, `join_draft/2` (SIZE, as in round 1) and `Switch.ended/1` (WAIT). The spec agent found no path where the wait blocks: the session has `restart: :temporary`, a gone Registry partition stops the session through its exit trap, and no other receive takes the `:DOWN`.

| # | Axis | Finding | Resolution |
| - | ---- | ------- | ---------- |
| 2.1 | Codex | A session can end with the reason `nil` or `false`: `switch.down || ended(state)` then waits for a `:DOWN` that `handle_info` already took, or takes a pending one and keeps the dead session. Reproduced. Second finding on the end-signal store | Fixed in the store: the end signal is `{:down, reason}`, so no reason reads as no signal; test "an end signal with a nil reason still counts as ended" |
| 2.2 | failure path | A new session that dies between the answer and the subscribe ends the TUI with `:session_not_found`, so the line says "stopped" for a crash. Reproduced | Accepted hole, stated in the feature doc: the mount has the same rule at `HEAD`; the TUI ends as it must, only the cause text is general |
| 2.3 | standards | The wait of `ended/1` has no bounds row | Fixed: row added |
| 2.4 | standards | "open, no ticket" and "not bounded" without a ticket number | No change: no ticket is opened in this run; the report names the holes |
| 2.5 | standards | The catch-all comment in `Helyx.TUI` does not name the `:EXIT` of the switch Task | No change: the comment of the Task `:DOWN` clause states that the last clause drops the `:EXIT` (round 3 simplify) |
| 2.6 | standards | `Raises` in the test file, `fit/2` in `Composer`, the `target` argument of `failed/3` | No change: judgement calls; `fit/2` is the rule of the composer box |
| 2.7 | spec | No defect | n/a |

Fix size: 2.1 changes the type of `down` and five lines of `Switch`; it is a second finding on one mechanism, so round 3 is full.

## Round 3 (full)

Simplify: one agent on the five-line fix. The repeated comment of 2.5 is removed; merging the nil-reason test into the `:killed` test is skipped (one test for each reason reads more clearly).

| # | Axis | Finding | Resolution |
| - | ---- | ------- | ---------- |
| 3.1 | Codex | `Helyx.TUI` skips every `queue_dropped` while a switch runs, before the result is known. Escape during a `/resume` whose open then fails (a raising tool check), or a turn that fails during the switch, drops the queue of the current session, and the TUI stays on it with the texts in neither the queue nor the composer. Reproduced | **Open.** The fix keeps the texts in the switch and joins them to the composer on a failed switch; it touches `Helyx.TUI` and `Helyx.TUI.Switch` and adds a field, so it does not meet the conditions of the small-fix round. Reported to the caller |
| 3.2 | standards | One word `down` names a type, a field, a function, and a tag; the nil test checks the struct only; `start/3` is public with `down`; the Errors text says `{:session_down, reason}` for the end reason | No change: judgement calls; the doc text names `Session.end_reason/1` in the bounds of the TUI exit (`coding-agent.md`) |
| 3.3 | spec | No defect | n/a |
| 3.4 | failure path | No defect; not reached: `Start.run/1`, `SessionList`, `Composer.end_recall/1`, the Escape abort Task during a switch | n/a |

The loop ends: round 3 reproduced 3.1, and its fix is not a small fix. The commit holds the code of round 3, whose review is done.
