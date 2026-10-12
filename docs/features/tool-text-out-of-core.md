# Tool text out of Core

## Goal

Move the text helpers of `Helyx.Tool` out of Core, into a helper module of `plugins/bundled`, `Helyx.Text`. About 200 of the 259 lines of `lib/helyx/interfaces/tool.ex` are text utilities that only plugins need: `truncate/2`, `truncate/3`, `read_file/1`, `max_bytes/0`, and the UTF-8 edge rules. Core must stay small (AGENTS.md). After this change, `Helyx.Tool` holds only the behaviour, `by_name/1`, `spec/1`, and `hold/1`. Issue #121, from the Core cleanup plan (`docs/reviews/2026-09-26-core-cleanup-plan.md`).

One Core caller holds the helpers in Core: the session cuts the text of each harness tool result with `Helyx.Tool.truncate/2` (`harness_event/1`, `Helyx.Session.Stream` after #120). Core cannot call into `plugins/bundled`. So this change moves the responsibility for the cut from the session to the providers. That is a change of the `Helyx.Provider` contract.

`Helyx.Text` is a helper module as in ADR 0005, like `Helyx.Watchdog`: `@moduledoc false`, no interface, and no registration entry.

## Interface changes

`Helyx.Provider` moduledoc, the `{:tool_result, call_id, {:ok | :error, binary}}` event:

- Today: "the session cuts the text like a tool result (`Helyx.Tool.truncate/2`, `:tail`)".
- After: the provider cuts the text to the tool result limits before it sends the event, as a tool does. Core then cuts a result over 65,536 bytes to a notice line, its head, a marker line, and its tail, and the turn goes on (#508, "The cut in Core").

`Helyx.Tool` loses `truncate/2`, `truncate/3`, `read_file/1`, and `max_bytes/0`. They move, unchanged, to `Helyx.Text` in `plugins/bundled/lib/helyx/text.ex`. The callers change to `Helyx.Text`: `Helyx.Tool.Read`, `Helyx.Tool.Edit`, `Helyx.Tool.Bash`, and `Helyx.ModelContext.Default`.

`Helyx.Provider.ClaudeCode` and `Helyx.Provider.Codex` call `Helyx.Text.truncate(text, :tail)` on each tool result before they emit it (`claude_code/turn.ex`, `codex/items.ex`).

The old names are removed, with no delegate. Every caller is in this repository.

## The cut in Core

#121 made Core check the size of each harness tool result in `Helyx.Session.Stream` and fail the turn over 65,536 bytes. #508 (`docs/reviews/2026-10-12-domain-review.md`, A1 and Q2) replaced the check with a cut: `Helyx.Message.cut_result/1` makes the text valid UTF-8, then puts a notice line first and keeps its head and its tail, each half of the room and cut on a character boundary, with a marker line between them; the whole result is at most 65,536 bytes. The harness model already has the full text, and only Helyx's copy is cut. The hands call the same function for every result of a Helyx tool, and the session file reader for every tool result text on resume. `Helyx.Text.truncate/2` repairs invalid UTF-8 before it counts, and checks at compile time that its output fits the limit, so Core never cuts the output of `truncate/2` a second time.

## Replaced mechanism (#508)

1. The terminal `{:error, {:tool_result_too_large, bytes, 65_536}}` and its path (`too_large/1` in `Helyx.Session.Stream`) are deleted. A result over the limit is cut by `Helyx.Message.cut_result/1` instead, and the turn goes on. The check before the UTF-8 repair is deleted with it: the cut runs after the repair, so the repair cannot pass the limit.
2. `@max_tool_result_bytes` in `Helyx.Session.Stream` and its comment arithmetic are deleted. `@max_result_bytes` in `Helyx.Message` is the one limit, and `Helyx.Text` asserts against `Helyx.Message.max_result_bytes/0`.
3. `Helyx.Message.scrub/1` is deleted. `cut_result/1` does the repair and the cut, and the hands and `Helyx.Session.Stream` call it where they called `scrub/1`.
4. In `Helyx.Session.Hands`, the atoms `:unknown` and `:no_cwd` in the tool slot and their `run_tool/3` clauses are deleted. An unknown tool and a missing working directory are answered at once, as a refusal is; no Task starts and no `release/3` is called for them.
5. Tests of the old rule: the test that a result over 65,536 bytes fails the turn, gives the open call `aborted`, and lets the next prompt run, becomes the test that the result is cut with the notice and the turn ends `:done`. The test that 65,536 invalid bytes are kept as 196,608 bytes becomes the test that 60,000 invalid bytes are stored valid and within the limit. The tests at 65,535 and 65,536 bytes keep their assertions.
6. What the user sees: a tool result over 64 KiB shows the line `[cut to <kept> of <total> bytes, start and end kept]`, its head, the line `[… cut …]`, and its tail, and the turn goes on. The notice comes first, so a client that shows only the first lines, such as the TUI preview, shows it. The tail keeps the errors and the exit code at the end of the output for the model and the stored transcript; the TUI preview of four lines does not show the tail. Before, the turn failed with `tool_result_too_large`, and the output was lost.
7. No state with no bound is added, but the repair before the cut makes a copy of up to three times its input, and Core sets no bound on that input. Before #508, `Helyx.Session.Stream` rejected a result over 65,536 bytes before the repair; now it repairs the whole text first. The input is bounded only by its source: the harness stdout line cap (16 MiB) for the bundled harness providers, so a copy of up to about 48 MiB, in `Helyx.Text.truncate/2` and in the cut; the bash output cap for the bundled tool; the 64 MiB file limit on resume. A provider that runs in the VM, a third-party tool, or the message of an exception it raises is already in memory when Core gets it, and is not bounded before the cut. Accepted: the copy is transient, and the order (repair, then cut) is the ticket's decision.

## Bounds

| What | Bound | Over the bound |
| ---- | ----- | -------------- |
| harness tool result text, after the UTF-8 repair (#508) | 65,536 bytes, notice included (`Helyx.Message.cut_result/1`) | a notice line, the head, a marker line, and the tail; the turn goes on |
| harness tool result text, after the provider cut | 2000 lines or 51,200 bytes of line content, on whole lines, by `Helyx.Text.truncate/2`, `:tail`, in the provider | See the row "tool result text" |
| tool result text, file read limit | unchanged: 2000 lines, 51,200 bytes, 10 MiB per file | unchanged |

The limit gets tests at 65,535, 65,536, and 65,537 bytes, and one with a multibyte character across the limit.

`docs/features/coding-agent.md` changes the row "Harness tool result text" (line 171) to the two harness rows above, and each mention of `Helyx.Tool.truncate` or `Helyx.Tool.read_file` to `Helyx.Text`.

## Ownership

No new resource. A result over the limit is cut in the provider process, and the turn goes on; the harness program is released as for any other turn (the rows "Claude Code program" and "Codex program" of `docs/features/coding-agent.md`).

## Tests

- The truncate and `read_file/1` tests, including the property test, move from `test/helyx/interfaces/tool_test.exs` to `plugins/bundled/test/helyx/text_test.exs`, with no change to their assertions. `plugins/bundled` adds `stream_data` as a test dependency, and its lock file is updated.
- `test/helyx/interfaces/tool_test.exs` holds only these tests, so the whole file moves. `by_name/1`, `spec/1`, and `hold/1` have their tests in `test/helyx/session/hands_test.exs` and the session test modules in `test/helyx/session/`. (Corrected in #121: the design said that the file keeps the tests of these three functions.)
- The ClaudeCode and Codex tests each get a test: a tool result over the limits arrives cut, with the notice.
- Tests of the Core cut (#508): a result at the limit and one under it is recorded as sent; a result over the limit, one with a multibyte character across it, and one of invalid bytes are cut to the limit with the notice, and the turn ends `:done`.

## Out of scope

- A change to the UTF-8 repair.
- A change to the limits of `truncate/2`.
