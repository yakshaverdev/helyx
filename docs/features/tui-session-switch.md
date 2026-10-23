# /new and /resume in the TUI

## Goal

The user starts a new session, or goes to an earlier session of the folder, without a quit and a new start of `helyx` (#551).

User stories:

1. `/new` ends the current session and starts a new one in the same folder with the current model. The screen clears, and an information cell says `new session`. The footer shows the new session.
2. `/resume` opens a list of the other sessions of the folder, with the lines of `helyx --list`, newest first. Up and Down move the selection, Enter resumes the selected session, and Escape closes the list. The TUI shows the history of that session and the information cell `resumed session`.

Decisions (the ticket, "Decisions (orchestrator, 2026-10-17)"):

- **The calls.** The TUI calls the server operations of #489: `Helyx.Session.File.Scan.list/2` for the list, `Helyx.Session.start/2` for `/new`, and `Helyx.Session.resume/2` with `:id` for `/resume`. Core gets no new function. From #809 the TUI uses only the wire (`docs/features/tui-attach.md`, decision 12): the requests `sessions.saved`, `start`, and `resume` with `id` (`Helyx.TUI.Link`) run these operations in the server, which saves in its own data folder, so the TUI has no sessions directory; the folder is `:cwd`.
- **The order of a switch.** The switch runs in a Task, so the frame loop does not wait: (1) the new session starts or resumes; (2) on success the old session gets the `stop` request, which aborts its turn and waits for its end, so the aborted turn is saved; (3) the old session ends; (4) the TUI subscribes to the new one and drops the `session_end` of the old sub. The new session starts first, so a failed start or resume leaves the current session as it was, with its turn and its queues. The ticket puts the abort first; the order here keeps its reason (the aborted turn is saved before the end) and loses nothing on a failure.
- **The end of the old session.** The Task sends `stop`, which the server runs as `Helyx.Sessions.stop/1` (#657): it aborts the turn and stops the session process; a session that ended first gives an error, such as `session_not_found`, and so does a stop that leaves a handle of the session not released (#752); the Task ignores both. A wire error (`timeout`, `busy`, `closed`, `failed`) fails the switch (`docs/features/tui-attach.md`, slice 3). The session's `terminate/2` runs its stop (`Helyx.Session.Server.Stop`), which releases the hands, the background folder, and the writer lock, and each of its waits is bounded. The end signal of the old session reaches the TUI as a subscriber; the TUI drops it.
- **The queues of the old session** go with it. The abort gives them back in a `queue_dropped` event. While a switch runs, the switch keeps the `queue_dropped` events of the current session (an Escape or a failed turn can give a queue back too). When the switch fails and the TUI stays on the current session, the composer takes their texts in their order, as it takes a `queue_dropped` outside a switch. When the current session ended and a `/new` takes its place, the composer takes them before that `/new` starts, because the composer stays with the TUI. After a switch that succeeds, the texts go with the old session. The composer draft stays as it is. A recall that shows at the join ends: the draft and the shown text stay in the composer (`Composer.end_recall/1`), because the position of the recall is a cell of the old session.
- **Input during a switch.** Enter and every command are rejected with the reason `not sent: a switch runs`, so no text goes to a session that ends. The composer still takes text.
- **The prompt history** (#469) is the user messages of the view model, so after a switch it is the history of the new session.
- **Old events.** An event of the old session can still be in the mailbox of the TUI after the join. The TUI keeps the `instance_id` of its snapshot and drops every event with another one, as `Helyx.Session.subscribe/1` asks of a client that subscribes again.
- **Errors.** A crash of the switch Task is a failed open: ExRatatui traps exits, so the TUI gets the `:DOWN` of the Task and handles it as an error. A tool check that raises in the open is the answer `failed` of the server. A failed start or resume adds the information cell `could not switch: <reason>`, and the TUI stays on its current session. Each known reason of Core or of the wire has a fixed text, such as `too many sessions on the server`, and any other reads `the session did not open`, so the cell holds no term (`docs/features/tui-attach.md`, slice 3); a session that another process has open is a `start_failed` of the server: `the server could not open the session`. When the current session ended during the switch (its `session_end` came while the Task ran), the TUI starts a new session in its place, as `/new`. No call of the wire tells a dead session apart, so a `session_end` that comes after the answer of a failed switch ends the TUI (`docs/features/tui-attach.md`, Accepted holes); the node, until #809, waited for the end signal of a dead session there and took its events first. When that start fails too, or when the failed switch was a `/new`, the TUI ends with `{:session_down, reason}`, as it does today when its session ends. A new session that ends between the answer of the Task and the subscribe ends the TUI with `{:session_down, :session_not_found}`, as at the mount, so the line says the session stopped also when it crashed (an accepted hole).
- **The list** draws in the place of the composer, in the same box, with as many rows as fit above the footer while the transcript keeps one row. It leaves out the current session. A list with no other session shows the line `no other session in this folder`. The list is read once, when it opens, in a Task (#667).
- **One line format.** The line of a session moves from `CodingAgent.CLI` to `Helyx.TUI.SessionList.line/2`, which both call, so `helyx --list` and `/resume` show the same line. The clean pass `CodingAgent.one_line/1` moves there too, as `Helyx.TUI.SessionList.one_line/1`, because the bundled project cannot call the product; `CodingAgent.clean_line/1` calls it.
- **Quit after a switch.** The TUI kills a switch Task that still runs in its `terminate/2`, after ExRatatui restores the terminal. The quit aborts nothing: the current session runs on in the server (`docs/features/tui-attach.md`, decision 8). Until #809 the TUI in the node aborted its current session there.

## Interface changes

- `Helyx.TUI.run/1`: the option `:sessions_dir`. Without it, `/new` starts a session that is not saved, and the `/resume` list is empty. #809 removes it: the server saves in its own data folder.
- `Helyx.TUI.Command`: the commands `/new` and `/resume`. Each takes no argument; `/new x` gives the notice `usage: /new`.
- `Helyx.TUI.SessionList` (new, `@moduledoc false`): the list of `/resume`, its keys and its widget, and `line/2`, `folder/1`, and `one_line/1` for `CodingAgent.CLI` and `CodingAgent`.
- `CodingAgent.one_line/1` is removed; `Helyx.TUI.SessionList.one_line/1` replaces it.
- `Helyx.TUI.Composer.end_recall/1` (new).
- `CodingAgent`: passes `:sessions_dir` to the TUI (until #809).

## Replaced mechanism

1. The TUI held one session for its whole life, and the view model had no `instance_id` guard because the TUI subscribed once. Now `Helyx.TUI` subscribes once for each session and drops an event of another `instance_id` (`handle_info/2`). The view model stays without a guard.
2. The end signal of the session always ended the TUI. During a switch it is kept in the switch state, and the result of the switch decides (see Goal, "Errors").
3. The `--list` line of `CodingAgent.CLI` (`line/2`, `folder_text/1`, `take/2`, `time/1`, and the widths) moves to `Helyx.TUI.SessionList` unchanged. The tests of `--list` keep their properties.
4. The only abort at quit was the one of `CodingAgent.run/1`. It stays, for a TUI that fails to start, and the TUI adds its own for its current session in the node; over the wire the quit aborts nothing (`docs/features/tui-attach.md`, slice 3). From #809 the TUI runs only over the wire, and `CodingAgent.run/1` runs only print mode. A known ceiling: a later client that switches sessions must abort its current session itself, because Core has no list of the sessions of a client.

## Bounds

| What | Bound | Over the bound | Where |
| ---- | ----- | -------------- | ----- |
| sessions in the list | the scan bound of `Scan.list/2`: 256 files, minus the current session | the older ones are not listed | `Scan.list/2` |
| bytes read for the list | 256 heads of 65,537 bytes, read by the server for the `sessions.saved` request that a Task sends when the list opens, so no frame waits for it: a full folder takes 41 to 342 ms (#667); until the answer comes the list shows `reading the sessions of this folder` and only Escape acts | Escape stops the Task (`SessionList.close/1`) | `Scan.list/2` in the server, `SessionList.new/2` |
| stats and paths of the list scan | not bounded, the known ceiling of `Scan.newest/2` (`docs/features/session-list.md`): every session file of the folder is stat'ed, also in the scan Task of the list | n/a | `Scan.list/2` |
| a line of the list | the widths of `helyx --list`: time 19, model 40, and prompt 60 code points after the clean pass, two spaces between fields; the id is not cut: 12 characters for an id of `Helyx.Session.Id.new/0`, and over the wire (#809) any string within the frame bounds, which the client checks as a string only; the widget cuts a line at the box width | cut | `SessionList.line/2`; `ExRatatui.Widgets.List` in the frame |
| list rows drawn | the rule of the composer (`Composer.fit/2`): at least one item row and the two borders, and the transcript keeps one row when the room above the footer is 4 rows or more; the widget scrolls to keep the selection on the screen | the other lines are off the screen | `SessionList.rows/2`, `Helyx.TUI` layout |
| `queue_dropped` events kept by a switch | one for each abort or failed turn of the current session while the switch runs; the texts of each are at most the queue of the session (`Helyx.Session.Queue`), and the composer that takes them has no bound (#29) | n/a | `Switch.event/2` |
| switches at one time | one; a second `/new` or `/resume` and every send wait for its end with a reason | rejected: `not sent: a switch runs` | `Helyx.TUI` |
| wait of a switch | the start or resume of the new session, the abort of the old one (it waits for the hands, as Escape does), and its stop, whose waits `Stop.shutdown_ms/0` bounds, each request within its deadline and margin (`docs/features/tui-attach.md`, slice 2); none of it in the frame loop | n/a | the switch Task |
| subscribe to the new session | the deadline of the server and the margin, 11,000 ms, in the TUI process (`docs/features/tui-attach.md`, slice 3) | the exit ends the TUI | `Helyx.TUI` |
| error text in the information cell | `Helyx.Reason.text/1`: 4,000 bytes; the cell is drawn through `Helyx.TUI.Wrap` | cut | `Helyx.TUI` |

## Ownership

| Resource | Created by | Held by | Released on normal end | Released when the holder crashes | Released on abort |
| -------- | ---------- | ------- | ---------------------- | -------------------------------- | ----------------- |
| switch Task | `Helyx.TUI`, `Task.async/1` | the TUI, linked | its reply goes to the TUI | the link ends it; a session that it started runs on in the server | `terminate/2` of the TUI kills it at quit; a session that it started runs on in the server |
| list scan Task | `SessionList.new/2`, `Task.async/1` | the TUI, linked | its answer goes to the TUI; Escape stops it (`SessionList.close/1`) | the link ends it; a crash of the Task itself, which only a bug makes, leaves the list at `reading the sessions of this folder` until Escape, because ExRatatui traps exits | not stopped at quit: it reads at most 256 heads, but its stats of the folder have no bound (the row of the list scan above), and its answer goes nowhere |
| the new session | the switch Task | the session supervisor of the Core of the server | the next switch ends it, or the server stops | the server stops it | it runs on in the server after a quit |
| the old session | an earlier start | the session supervisor of the Core of the server | the switch Task stops it | the server stops it | n/a |

## Out of scope

No ticket owns these yet.

- Session names, a tree view, branching, fork.
- Sessions of other folders in the list (`--all`).
- A search or a filter in the list.
