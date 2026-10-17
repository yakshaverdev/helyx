# Ctrl+O toggles the full text of tool results

## Goal

The TUI shows the first four lines of a tool result and then a hint row with the count of the hidden lines. The user cannot read the rest without a request to the model. Ctrl+O shows the full text of every tool result, and a second Ctrl+O shows the short form again (#666).

User story: a test run fails. The user presses Ctrl+O and reads the failure after line four. The user presses Ctrl+O again, and the transcript is short again.

Decisions (the ticket, "Decisions (orchestrator, 2026-10-17, owner away)"):

- **One global toggle**, not a selection of one cell. It changes every tool result, also those that arrive later. A selection of one cell needs a cell cursor, which the TUI does not have.
- **The hint row** of a short result is `… N more lines (ctrl+o to expand)` (`… 1 more line (ctrl+o to expand)` for one line). The hint row shows the key, so the footer does not change. The full form has no hint row: its last row is the last line of the result.
- **The full form shows the text that the TUI already holds.** A tool result that Core cut (`Helyx.Message.cut_result/1`) shows its cut notice and its head and tail; the text that Core removed does not come back.
- **Client state only.** The toggle is the field `expanded?` of `Helyx.TUI.ViewModel`, false at the mount. Like `reason`, no event changes it. The transcript reads it from the view model, so the frame, the scroll keys, the wheel, and the copy of a selection all use one form. A switch of the session (`/new`, `/resume`) keeps it: the toggle belongs to the client, not to the session.
- **The key.** Ctrl+O was free in the TUI before #666: no clause of `Helyx.TUI` bound it, and the last key clause of `Helyx.TUI` dropped a key with Ctrl. A press toggles; a repeat and a release do nothing, so a held key does not flicker. While the `/resume` list is open, the list takes the keys, as it does for every key.
- **The view.** A toggle changes the rows of the tool cells. A scrolled view stays in its item (`Transcript.keep/4`): its row stays when the item still has it, else the view starts at the first row of the item, so a collapse inside a long result shows that tool cell, not the items after it. `Transcript.hold/4` then checks the position, as after any change of rows. The follow view stays at the newest output. A toggle ends a selection, as a new size does: the selection holds row addresses, and after the toggle those rows can hold other text. The accepted hole of `docs/features/coding-agent.md` (the mouse) stays: a cell that changes its rows under a selection changes the selected text. With the toggle on, a result that arrives under a selection adds all its rows, not four lines and the hint row.

## Interface changes

- `Helyx.TUI.ViewModel`: the field `expanded?` (default false) and `toggle_expanded/1`.
- `Helyx.TUI`: Ctrl+O calls `toggle_expanded/1`, ends the selection, and keeps a scrolled view in its item.
- `Helyx.TUI.Transcript.keep/4` (new): the position after a change of the rows of its own item.
- `Helyx.TUI.Transcript`: a tool result shows all its lines when `expanded?` is true, and the hint row says the key.

## Replaced mechanism

none. The short form stays as it was, with the key added to its hint row.

## Bounds

| What | Bound | Over the bound |
| ---- | ----- | -------------- |
| the text of one expanded tool result | the tool result bound: 65,536 bytes of valid UTF-8 (`Helyx.Message.cut_result/1`, the bounds table of `docs/features/coding-agent.md`). The accepted hole of that row stays: a session file edited by hand can put several text blocks in one result, and the result then passes 65,536 bytes, within the 64 MiB file limit | Core cut it before the TUI got it; the TUI shows the cut text |
| the work of a frame | a frame wraps only the items that it shows, and the scroll keys and the wheel only the items that they pass (the "Transcript scrollback" row of `docs/features/coding-agent.md`). An expanded result is one item, so a frame that shows one row of it wraps its whole text, at most 65,536 bytes, or more for the hand-edited file of the row above | an item off the screen costs nothing |
| the rows sent to the terminal | the rows of the transcript area: `Transcript.screen/3` takes `height` rows | the rows below the screen are not drawn |

A frame builds the rows of every item that it shows, the rows above and below the screen included, and draws only the rows of the screen. Accepted deviation from the ticket: its "only visible rows are styled" holds for the draw, not for the build. The scroll rule counts the rows of an item, the count needs the wrap of the item, and a build for the screen rows alone needs a row cache, which the transcript does not have. The kept lines are wrapped as one text, so they are sanitized once, not once for each line. Measured on 2026-10-17, a 76 by 40 transcript in the follow view with one result at the bound: 32,768 short lines take about 9 ms per frame expanded and 2 ms short; one line of 65,536 bytes takes about 12 to 24 ms in both forms, because the short form wraps its first line whole too. With one sanitize for each line, the 32,768 lines took 85 ms expanded.

## Ownership

none: the toggle is a field of the view model in the TUI process.

## Out of scope

Expansion of one cell and a pager: no ticket, the ticket of #666 rules them out. Search in the transcript: #668. A hint in the full form or in the footer: no ticket, the hint row of the short form names the key.
