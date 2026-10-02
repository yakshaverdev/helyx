# Tool text out of Core

## Goal

Move the text helpers of `Helyx.Tool` out of Core, into a helper module of `plugins/bundled`, `Helyx.Text`. About 200 of the 259 lines of `lib/helyx/interfaces/tool.ex` are text utilities that only plugins need: `truncate/2`, `truncate/3`, `read_file/1`, `max_bytes/0`, and the UTF-8 edge rules. Core must stay small (AGENTS.md). After this change, `Helyx.Tool` holds only the behaviour, `by_name/1`, `spec/1`, and `hold/1`. Issue #121, from the Core cleanup plan (`docs/reviews/2026-09-26-core-cleanup-plan.md`).

One Core caller holds the helpers in Core: the session cuts the text of each harness tool result with `Helyx.Tool.truncate/2` (`harness_event/1`, `Helyx.Session.Stream` after #120). Core cannot call into `plugins/bundled`. So this change moves the responsibility for the cut from the session to the providers. That is a change of the `Helyx.Provider` contract.

`Helyx.Text` is a helper module as in ADR 0005, like `Helyx.Watchdog`: `@moduledoc false`, no interface, and no registration entry.

## Interface changes

`Helyx.Provider` moduledoc, the `{:tool_result, call_id, {:ok | :error, binary}}` event:

- Today: "the session cuts the text like a tool result (`Helyx.Tool.truncate/2`, `:tail`)".
- After: the provider cuts the text to the tool result limits before it sends the event, as a tool does. The session does not cut it. A result over `@max_tool_result_bytes` fails the turn.

`Helyx.Tool` loses `truncate/2`, `truncate/3`, `read_file/1`, and `max_bytes/0`. They move, unchanged, to `Helyx.Text` in `plugins/bundled/lib/helyx/text.ex`. The callers change to `Helyx.Text`: `Helyx.Tool.Read`, `Helyx.Tool.Edit`, `Helyx.Tool.Bash`, and `Helyx.ModelContext.Default`.

`Helyx.Provider.ClaudeCode` and `Helyx.Provider.Codex` call `Helyx.Text.truncate(text, :tail)` on each tool result before they emit it (`claude_code.ex:199`, `codex.ex:408`).

The old names are removed, with no delegate. Every caller is in this repository.

## The check in Core

Core checks the size of each harness tool result at the stream boundary, in `Helyx.Session.Stream`, in the place of the cut today:

- The limit is `@max_tool_result_bytes 65_536`. The output of `truncate/2` is at most 51,201 bytes of lines (51,200 bytes of line content and newlines, plus one trailing newline when the text is not cut) plus one notice line. The notice holds at most four line or byte numbers. The harness stdout line cap (16 MiB) holds each number to at most 8 digits, so the notice is less than 200 bytes. 65,536 bytes holds every output of `truncate/2` with room to spare. A result that is larger was not cut, so the provider broke the contract.
- The check runs on `byte_size/1` of the text as the provider sent it, before the UTF-8 repair. The repair (`String.replace_invalid/1`) runs after the check, in `Helyx.Session.Stream`, and can make the text up to three times larger. The row "tool result text validity" of `docs/features/coding-agent.md` already states that growth. The check measures what the provider controls.
- A result over the limit ends the stream with the terminal `{:error, {:tool_result_too_large, actual_bytes, 65_536}}`. The error does not hold the text.
- The turn fails through the existing path: `end_turn/2` with an error, then `fail_turn/2`. That path gives every open call its aborted result and closes the turn. The hands release the harness program at the end of the stream Task, as for any other terminal.

## Bounds

| What | Bound | Over the bound |
| ---- | ----- | -------------- |
| harness tool result text, as the provider sends it | 65,536 bytes (`@max_tool_result_bytes` in `Helyx.Session.Stream`), checked before the UTF-8 repair | the turn fails with `{:tool_result_too_large, actual_bytes, 65_536}`; the text is not kept |
| harness tool result text, after the provider cut | 2000 lines or 51,200 bytes of line content, on whole lines, by `Helyx.Text.truncate/2`, `:tail`, in the provider | See the row "tool result text" |
| tool result text, file read limit | unchanged: 2000 lines, 51,200 bytes, 10 MiB per file | unchanged |

The limit gets tests at 65,535, 65,536, and 65,537 bytes, and one with a multibyte character across the limit.

`docs/features/coding-agent.md` changes the row "Harness tool result text" (line 171) to the two harness rows above, and each mention of `Helyx.Tool.truncate` or `Helyx.Tool.read_file` to `Helyx.Text`.

## Ownership

No new resource. An oversized result fails the turn while the harness program runs. The stream Task returns the error terminal, and the hands release the program at delivery, as for any other terminal (the rows "Claude Code program" and "Codex program" of `docs/features/coding-agent.md`). An abort during the check is the abort of today.

## Tests

- The truncate and `read_file/1` tests, including the property test, move from `test/helyx/interfaces/tool_test.exs` to `plugins/bundled/test/helyx/text_test.exs`, with no change to their assertions. `plugins/bundled` adds `stream_data` as a test dependency, and its lock file is updated.
- `test/helyx/interfaces/tool_test.exs` holds only these tests, so the whole file moves. `by_name/1`, `spec/1`, and `hold/1` have their tests in `test/helyx/session/hands_test.exs` and the session test modules in `test/helyx/session/`. (Corrected in #121: the design said that the file keeps the tests of these three functions.)
- The ClaudeCode and Codex tests each get a test: a tool result over the limits arrives cut, with the notice.
- The session test "a harness tool result is cut like a tool result" (`test/helyx/session_test.exs:247`) is replaced by tests of the Core check: a result at the limit is recorded as sent; a result over the limit fails the turn with `{:tool_result_too_large, bytes, 65_536}`, the error holds no text, the open calls get their aborted results, and the session then accepts another prompt that completes a turn.

## Out of scope

- A byte limit on tool results of model turns. The tools cut their own results, and the hands run them.
- A change to the UTF-8 repair.
- A change to the limits of `truncate/2`.
