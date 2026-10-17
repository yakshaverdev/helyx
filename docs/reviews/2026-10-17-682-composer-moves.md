# Review: Ctrl+A, Ctrl+E, and word moves in the composer (#682)

Scope: `Helyx.TUI.Composer.press/3`, the last key clause of `Helyx.TUI.handle_event/2`, the new internal module `Helyx.TUI.Composer.Paste`, the feature doc `docs/features/multiline-composer.md`, the key list of the `Helyx.TUI` moduledoc, and the key table of `apps/coding_agent/README.md`.

Invariant: every key press or repeat that no TUI key takes goes to `Composer.press/3`, which moves the cursor for Ctrl+A and Ctrl+E as Home and End and for Alt+B, Ctrl+Left, Alt+F, and Ctrl+Right one word; a marker is one word, so a word move never leaves the cursor inside a marker and never passes an end of a marker without a stop; every other key with a modifier but Shift does nothing; and the text sent equals the visible text with each live marker replaced by its own paste.

## Rounds

| Round | Type | Base | Simplify | Standards | Spec | Failure-path | Codex | Reproduced defects |
| ----- | ---- | ---- | -------- | --------- | ---- | ------------ | ----- | ------------------ |
| 1 | full | origin/master `27c04694` | 4 applied, 2 skipped | 1 hard, 1 test gap, 4 judgement | 1 test gap, 1 doc, 1 scope | 1 | 0 (approve) | 1 |
| 2 | full (over 100 code lines: 2 code files, a module added; reported before the round) | origin/master, working tree | 3 applied, 2 skipped | 1 test gap, 4 judgement | 0 defects, 1 judgement | 1 (2 paths) | 1 (needs-attention) | 1 (start inside a marker) |
| 3 | full (second finding on the word-move mechanism) | origin/master, working tree | 2 applied | 2 test gaps, 1 doc, 2 judgement | 0 defects, 1 doc | 0 | 0 (approve) | 0: the loop ends |

Bounds sensor:

- round 1: `bounds sensor: 0 candidate functions, 0 flagged, 0 without an answer`
- round 2: `bounds sensor: 3 candidate functions, 0 flagged, 0 without an answer`
- round 3: `bounds sensor: 3 candidate functions, 0 flagged, 0 without an answer`

## Findings and resolution

Round 1:

- Failure-path: the textarea counts U+0001, the end of a marker, in the class of letters, so in `ab[marker]cd` the word `\u0001cd` starts inside the marker. Alt+B from the end went to the marker start and skipped `cd`. Fixed: a word move that ends inside a marker stops at the first end of the marker that it passes (`word_end/3`). Test: `composer_test.exs`, "a word move stops at an end of a paste marker, never inside it".
- Standards (hard): `.credo.exs` says "The list only shrinks", and the round added an allowance entry for `composer.ex` at 418 lines. Fixed: no entry; the paste rule (the clean text, the marker form, the expansion) moved into `Helyx.TUI.Composer.Paste`, which owns those decisions, and `composer.ex` is 400 lines.
- Standards and spec: "they do not scroll" and "goes to the line before or after" had no test, and the forward check of the marker test could not fail. Fixed: exact column lists for each key, a test across lines, and an empty-composer test.
- Spec: the doc said that every other key inside a marker first goes to the marker end. Fixed: the doc names the word moves as an exception.
- Simplify: one `out_of_marker` rule, `key/3` with modifiers, one `column/1` helper. Skipped: Home and End through `press/3`, because the formatter breaks the `cond` of `tui.ex` and the file goes to 401 lines; one move-then-snap rule for Left and Right too, which is outside the ticket.

Round 2:

- Codex and failure-path: a word move that starts inside a marker, where Up or Down can leave the cursor, can leave the marker in one widget step: before U+0001 forward it went to the next row, and after the `[` that follows `(` back it went past the marker start. Second finding on one mechanism, so the mechanism is now complete: a move from inside a marker goes to its start or end with no widget move, and a move that ends inside one stops at the first end that it passes. Test: the same test, the rows of `inside`; red without the fix.
- Standards (test gap): the empty-composer test passed also if Ctrl+A and Ctrl+E took the scroll path. Fixed in round 3.
- Spec (judgement): a marker with a space after it has one more stop than a plain word, its end. Accepted, recorded under accepted holes in the feature doc.
- Spec: the move of the paste rule changed no behaviour; the probe compared 24 marker and clean pairs and 12 expand pairs with the origin/master functions.
- Simplify: two plain loops in the marker test, a `@doc` without the literal line count, a cross-reference from the key-code filter to `Composer.Paste`. Skipped: `count + 1` bound once, because `composer.ex` goes to 401 lines.

Round 3:

- No reproduced defect. Codex ran 50,328 word-move probes, the failure-path agent about 3000 random walks with 769 moves from inside a marker; both found no break of the invariant.
- Standards (test gaps): the `from < start` clause of `word_end/3` had no test, and the Ctrl+E half of the empty-composer test could not fail. Fixed: a forward walk over `x([marker]cd` from column 1, red without the clause, and Ctrl+E from a held scroll keeps the scroll.
- Standards and spec (doc): an unmapped Ctrl or Alt key inside a marker leaves the cursor there, and the doc said every other key goes to the marker end. Fixed: the doc says so.
- Judgement, not changed: the widget move runs in the `case` condition of `press/3` (the comment says so); the name `word_end/3`.

## Accepted holes

- Ctrl+A and Ctrl+E with an empty composer do nothing; they do not scroll as Home and End do.
- A marker with a space after it has one more word stop than a plain word: its end.
- Alt+B and Alt+F reach the TUI only where the terminal sends Option or Alt as Meta; the system can take Ctrl+Left and Ctrl+Right.
- Not reached by the probes: word moves while the search or the session list is open (their handlers take the keys first), a composer of more than about 1 MB, and the keys from a real terminal.
