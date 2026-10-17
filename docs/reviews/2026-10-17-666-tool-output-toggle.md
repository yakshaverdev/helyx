# Review: Ctrl+O toggles the full text of tool results (#666)

Scope: the working tree against `origin/master` (`cb5e7b4b`). Feature doc: `docs/features/tui-tool-output-toggle.md`.

Invariant: Ctrl+O switches every tool result between four lines with a hint row and its full text; the frame, the scroll keys, the wheel, and the copy read one form, and after a press no row address of the old form survives.

## Round 1 (full)

Simplify, four agents. Fixed: the result rows are one wrap of the kept lines through `styled_lines/3`, not an inline copy of the row build; the open calls of the streaming message keep their 4-tuple, and only an expanded tool item carries `true`. Skipped: `ViewModel.from_snapshot/2` with the old view model in place of the `match?` in `Switch.bind/3` (one line, one field); `key/3` with modifiers in `switch_test.exs`; one build of the rows of an item for each frame (it exists on master, and it needs a row cache).

Bounds sensor: `bounds sensor: 8 candidate functions, 0 flagged, 0 without an answer`.

| Source | Finding | Resolution |
| ------ | ------- | ---------- |
| Codex | approve, no findings | none |
| failure path, spec | Ctrl+O kept the selection. Reproduced: drag over expanded rows, Ctrl+O, release copied `(ctrl+o to expand)` | Fixed: the Ctrl+O clause clears the selection, as a new size does; test in `tui_test.exs` |
| spec | "only visible rows are styled" holds for the draw, not for the build | Accepted deviation, stated in the feature doc: the scroll rule counts the rows of an item, and that needs its wrap |
| spec | bounds row did not name the hand-edited-file hole of the 65,536-byte bound | Fixed in the feature doc |
| spec | the feature doc said the composer drops a Ctrl key; it is the last key clause of `Helyx.TUI` | Fixed |
| spec | the `coding-agent.md` sentence "at most four content lines" read as a contradiction | Fixed: two forms |
| standards | Out of scope named no tickets | Fixed: search is #668; the rest has no ticket, with the reason |
| standards | idiom and a measurement in code comments | Fixed |
| standards | `join_info/3` also marks tool cells | Renamed `add_item/3` |
| standards, spec | guarantees with no test: off at mount, no event changes it, full form of a cut result, the `/resume` list takes the key, the copy reads the expanded rows | Tests added |
| standards | 5-tuple tool item, `match?` in `Switch.bind/3` | Kept: judgement calls |

## Round 2 (full: the fix touched `tui.ex` and `transcript.ex`)

Simplify, four agents. Fixed: the `Helyx.TUI.Selection` moduledoc and the mouse sentence of `coding-agent.md` name Ctrl+O; a comment wrap; a duplicated test line. Skipped: `key/3` with modifiers.

Bounds sensor: `bounds sensor: 8 candidate functions, 0 flagged, 0 without an answer`.

| Source | Finding | Resolution |
| ------ | ------- | ---------- |
| failure path | no second path that breaks the selection invariant | none |
| spec | a collapse while scrolled deep in an expanded result moved the view past the tool cell. Reproduced: 20-line result at `{0, 15}`, Ctrl+O, view at `{2, 0}` | Fixed: `Transcript.keep/4` keeps the row when the item still has it, else row 0 of that item, then the rule of `hold/4`; test "a row that a collapse removes starts the view at its tool cell" |
| Codex | a tool result that arrives under a selection changes the selected rows, so the copy holds text the user did not see | Rejected as a new defect: it is the accepted hole of `docs/features/coding-agent.md` (the mouse), on master for every cell that changes its rows. The feature doc now states that the toggle makes the change larger |
| standards | bounds row 2 did not name the hole of row 1 | Fixed |
| standards | weak test of "the text that Core removed does not come back" | Fixed: a removed middle line is refuted |
| standards | "at the start" in `coding-agent.md`; a reason in a code comment; a duplicated view model in a test | Fixed |

## Round 3 (full: the fix added `Transcript.keep/4`)

Simplify, four agents. Fixed: `settle/2` takes the position rule, so the Ctrl+O clause has no second nil check. Skipped: a passed row count to save one wrap on a key press.

Bounds sensor: `bounds sensor: 9 candidate functions, 0 flagged, 0 without an answer`.

| Source | Finding | Resolution |
| ------ | ------- | ---------- |
| Codex | approve, no findings (180 layouts probed) | none |
| failure path | no reproduced finding: 1,311 scrolled presses in a random walk of keys and sizes, 0 breaks | none |
| spec | no defect; the round 2 reproduction passes | none |
| standards | the feature doc said Ctrl+O is free; "not five" rows; the `hold/4` doc said every position comes from it; "one truncation row" | Fixed, wording only |
| standards | a helper `item_rows/2` for the row count | Skipped: optional |

The loop ends: round 3 reproduced no defect.
