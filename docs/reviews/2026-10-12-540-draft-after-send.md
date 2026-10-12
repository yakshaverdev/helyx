# Review: #540 The waiting draft comes back after a recalled prompt is sent

Invariant: after an accepted send through `Helyx.TUI` (a message in `send_message/3`, or a `/model` switch in `switch_model/2`), `Helyx.TUI.Composer.restore/1` shows the draft that waited behind a recalled prompt, with its paste markers, its paste map, `count` kept, the cursor at its end, and `recall` nil. When no draft waits, the composer empties, and the paste map and `count` reset, as before. Down past the newest prompt calls the same `restore/1`, so with an empty draft it now resets `count` too; no marker lives on that path. A rejected send (a full queue, an ended session, a rejected model ref, a usage notice) changes nothing. Ctrl+C still drops the draft through `clear/1`.

Accepted holes: the composer text is unbounded human input (#29). Only one draft is kept (out of scope in the ticket). Paste entries whose marker a key that the composer does not intercept deleted stay in the map; they already waited with the draft before this change, and their size is bounded by what the user pasted.

Ticket correction: the ticket says "Ctrl+C and Esc still clear everything". Esc only aborts the turn (`tui.ex:211`); it never cleared the composer, and at an abort `queue_dropped` keeps the draft. The feature doc names only Ctrl+C.

Line limit: `composer.ex` was at 398 of 400 lines. `clear/1` now sets the text through the private `show/5`, so the public `restore/1` fits with no `.credo.exs` entry.

## Round 1 (full)

Simplify: reuse and efficiency found nothing. Simplification and standards noted that the key code `"up"` in `clear/1` only picks `textarea_set_value/2`; kept, because the direct form takes the file over the limit, and `show/5` documents the code argument. Skipped (altitude): reset `count` whenever the restored paste map is empty in place of the `draft != ""` guard. The guard gives the documented rule (a send that empties the composer starts the ids at `#1`) with no extra state.

Bounds sensor:

```
bounds sensor: 0 candidate functions, 0 flagged, 0 without an answer
```

| # | Axis | Finding | Resolution |
| - | ---- | ------- | ---------- |
| 1.1 | standards, spec | "A send that brings the draft back gives the draft its map and keeps `count`" had no test | Fixed: `tui_test.exs:1472` pastes after the draft comes back and gets marker `#2`, and the send expands both pastes. A mutation that resets `count` in `restore/1` fails it |
| 1.2 | standards, spec, failure path | The `recall` line ("`count` does not change") and the `pastes` row did not say that Down past the newest prompt with an empty draft now resets `count` | Fixed: both doc lines state it. No marker lives on that path, so no id repeats |
| 1.3 | spec | "Ctrl+C clears the draft too" had no test behind a recall | Fixed: `tui_test.exs:1501` (Ctrl+C on a recalled prompt, then Down brings nothing back) |
| 1.4 | standards | Judgement: `"up"` in `clear/1` reads as a key code | Kept, see "Line limit" |
| 1.5 | standards | Judgement: `restore/1` and `nothing_to_clear?/1` both match a non-empty draft | Kept: two clauses, too small for a helper, and the file has no room |
| 1.6 | standards | Nit: the new tests used `Helyx.Message` with the alias in scope | Fixed |
| 1.7 | spec | The ticket says Esc clears | Not a code finding; see "Ticket correction" |
| 1.8 | failure path | Probes through `TUI.handle_event/2` and `handle_info/2`: marker ids across a restore (draft `#1`, recalled paste `#2`, next paste `#3`, full expansion), a multibyte draft with a zero-width character (cursor at the end), Ctrl+C after a restore, Down with an empty draft, the composer height after a restore (the send sets `scroll: nil`, and the caller of `switch_model/2` runs `settle/1`). All pass. Not reached: a steer from a recalled prompt then `queue_dropped`, very large drafts | — |
| 1.9 | Codex | Approve, no findings | — |

Round 1 reproduced no defect, so the loop ends. The fixes are tests and doc text; no code changed after the round.
