# Diff blocks

Builds the `diff` kind of `docs/features/ui-blocks.md` (ADR 0011 §5, part of #853).

## Goal

A user supervises several sessions from the desktop app and from the TUI. Under each `edit` and `write` call, the user sees what the agent changed: the path, the added and removed line counts, and the changed lines with three lines of context. Today an edit result is `Edited <path>`, so the user must open the file to see the change.

The block rides on the tool result, so it shows live, after a resume, and in a client that joins later (ADR 0011 §3). The model's result text does not change. A client that cannot render the kind shows the block's `text`, a unified diff.

## Interface changes

### `Helyx.Diff`

A helper module (`@moduledoc false`, ADR 0005) with two functions:

- `block(path, old_text, new_text, from_line_hint \\ nil)` returns the `diff` block of a change. `from_line_hint` is the file line number of the first line of the texts, 1 by default, so that `old_start` and `new_start` of a hunk are file line numbers.
- `unreadable(path, reason)` returns the block of a write whose old file is not read: `hunks: []`, `cut: true`, and a text that names the reason. Its `added` and `removed` are absent, because the old text is unknown.

The block:

```json
{"kind": "diff", "text": "<unified diff>", "path": "lib/a.ex",
 "added": 3, "removed": 1,
 "hunks": [{"old_start": 10, "old_lines": 5, "new_start": 10, "new_lines": 7,
            "lines": [" ctx", "-old", "+new", " ctx"]}]}
```

- The common first and last lines of the two texts are taken off first, and the hunks come from `List.myers_difference/2` over the middles alone, so a large file with a small change costs a walk of its lines. Each hunk holds `context_lines/0` lines around a change, and two changes share a hunk when the equal lines between them are at most twice the context.
- Each line is one sign of `" "`, `"-"`, or `"+"`, then the line without its line end. A trailing `"\r"` is dropped, so a CRLF file shows no carriage return. A line over `line_bytes/0` is cut at a character boundary with ` …` appended.
- `text` is the unified diff: `--- a/<path>` and `+++ b/<path>`, then for each hunk `@@ -o,ol +n,nl @@` and its lines. A client that cannot render the kind shows it.
- `cut: true` is present when the emitter left out lines or cut a line. A block over the JSON bound is cut by the session to `{kind, text, cut: true}` (`Helyx.UIBlock.check/1`), as for any block, because JSON escapes can double the bytes of a line.

### The tools

- `Helyx.Tool.Edit.run/2` returns `{:ok, "Edited <path>", [block]}`. The text is byte for byte the text of today. An error result keeps `{:error, text}` and gets no block.
- `Helyx.Tool.Write.run/2` reads the old file with `Helyx.Text.read_file/2` after `regular_or_missing/1` and before the write, then returns `{:ok, "Wrote <path>", [block]}`. A missing file is an empty old text, so every line is a `+`. A file that the read refuses keeps the write, and the block of `unreadable/2` names the reason. An error result gets no block.

### The edit window

An edit never diffs the whole file: a file can hold `Helyx.Text.max_file_bytes/0` bytes, and its diff is not the change that the user needs. The tool expands the replaced byte range to whole lines, takes `context_lines/0` lines on each side from the file, and diffs only that window with the same `block/4`, which gets the file line number of the window's first line. A large file therefore costs a scan to the change and a small diff, not a diff of every line.

## Replaced mechanism

The return of `Helyx.Tool.Edit.run/2` and `Helyx.Tool.Write.run/2` changes from `{:ok, text}` to `{:ok, text, [block]}`. The status, the result text, the error results, and the file effects are the same; the block is a new third element, and the session's handling of it is the path that `docs/features/ui-blocks.md` already defines.

1. The result text stays `Edited <path>` and `Wrote <path>`, and the failure texts stay as they are.
2. No reply is removed.
3. The tests of the tools keep their property: the file changes as before, and the text is the same. They add the block.
4. A user sees the diff under the call, where before the call showed its result text alone. The model sees no change.
5. No state without a bound.

## Bounds

| What | Bound | Over the bound | Where |
| ---- | ----- | -------------- | ----- |
| one line of a block | `Helyx.Diff.line_bytes/0` bytes. A source line is readable at that width, and one line adds at most twice that to the block | cut at a character boundary with ` …` appended, and `cut: true` | `Helyx.Diff` |
| the lines of one block | `Helyx.Diff.budget_bytes/0` bytes of the lines as `text` writes them, line ends included and counted once although each line is also in `hunks`. The block stays near 50 KB, under the 65,536-byte bound of `Helyx.UIBlock.check/1` unless JSON escapes many characters | the lines past it are left out, and `cut: true`. A hunk that the budget stops keeps the lines that fit, so its counts match them. `added` and `removed` still count every line | `Helyx.Diff` |
| the middle of a diff (the two texts after their common first and last lines) | `Helyx.Diff.max_diff_lines/0` lines on either side. `List.myers_difference/2` costs O((N+M)·D), and the common lines around a change are taken off before the search. A middle at the bound with every line different measured 0.8 s for a block on a 10-core machine with a load average near 18, and 0.4 s in an earlier run at a lower load; a tool call is abortable | no diff: `hunks: []`, `cut: true`, the exact line counts, and a text that names the bound | `Helyx.Diff` |
| one text of a diff | `Helyx.Text.max_file_bytes/0` bytes, the read bound of the tools, kept as the bound of the split. A text over it is not split into lines, so a file that a tool reads always splits, and a larger text costs one walk of its bytes | no split: the line counts are exact and the text names the line bound | `Helyx.Diff` |
| the path of a block | `Helyx.Diff.max_path_bytes/0` bytes, the path argument of the call as the model gave it | cut at a character boundary | `Helyx.Diff` |
| the context of a hunk | `Helyx.Diff.context_lines/0` lines on each side. Three lines place a change in its function or block | the start or the end of the file | `Helyx.Diff` |
| one block | `Helyx.Message.max_result_bytes/0` bytes of JSON (`Helyx.UIBlock.max_bytes/0`) | the session cuts it to `{kind, text, cut: true}`, as any block | `Helyx.UIBlock.check/1` |
| the text of an edit | the lines of the replaced range plus the context, never the file. The file bound is that of the read, `Helyx.Text.max_file_bytes/0` | n/a: an edit of a larger file fails at the read | `Helyx.Tool.Edit` |

Tests at the limits: a line of `line_bytes/0` bytes, and one more with a multibyte character at the cut; the exact `budget_bytes/0` and one line more; a middle at `max_diff_lines/0` and one more; a text at the split bound and one more; a large text with one changed line; a change at the first line and at the last line; two equal texts; two changes at twice the context and one line more; a block at the budget with quotes and control characters, checked as `{:ok, same_block}`.

## Ownership

None: a block holds no external resource, and the tools read and write their file as before.

## Out of scope

Rendering in the GPUI app, which a later ticket builds from the shape above. A change to the TUI renderer: the TUI shows the block's `text`, as it shows an unknown kind. Diffs for the files that `bash` changes. A diff of the whole session or of the worktree. Accept and reject actions: the block is a result, not an input block.
