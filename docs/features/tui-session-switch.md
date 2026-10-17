# /new and /resume in the TUI

## Goal

The user starts a new session, or goes to an earlier session of the folder, without a quit and a new start of `helyx` (#551).

User stories:

1. `/new` ends the current session and starts a new one in the same folder with the current model. The screen clears, and an information cell says `new session`. The footer shows the new session.
2. `/resume` opens a list of the other sessions of the folder, with the lines of `helyx --list`, newest first. Up and Down move the selection, Enter resumes the selected session, and Escape closes the list. The TUI shows the history of that session and the information cell `resumed session`.

Decisions (the ticket, "Decisions (orchestrator, 2026-10-17)"):

- **The calls.** The TUI calls the server operations of #489: `Helyx.Session.File.Scan.list/2` for the list, `Helyx.Session.start/2` for `/new`, and `Helyx.Session.resume/2` with `:id` for `/resume`. Core gets no new function. `CodingAgent` gives the TUI the sessions directory (`:sessions_dir` of `Helyx.TUI.run/1`); the core is the one of the current session, and the folder is `:cwd`.
- **The order of a switch.** The switch runs in a Task, so the frame loop does not wait: (1) the new session starts or resumes; (2) on success the old session gets `Helyx.Session.abort/1`, which waits for the end of its turn, so the aborted turn is saved; (3) the old session ends; (4) the TUI drops its monitor of the old session and subscribes to the new one. The new session starts first, so a failed start or resume leaves the current session as it was, with its turn and its queues. The ticket puts the abort first; the order here keeps its reason (the aborted turn is saved before the end) and loses nothing on a failure.
- **The end of the old session.** Core has no stop function, and the ticket allows no new Core API. The Task stops the session process with `GenServer.stop(pid, :shutdown, :infinity)` on the pid of `Helyx.Session.pid/1`. The session's `terminate/2` runs its stop (`Helyx.Session.Server.Stop`), which releases the hands, the background folder, and the writer lock, and each of its waits is bounded. The end signal of the old session reaches the TUI as a subscriber; the TUI drops it.
- **The queues of the old session** go with it. The abort gives them back in a `queue_dropped` event, and while a switch runs the composer does not take them. The composer draft stays as it is. A recall that shows at the join ends: the draft and the shown text stay in the composer (`Composer.end_recall/1`), because the position of the recall is a cell of the old session. Open, no ticket (review round 3, 3.1): a queue that an Escape or a failed turn gives back during a switch that then fails is lost, because the composer skips it before the result is known.
- **Input during a switch.** Enter and every command are rejected with the reason `not sent: a switch runs`, so no text goes to a session that ends. The composer still takes text.
- **The prompt history** (#469) is the user messages of the view model, so after a switch it is the history of the new session.
- **Old events.** An event of the old session can still be in the mailbox of the TUI after the join. The TUI keeps the `instance_id` of its snapshot and drops every event with another one, as `Helyx.Session.subscribe/1` asks of a client that subscribes again.
- **Errors.** A crash of the switch Task (a tool check that raises in the open, for example) is a failed open: ExRatatui traps exits, so the TUI gets the `:DOWN` of the Task and handles it as an error. A failed start or resume adds the information cell `could not switch: <reason>`, and the TUI stays on its current session. `{:session_locked, id}` reads `session <id> is open in another process`; any other reason is `Helyx.Reason.text/1`. When the current session ended during the switch (its end signal came while the Task ran, or its process is dead when the answer comes; then the TUI waits for the end signal, which its monitor makes certain), the TUI starts a new session in its place, as `/new`. When that start fails too, or when the failed switch was a `/new`, the TUI ends with `{:session_down, reason}`, as it does today when its session ends. A new session that ends between the answer of the Task and the subscribe ends the TUI with `{:session_down, :session_not_found}`, as at the mount, so the line says the session stopped also when it crashed (an accepted hole).
- **The list** draws in the place of the composer, in the same box, with as many rows as fit above the footer while the transcript keeps one row. It leaves out the current session. A list with no other session shows the line `no other session in this folder`. The list is read once, when it opens, in the TUI process.
- **One line format.** The line of a session moves from `CodingAgent.CLI` to `Helyx.TUI.SessionList.line/2`, which both call, so `helyx --list` and `/resume` show the same line. The clean pass `CodingAgent.one_line/1` moves there too, as `Helyx.TUI.SessionList.one_line/1`, because the bundled project cannot call the product; `CodingAgent.clean_line/1` calls it.
- **Quit after a switch.** `CodingAgent` aborts the session that it started. After a switch that session is gone, so the TUI aborts its current session in its `terminate/2`, after ExRatatui restores the terminal, and kills a switch Task that still runs.

## Interface changes

- `Helyx.TUI.run/1`: the option `:sessions_dir`. Without it, `/new` starts a session that is not saved, and the `/resume` list is empty.
- `Helyx.TUI.Command`: the commands `/new` and `/resume`. Each takes no argument; `/new x` gives the notice `usage: /new`.
- `Helyx.TUI.SessionList` (new, `@moduledoc false`): the list of `/resume`, its keys and its widget, and `line/2`, `folder/1`, and `one_line/1` for `CodingAgent.CLI` and `CodingAgent`.
- `CodingAgent.one_line/1` is removed; `Helyx.TUI.SessionList.one_line/1` replaces it.
- `Helyx.TUI.Composer.end_recall/1` (new).
- `CodingAgent`: passes `:sessions_dir` to the TUI.

## Replaced mechanism

1. The TUI held one session for its whole life, and the view model had no `instance_id` guard because the TUI subscribed once. Now `Helyx.TUI` subscribes once for each session and drops an event of another `instance_id` (`handle_info/2`). The view model stays without a guard.
2. The end signal of the session always ended the TUI. During a switch it is kept in the switch state, and the result of the switch decides (see Goal, "Errors").
3. The `--list` line of `CodingAgent.CLI` (`line/2`, `folder_text/1`, `take/2`, `time/1`, and the widths) moves to `Helyx.TUI.SessionList` unchanged. The tests of `--list` keep their properties.
4. The only abort at quit was the one of `CodingAgent.run/1`. It stays, for a TUI that fails to start, and the TUI adds its own for its current session. A known ceiling: a later client that switches sessions must abort its current session itself, because Core has no list of the sessions of a client.

## Bounds

| What | Bound | Over the bound | Where |
| ---- | ----- | -------------- | ----- |
| sessions in the list | the scan bound of `Scan.list/2`: 256 files, minus the current session | the older ones are not listed | `Scan.list/2` |
| bytes read for the list | 256 heads of 65,537 bytes, read in the TUI process when the list opens; the frame waits for it | n/a | `Scan.list/2`, `SessionList.new/2` |
| stats and paths of the list scan | not bounded, the known ceiling of `Scan.newest/2` (`docs/features/session-list.md`): every session file of the folder is stat'ed, now also in the TUI process when the list opens | n/a | `Scan.list/2` |
| a line of the list | the widths of `helyx --list`: id 12, time 19, model 40, and prompt 60 code points after the clean pass, two spaces between fields; the widget cuts a line at the box width | cut | `SessionList.line/2`; `ExRatatui.Widgets.List` in the frame |
| list rows drawn | the rule of the composer (`Composer.fit/2`): at least one item row and the two borders, and the transcript keeps one row when the room above the footer is 4 rows or more; the widget scrolls to keep the selection on the screen | the other lines are off the screen | `SessionList.rows/2`, `Helyx.TUI` layout |
| switches at one time | one; a second `/new` or `/resume` and every send wait for its end with a reason | rejected: `not sent: a switch runs` | `Helyx.TUI` |
| wait of a switch | the start or resume of the new session, the abort of the old one (it waits for the hands, as Escape does), and its stop, whose waits `Stop.shutdown_ms/0` bounds; none of it in the frame loop (the wait for an end signal at a failed answer is its own row) | n/a | the switch Task |
| wait for the end signal of a dead session at a failed answer | the `:DOWN` of the monitor of the subscribe, which a dead process sends; `Helyx.Session.pid/1` gives nil only for a dead session or a gone Registry, and both end the session within the bound of `Stop.shutdown_ms/0` | n/a | `Switch.done/2`, in the TUI process |
| subscribe to the new session | the 5 s call timeout of `Helyx.Session.subscribe/1`, in the TUI process | the exit ends the TUI | `Helyx.TUI` |
| error text in the information cell | `Helyx.Reason.text/1`: 4,000 bytes; the cell is drawn through `Helyx.TUI.Wrap` | cut | `Helyx.TUI` |

## Ownership

| Resource | Created by | Held by | Released on normal end | Released when the holder crashes | Released on abort |
| -------- | ---------- | ------- | ---------------------- | -------------------------------- | ----------------- |
| switch Task | `Helyx.TUI`, `Task.async/1` | the TUI, linked | its reply goes to the TUI | the link ends it; open, no ticket: a session that it started stays until Core stops | `terminate/2` of the TUI kills it at quit; open, no ticket: a session that it started stays until Core stops |
| the new session | the switch Task | Core's session supervisor | the next switch ends it, or Core stops | Core stops it | a quit aborts it in `terminate/2` |
| the old session | an earlier start | Core's session supervisor | the switch Task stops it | Core stops it | n/a |

## Out of scope

No ticket owns these yet.

- Session names, a tree view, branching, fork.
- Sessions of other folders in the list (`--all`).
- A search or a filter in the list.
- A stop function in Core, which would replace the `GenServer.stop/3` of the switch Task.
