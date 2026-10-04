# Multiline composer

## Goal

The TUI composer holds more than one line, so a user can write and paste code (#44). The decision on the ticket, 2026-09-25:

- Enter sends, as before. Alt+Enter stays the follow-up key.
- Ctrl+J adds a new line in every terminal. In raw mode crossterm reports the LF byte as `j` with `ctrl`, so ExRatatui gives the key code `"j"` with the modifiers `["ctrl"]`.
- Shift+Enter adds a new line where the terminal reports Shift on Enter. Elsewhere Shift+Enter is Enter and sends.
- A paste keeps its new lines and tabs. A paste of more than 5 lines shows in the composer as one marker, `[Pasted text #1, 20 lines]`, like Claude Code and Codex. The full text is sent with the prompt, so the session saves it in the transcript. A paste of 5 lines or fewer shows as normal text. The Tab key goes to the textarea, which indents; the one-line input ignored it. Shift+Tab also goes to the textarea, which inserts spaces.
- A marker is one unit for every edit (orchestrator decision, 2026-09-25): no edit leaves a broken marker whose paste is dropped in silence, and only the markers that the composer made are replaced on send.

The invariant: the text sent equals what the user sees, with every live marker replaced by exactly its own paste. No edit drops a paste without removing its marker, and no typed text is replaced.

The marker rules:

- A marker ends with U+0001, a control character. A paste drops it. A key code with a control character goes nowhere: crossterm gives Ctrl+key as the key with a `ctrl` modifier, but the kitty keyboard sequence `ESC [ 1 u` gives the key code U+0001 with no modifier. ExRatatui does not draw it. So only a marker that the composer made ends with it, and text that only looks like a marker is sent as typed.
- Backspace with the cursor inside a marker or right after it, and Delete with the cursor at its start or inside it, remove the whole marker.
- Left and Right pass over a marker in one step.
- Up and Down keep the column, so they can put the cursor inside a marker. Every other key, a paste, Ctrl+J, or Shift+Enter with the cursor inside a marker first moves the cursor to the end of the marker. So Up and Down from inside a marker start at its end.

Prompt history (#469):

- Up with the cursor on the first row recalls the earlier user prompts of the session, newest first. Down with the cursor on the last row goes back toward the newest, and past it to the draft, the text the user was typing, with its paste markers. On any other row, and with no prompt to go to, Up and Down move the cursor as before. Shift+Up and Shift+Down only move the cursor.
- A recalled prompt starts with the cursor at its start, and the draft or a prompt that Down brings with the cursor at its end, so the next Up or Down goes on through the history.
- The history is the user messages in the view model (`Helyx.TUI.ViewModel.prompt/3`), so it holds the history of a resumed session and the steers and follow-ups that became user messages. It is not stored a second time. The composer keeps only the position of the cell that shows and the draft (`recall`).
- A recalled prompt is its text blocks as stored, so a paste shows in full, not as a marker. The paste rule cleans it: CRLF and a lone CR become LF, and control characters other than tab and LF drop, so recalled text cannot forge a marker. Editing a recalled prompt does not change the history: the next recall replaces the edit with a stored prompt or the draft, and the edit is lost. Enter sends the composer as usual, and a send empties `recall`. A rejected send keeps `recall`, so Down still brings the draft back.

The kitty keyboard protocol is not on; it is #108. ExRatatui 0.14.1 has no option to push keyboard enhancement flags: `native/ex_ratatui/src/terminal.rs` turns on the alternate screen, bracketed paste, and optional focus and mouse reports, and nothing else. Until #108, Shift+Enter adds a new line only in a terminal that reports Shift on Enter without the protocol.

## Interface changes

The state of `Helyx.TUI` changes:

- `input` is an `ExRatatui.textarea_new/0` reference, drawn as `ExRatatui.Widgets.Textarea`, in place of the one-line `TextInput`.
- `pastes` maps the text of each live marker to the full paste it stands for. `count` is the id of the last marker.
- `recall` is nil, or the position of the recalled prompt's cell and the draft with its `pastes` (#469). A recalled prompt shows with no pastes; the draft gets its own back. `count` does not change, so a marker id is not used twice.
- `Helyx.TUI.Composer.recall/3` and `Helyx.TUI.ViewModel.prompt/3` are new (#469).

The status bar key help adds ` · Ctrl+J newline`.

## Bounds

| What | Bound | Over the bound |
| ---- | ----- | -------------- |
| Composer height | At most 8 lines inside the two borders, so 3 to 10 rows. On a small terminal the composer shrinks, down to 3 rows, so the transcript keeps 1 row: the terminal height minus 2, and not less than 3. `Helyx.TUI.Composer.rows/2` is the one rule. The render (`Layout.split/3`) and the scroll screen (`on_screen/2`) both read it with the room they have, the terminal height minus the status row, so the transcript screen that the scroll position is checked against is the screen that is drawn. An edit that changes the line count runs `settle/1` of `Helyx.TUI`. At 4 rows or less the transcript has no row, and the scroll screen is 1 row | The textarea scrolls to its cursor. A line longer than the composer width scrolls sideways, as the one-line input did |
| Composer text | Unbounded human input, as before (#29) | Nothing is cut |
| Paste line count | More than 5 lines is a marker. A line ends at a new line, and a final new line does not start a line: `"a\nb\n"` is 2 lines. CRLF and a lone CR count as one new line each | The paste shows as the marker, and the full text goes in `pastes` |
| Paste text | Valid UTF-8: ExRatatui gives it as a Rust `String` (#381). CRLF and a lone CR become LF. Control characters other than tab and LF drop, the same set the transcript drops, so no escape sequence reaches the terminal through the composer. Size is unbounded human input (#29) | None: no source gives other text |
| `pastes` map | One entry for each live marker: Backspace or Delete removes a marker and its entry (#427). The map and `count` empty when a send or a `/model` switch empties the composer, so the marker ids start at `#1` again. While a prompt is recalled, the draft's map waits in `recall`, and the composer map starts empty: it holds only the markers of pastes made in the recalled prompt | A rejected send keeps the map with the text |
| An edit with pastes pending | Each key, paste, or new line reads the composer text once (`textarea_get_value/1`), walks the cursor line once to turn the code point column into a byte offset, and searches the text once for all pending markers (`:binary.matches/2`). ExRatatui has no call to delete a range or to set the cursor, and its Right key stops short of zero-width characters at the end of a line. So to remove a marker or to move past it, the TUI sets the composer to the text after the new cursor (`textarea_set_value/2`) and inserts the text before it (`textarea_insert_str/2`), which leaves the cursor exactly there. The cost is linear in the composer text for each edit. A marker is 24 characters plus the digits of the id and the line count | With no pending paste, keys go to the widget as before, and text is inserted without a search |
| Prompt history | One Up or Down walks the cells from the shown prompt to the next user message: one `:array.get/2` for each cell it passes, so at most the cell count. Setting the text is linear in it. The draft is one copy of the composer text and its `pastes` | |
| Send | The composer text with each live marker replaced by its paste, in one pass (`String.replace/3` with the list of markers), so a marker inside a paste is not replaced again. `count` only grows until the map empties. Thus a marker id is not used twice before then, and each marker stands for exactly one paste. The `/model` rule reads this text | |

Accepted holes:

- The repeat and the release of Enter do nothing. Holding Enter does not add lines.

## Ownership

No external resource. The textarea state is a NIF resource owned by the TUI process, freed with it.

## Out of scope

- The kitty keyboard protocol: needs an ExRatatui change (#108).
- Undo and the Emacs keys of the textarea: keys with Ctrl or Alt do not reach the widget, as before.
- A limit on the composer text: unbounded human input (#29).
