# Review: Up and Down recall earlier prompts (#469)

Date: 2026-10-04. Base: `origin/master` ac6eff9.

Invariant: Up on the first composer row and Down on the last row, as a press or repeat with no modifier, reach `Helyx.TUI.handle_event/2` and then `Helyx.TUI.Composer.recall/3`, which walks the user messages of the view model through `Helyx.TUI.ViewModel.prompt/3` newest first and back to the saved draft with its paste markers and pastes, never changes the history, cleans recalled text as a paste so it cannot forge a paste marker, and otherwise moves the cursor as before. Accepted holes: an edit to a recalled prompt is lost on the next recall, a paste made inside a recalled prompt is dropped when the user moves on, and one key press walks up to the whole cell array when no user message lies between.

Checked before the build: ExRatatui 0.14.1 `textarea_cursor/1` gives the logical `{row, column}` from 0, and the textarea does not wrap (a long line scrolls sideways), so the logical row is the drawn row. Up and Down reached `Helyx.TUI.handle_event/2` before the change, through the last `%Key{}` clause, and went to the widget.

## Bounds sensor

```text
bounds sensor: 3 candidate functions, 0 flagged, 0 without an answer
```

## Simplify

- Reuse, simplification, altitude: `prompt/3` copied `Helyx.Message.text/1`. Fixed: it calls it.
- Simplification: the `Stream.iterate` walk became one range; the nested draft tuple became `{at, value, pastes}`.
- Reuse: recall dropped control characters but did not turn CR into LF, as a paste does. Fixed: `clean/1` serves both.
- Efficiency: two NIF calls on a plain Down in the draft. Skipped: negligible.
- Simplification: `show/5` takes the key to place the cursor; `ViewModel.prompt/3` could take the key code. Skipped: the view model knows no keys.
- Reuse: `press/3` and `drain/1` repeat helpers of `tui_test.exs`. Skipped: other workers change `tui_test.exs` now, so a shared helper would conflict.
- Altitude: `edit/3` of `Helyx.TUI` became `edit/2` with an `edit/3` wrapper. Kept: the height check must read the rows before the change, and the wrapper leaves every caller of `edit/3` as it was.

## Round 1 (full)

| Axis | Finding | Resolution |
| --- | --- | --- |
| Standards | Doc: "the composer map holds the markers of the recalled text only" is empty or false | Reworded: the map starts empty and holds only the markers of pastes made in the recalled prompt. |
| Standards | `prompt/3` `@doc` states a cost, which belongs in the feature doc | Cut; the bounds table has it. |
| Standards | `edit/2` beside `edit/3` in shared TUI code | Judgement, kept (see Simplify). |
| Standards | The key string drives four branches; the draft tuple travels through three functions; `Composer` takes the whole view model | Judgement, skipped: each branch is one line, and the tuple has one writer. |
| Standards | `composer_test.exs` drives `Helyx.TUI.handle_event/2`; `prompt/3` has no test of its own | Judgement, kept: the tests reach `Composer.recall/3` and `prompt/3` through the key boundary, and a new file avoids `tui_test.exs`, which other workers change now. |
| Spec | Doc: "Up or Down shows the stored prompt again" is not precise | Reworded: the next recall replaces the edit with a stored prompt or the draft. |
| Spec | A rejected send keeps `recall`; the doc did not say it | Added to the doc. |
| Spec | No test of a follow-up that became a user message | Judgement, skipped: `prompt/3` reads every user message cell, and the fold makes the same cell for a prompt, a steer, and a follow-up. |
| Spec | Recall cleans the text, not "as stored" | Kept and stated in the doc: without it a resumed message could forge a marker that a later paste expands. |
| Failure path | None reproduced | Probed through `handle_event/2`: multibyte and zero-width drafts, a prompt that ends with a new line, a paste in a recalled prompt, an empty user message, the cursor inside a draft marker, 2000 cells. Not reached: a steer delivered by a live turn while a prompt shows; combining characters other than U+200B. |
| Codex adversarial | Approve, no material findings | None. Eight tests and five probes passed. |

No defect was reproduced, so the loop ends after round 1.
