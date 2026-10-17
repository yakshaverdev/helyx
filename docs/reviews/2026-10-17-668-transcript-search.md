# Review: find text in the TUI transcript (#668)

Scope: Ctrl+F search of the loaded transcript (`Helyx.TUI.Search`, `Transcript.find/5`, `Selection.widgets/3`, `Footer.busy/2`), the feature doc `docs/features/tui-search.md`, and the key table of `apps/coding_agent/README.md`.

Invariant: the open search draws in the rect of the composer and takes every key and paste except Ctrl+C, PgUp, PgDn, and Ctrl+O; a query of at most 256 bytes of clean one-line text moves the view to the nearest match, held by `Transcript.hold/4`; the line says `match not shown` whenever the frame has no mark of the match.

## Rounds

| Round | Type | Base | Simplify | Standards | Spec | Failure-path | Codex | Reproduced defects |
| ----- | ---- | ---- | -------- | --------- | ---- | ------------ | ----- | ------------------ |
| 1 | full | origin/master `c7cbebb9` | 4 applied, 6 skipped | 7 | 3 | 2 | 2 (needs-attention) | 5 |
| 2 | full (109 code lines, 4 files, functions added and removed) | `fcbfc756` | 3 applied, 4 skipped | 1 doc, 3 judgement | 2 defects, 2 doc | 0 | 0 (approve) | 2 |
| 3 | full (note mechanism patched in round 1; 2 code files, 1 function added) | `07d2d3c0` | clean, 1 skipped | 1 hard, 2 judgement | 2 | 3 | 1 (needs-attention) | 3 |
| small-fix | reduced (10 code lines, 1 file, no function change) | `45c37f7b` | n/a | n/a | 3 (one class) | 1 (same class) | n/a | 0 new: all in the open hole of round 3 |

Bounds sensor:

- round 1: `bounds sensor: 7 candidate functions, 0 flagged, 0 without an answer`
- round 2: `bounds sensor: 5 candidate functions, 0 flagged, 0 without an answer`
- round 3: `bounds sensor: 3 candidate functions, 0 flagged, 0 without an answer`

## Findings and resolution

Round 1:

- Failure-path: Ctrl+F made the search line one row high, so the transcript height changed and the held position broke `Transcript.hold/4`. Codex: Escape with a tall composer moved the match off screen. Fixed: the search line takes the rect of the composer; `Search.rows/1` and its `middle_rows` clause are gone. Test: `tui_test.exs`, "the search line takes the rows of the composer".
- Failure-path: a tab in the text could not be found. Fixed: the search text and a paste are cleaned with `Wrap.sanitize/1`.
- Spec: Ctrl+O was swallowed by the open search. Fixed: `Helyx.TUI` handles PgUp, PgDn, and Ctrl+O before the search clause.
- Spec: a cell that arrives during a stream takes the index of the open message, so the cursor can name another item. Accepted, as the scroll position has the same rule (`Transcript.hold/4`); the note is derived from the marks of the frame, so it says `match not shown`. Test: `search_test.exs`, "a cell that arrives during a stream".
- Standards: the `.credo.exs` entry for `tui.ex` had a line count as its reason. Fixed: the entry is gone; `sync_busy` became `Footer.busy/2`, and `tui.ex` is 400 lines.
- Standards: the note was made from an atom name. Fixed: `end_note/1`.
- Standards: the `refute_receive` of the Escape test proved nothing. Fixed: the test traces the spawns of the test process and refutes the abort Task.
- `show/3` kept an old `no match` after a move. Fixed: `show/3` clears the note.
- Skipped: one shared box helper for the composer, the list, and the search; one panel field for the list and the search; a regex derived from the query on read.

Round 2:

- Spec: Enter, Up, Down, and Backspace with Ctrl or Alt acted. Fixed: one clause in `Search.key/3` drops a key with a modifier other than Shift.
- Spec: an end note hid `match not shown`. Fixed: the line shows both notes.
- Spec: an information run was searched joined with a new line but drawn as `· a · b`. Fixed: `infos_text/1` for both.
- Standards: the doc said a cell during a stream always gives `match not shown`; the item at the index is marked when it holds the query. Fixed in the doc, with a test.
- Spec: Ctrl+O does not move the view to a hidden match. Doc: a scroll or a change of the query reaches the row.
- Simplify (altitude): the guard of the search listed the keys it did not take. Fixed by the clause order in `Helyx.TUI`.
- Judgement, kept: the end notes as two clauses, `Footer.busy/2` with the tick message still in `Helyx.TUI` (the doc states the reason as the start and stop rule).

