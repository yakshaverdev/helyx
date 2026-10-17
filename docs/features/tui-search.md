# Find text in the TUI transcript

## Goal

The user finds text in the transcript that the TUI holds (#668). The TUI draws in the alternate screen, so the search of the terminal cannot see the transcript.

User story: I want the path that the model named an hour ago. I press Ctrl+F, type part of the path, and jump from match to match. Escape ends the search, and the view stays where I am.

Decisions:

- **The key.** Ctrl+F opens the search. It is free: the composer gets no key with Ctrl, and the TUI uses Ctrl+C and Ctrl+J only. Ctrl+S is not used, because a terminal with flow control stops its output on it. Ctrl+R is not used, because a shell gives it to the search of the prompt history, and Up and Down already recall prompts.
- **The search line.** The open search draws in the place of the composer, in the rect of the composer and in a box of the same look, so an open or a close of the search does not change the transcript height and keeps the view of `Transcript.hold/4`: `find: <query>`, and a reversed space as the cursor. The notes are dim, in the title of the box on its top border, so a long query cannot push them past the edge. The longest notes, `no older match, match not shown`, show in full at a terminal of 38 columns or more; a narrower box cuts them at its corner, as a footer row is cut. The composer keeps its text and shows again when the search closes. A query wider than the box is cut at its edge, as a footer row is.
- **The keys of the open search.** A printable key adds its character to the query. A paste adds its text with each new line as a space, because the query is one line, and the rest cleaned as the transcript draws it: a tab is two spaces, and the other control characters drop. Backspace removes the last character. Enter and Up go to the next older match, and Down to the next newer match. Escape closes the search, with or without a modifier, as Escape aborts with any modifier outside the search; the view stays where it is, and the mark goes. PgUp and PgDn scroll as usual, and so do the wheel and a drag. Ctrl+O toggles the tool output as usual: the hidden lines then draw, and a scroll or a change of the query reaches the row of a match in them. Ctrl+C keeps its rule (clear the composer, or quit). Every other key does nothing while the search is open, and so do Enter, Up, Down, Backspace, and a printable key with a modifier other than Shift.
- **What matches.** The query is literal and case-insensitive: the regex of the escaped query with the flags `i` and `u`, so the case rule of PCRE decides. The search text of an item is the text that the TUI holds for it, cleaned as the transcript draws it (a tab is two spaces): a user message, the text and thinking of an assistant message (Markdown signs included), a tool call line and the whole result text of its tool cell (also the lines that the short form of four lines hides), a notice, a stop line, and the information cells of a run, joined as their row draws them (`· a · b`). The bar of a user row and the `✕` of a notice or a stop line are not search text. The open assistant message is an item too. A match does not cross from one item into another.
- **The match cursor.** One cursor: the item index of the current match. A change of the query looks for the nearest match at or before the cursor, and else for the nearest match after it, so a longer query stays near the match the user reads. With no cursor, the search starts at the newest item. Enter, Up, and Down move from the cursor. At the oldest or the newest match the cursor stays, and the note says `no older match` or `no newer match`; when the frame also has no mark of the match, the box shows both notes, as `no older match, match not shown`. A query with no match in the loaded items has no cursor, and the note says `no match`.
- **The view.** A match moves the view to the first row of the item whose drawn text holds the query, else to the first row of the item, held by `Transcript.hold/4`. So a match near the end shows in the follow view. The match rows of the item on the screen get a yellow mark over each place of the query in their drawn text. When the frame has no mark of the match, the note says `match not shown`: the match is in the lines of a tool result that the short form hides, in Markdown signs, or across a row break, or the user scrolled away from it. With the Ctrl+O toggle on (`docs/features/tui-tool-output-toggle.md`), every result line is drawn, so a match in it is marked.
- **Open hole: the signs of a drawn row.** The row lookup and the marks scan the whole drawn row, and a row has signs that are not search text: the bar `▌ ` of a user row, the fill of spaces to the row end, the `✕ ` of a notice, the indent of a result line, and the hint row of the short form (`… 2 more lines`). So a query can match a sign: the view goes to that row, the mark falls on the sign, and `match not shown` does not show for a match that is not drawn. Examples: a query that starts or ends with a space, `more` with a match in hidden lines, or `✕` in a notice. The review of #668 found it in its last round, and it is not fixed. The fix gives the search its own rows: the text spans of each row with their columns, the signs left out.
- **Emoji sequences.** The marks take their columns from the width rule of `Helyx.TUI.Wrap`, which counts each emoji of a joiner sequence, a skin tone, or a flag, while ExRatatui draws the sequence as two columns (`wrap.ex`, ticket #90). So after such a sequence in a row, the mark falls to the right of the match, and `match not shown` does not show. Accepted: the selection has the same rule, and the rule must never count less than ExRatatui draws. Found by the Codex merge gate of #668, round 2.
- **The loaded history.** The search covers only the cells that the TUI holds. With the history pages of #658 and the attach of #662, a cell that is not loaded is not searched.
- **A cell during a stream.** A tool cell or a notice that arrives while an assistant message streams goes before the open message, so the open message and each item after the cursor get a new index. The cursor stays at its index, so it can name another item; the note then says `match not shown`, or the item at that index is marked when it holds the query, and the next key looks from that index. The scroll position has the same rule: a new item can take the index of the open message (`Transcript.hold/4`). Accepted: a stream adds at most a few cells, and the next key finds a match again.
- **A switch.** `/new` and `/resume` close the search, because the cursor is an item of the old session.

## Interface changes

- `Helyx.TUI.Search` (new, `@moduledoc false`): the search state, its keys, its line, and its marks.
- `Helyx.TUI.Transcript.find/5` (new): the next match from an item, older or newer, and its row at a width.
- `Helyx.TUI.Selection.widgets/4` becomes `Selection.widgets/3`, which takes the rows of `Transcript.screen/3`, so one frame wraps the screen once for the transcript, the selection, and the search marks.
- `Helyx.TUI`: the state key `:search`, Ctrl+F, and the search line in the place of the composer.
- `Helyx.TUI.Footer.busy/2` (new): the busy timer of the footer from the view model, moved from `Helyx.TUI`: the footer owns the rule of when the busy timer starts and stops, next to its draw and its tick (`Footer.tick_ms/0`). `Helyx.TUI` keeps the tick message.

## Replaced mechanism

None. `Selection.widgets/4` made the screen rows itself; `Selection.widgets/3` gets them from the TUI, which adds the search marks over the same rows. The selection test of the marks keeps its property.

## Bounds

| What | Bound | Over the bound | Where |
| ---- | ----- | -------------- | ----- |
| query | 256 bytes of valid UTF-8, no control character | a key that would pass the bound is dropped; a paste is cut at the bound on a character boundary before its clean, so a long paste costs no more than the bound | `Helyx.TUI.Search` (`@max_bytes`) |
| scan of one query change or one move | the loaded items, one regex match over the search text of each item from the cursor to the first match; for the row, one wrap of the matched item at the transcript width. Unbounded in the loaded history, accepted: the cells are bounded by the session | n/a | `Transcript.find/5` |
| marks of a frame | only the rows of the matched item that the frame draws, one regex scan of each row text | n/a | `Search.marks/3` |
| match cursors | one | n/a | `Helyx.TUI.Search` |
| note | a fixed text of the TUI | n/a | `Helyx.TUI.Search` |

## Ownership

No external resource.

## Out of scope

Regex search, the search of history that is not loaded (#658), a search across sessions, a count of the matches, and a wrap from the oldest match to the newest. No ticket owns these yet.