Round 3:

- Codex, spec, failure-path: Alt+Esc and Ctrl+Esc close the search. Decision: Escape closes the search with any modifier, as Escape aborts with any modifier outside the search (`Helyx.TUI`, the Escape clause). The doc states it.
- Standards: `transcript.ex` was 404 lines. Fixed in the small-fix round: the `@doc` of `find/5` is shorter, and the file is 400 lines.
- Failure-path: a mark falls on the bar of a user row for a query with a leading space, and `match not shown` does not show. Open: the fix needs `search.ex` and `transcript.ex`, which is more than a small-fix round allows. The doc states it as an open hole.
- Spec and failure-path: the `✕` of a notice is drawn but not search text. Doc: stated.
- Judgement: a modifier other than Ctrl or Alt (Super, Hyper, Meta) is also dropped. Doc: "a modifier other than Shift".

Small-fix round:

- Spec and failure-path: the open hole is wider than the bar and the fill: the `✕ ` of a notice, the indent of a result line, and the hint row of the short form also match (`more` with a match in hidden lines marks the hint). The same root cause: the row lookup and the marks scan the drawn row. Doc: the open hole names every sign and the fix. No code change.

## Guarantee table

S is `plugins/bundled/test/helyx/tui/search_test.exs`, T is `plugins/bundled/test/helyx/tui_test.exs`.

| Guarantee of `docs/features/tui-search.md` | Proof |
| ----------------------------------------- | ----- |
| Ctrl+F opens; the newest match comes first | S "Ctrl+F opens the search" |
| The line is in the rect of the composer; the height and the view do not change | T "the search line takes the rows of the composer" |
| The composer keeps its text | T "Ctrl+F finds text in place of the composer" |
| A long query is cut at the box edge | S "a match the view left" |
| A printable key adds; a named key and a modifier other than Shift do nothing | S "named keys and keys with Ctrl or Alt"; probe of round 3 and the small-fix round (Super, Hyper, Meta) |
| A paste: a new line is a space, a tab two spaces, controls drop, cut before the clean | S "the query has at most 256 bytes" |
| Backspace; an empty query has no match | S "Backspace removes the last character" |
| Enter and Up older, Down newer, end notes | S "Ctrl+F opens the search" |
| Escape closes with any modifier, keeps the view, starts no abort | S "Escape closes the search"; T "Ctrl+F finds text"; probe of the small-fix round |
| PgUp, wheel, drag, Ctrl+O, and Ctrl+C keep their rule | T "the search line takes the rows of the composer"; PgDn is the clause of PgUp |
| Literal and case-insensitive; no match across items | S "the query is literal and case-insensitive" |
| Search text of each kind, hidden lines, `· a · b` | S "a match in the lines the short form hides", "the search text holds tool calls" |
| A tab matches as two spaces | S "a tab matches as the two spaces" |
| The open message is searched; Markdown signs give `match not shown` | S "the open assistant message is searched" |
| A new query stays near the cursor | S "a new query stays at the match" |
| The view goes to the row of the match; yellow marks on drawn rows only | S "the view goes to the row of the match", "the marks cover each place" |
| `match not shown` after a scroll away, and next to an end note | S "a match the view left", "a match in the lines the short form hides" |
| `match not shown` across a row break | probe of round 3 (spec) |
| A cell during a stream: mark or `match not shown` | S "a cell that arrives during a stream" |
| `/new` and `/resume` close the search | `switch_test.exs` "/new ends the session"; `/resume` uses the same `Switch.bind/3` |
| Query bound of 256 bytes | S "the query has at most 256 bytes"; probe of round 2 (failure-path) |
| Open hole: the signs of a drawn row | probes of round 3 and the small-fix round |
