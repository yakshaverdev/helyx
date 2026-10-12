# Review: #508 One cut for tool results

Invariant: every tool result is at most 65,536 bytes of valid UTF-8, the user sees the cut notice first, the tail is kept, and a second cut changes nothing. Every tool result text that enters the session passes `Helyx.Message.cut_result/1` at its entry point: a Helyx tool through `Hands.outcome/3` (run output, crash text, bad return, unknown tool, missing cwd, refusal, unconfirmed release), a provider `tool_result` event through `Stream.check/1`, and a tool result read from the session file through `Session.File.Codec.decode/1`. The text is then valid UTF-8 of at most 65,536 bytes with its notice, with the notice line first, then the head and the tail, each cut on a character boundary after the repair, with a marker line between them, and a large result never fails the turn. An unknown tool and a missing cwd are answered without a Task. `Helyx.Text.truncate/2` repairs before it counts, and asserts at compile time that its output fits the Core limit. Accepted: the repair of a large input copies up to three times its size before the cut, the hands cut inside their GenServer, and a session file edited by hand with several text blocks in one result resumes each block cut on its own, within the 64 MiB file limit.

## Round 1 (full)

Simplify: `cut/1` derives the total in its own clause (simplification); the one-caller spawn wrapper inlined (simplification). Skipped: the Core head cut shares no code with `Helyx.Text.cap/3` (Core must not call the plugin; reuse); the tests keep the literal 65,536, the documented bound (reuse, simplification); the cut moved into the tool Task (efficiency: the ticket puts it in `outcome/3`); a repaired-size count without the copy (efficiency: ticket order is repair, then cut).

Bounds sensor:

```
bounds sensor: 1 candidate functions, 0 flagged, 1 without an answer
  lib/helyx/data/message.ex:240  NO ANSWER (TimeoutError('The read operation timed out'))  defp cut(text) do
```

| # | Axis | Finding | Resolution |
| - | ---- | ------- | ---------- |
| 1.1 | Codex, failure path, spec | `Helyx.Text.truncate/2` counted raw bytes, and the hands repaired after it. Bash output of invalid bytes (48,004 bytes, 600 lines) grew to 142,804 bytes, and Core cut it again from the head: the tail with the exit status was lost, and two notices showed. The compile-time check did not prove its claim. Reproduced | Fixed: `truncate/2` and `truncate/3` repair invalid UTF-8 before the caps; test with 4,000 invalid lines and an exit line: the tail is kept and `cut_result/1` leaves the output unchanged |
| 1.2 | spec | The bound "every tool result in the transcript" did not hold after a resume: the file reader put a tool result of any size into the transcript (a file before #300 had no limit, a file before #508 up to 196,608 bytes) | Fixed: `Session.File.Codec.decode/1` applies `cut_result/1` to each text block of a tool result; test with a 100,000-byte result on disk. Wider than the ticket's design list; it holds the ticket's bound on the disk path |
| 1.3 | standards | No "Replaced mechanism" section for the deleted fail-the-turn rule | Fixed: section in `docs/features/tool-text-out-of-core.md` |
| 1.4 | standards | `Message.tool_result/2` doc said every text went through `cut_result/1`; `Transcript.aborted/1` writes a fixed text | Fixed: the doc states the bound and names the session's own short texts |
| 1.5 | standards | No test one byte under the limit in the unit test | Fixed: 65,535, 65,536, and 65,537 bytes in `message_test.exs` |
| 1.6 | standards | A Core comment named `Helyx.Text`; `refuse/3` a one-line middle man; `elem(1)` hid the dropped pid | Fixed |
| 1.7 | spec | `provider_process_tools_test.exs` matched only `"xxx" <> _` for the cut echo | Fixed: asserts the size and the notice |
| 1.8 | spec | `docs/features/session-stream.md:71` still said Stream checks 65,536 bytes | Fixed |
| 1.9 | standards | The `Helyx.Text` comment "pi's read and bash defaults" cites another harness | Not changed: outside the diff, and a Helyx reason for the number is not recorded |
| 1.10 | standards | The provider cut stays in the contract while Core also cuts | Kept: the owner decision (domain review section 12); the Core cut is the safety bound |
| 1.11 | failure path | Note: a provider result over 64 KiB is now repaired whole before the cut (16 MiB invalid: 338 ms, about 48 MiB transient) | Accepted, stated in the replaced mechanism section; the input is bounded by its source |
| 1.12 | failure path | Held: `cut_result/1` at 65,535 to 655,360 bytes, 2- to 4-byte characters across the cut, 600 random binaries; the direct answer starts no Task | — |

The fix changes about 40 code lines in four code files and adds functions, so round 2 is full.

## Round 2 (full)

Fix of round 1, counted from its diff: about 40 code lines added plus removed in 4 code files (`text.ex`, `codec.ex`, `hands.ex`, `message.ex`); it adds functions, so the round is full.

Simplify: `cut_result/1` takes and returns a text, so no caller builds a status only to drop it (simplification, altitude); the codec cut is one clause per block (simplification); the "tool result text validity" row of `coding-agent.md` merged into the bound row (simplification). Skipped: one public repair helper for `Helyx.Message` and `Helyx.Text` (reuse: one line, and a new public function for it); `repair/1` only in the `:tail` clause, and no repair on resume (efficiency: `read_file/1` and the JSON decode already give valid text, but the extra scan costs about 4 ms per MiB and keeps `truncate/2` true for any caller).

Bounds sensor:

```
bounds sensor: 4 candidate functions, 0 flagged, 0 without an answer
```

| # | Axis | Finding | Resolution |
| - | ---- | ------- | ---------- |
| 2.1 | Codex | Verdict approve: no finding | — |
| 2.2 | failure path | Round-1 reproductions pass: bash output of invalid bytes keeps `END` with one notice and no Core cut; a 100,000-byte result on disk resumes at 65,536 bytes. `cut_result/1` held for every length from 65,500 to 65,560 with each trailing character class | — |
| 2.3 | failure path, altitude | A hand-edited session file with many text blocks in one tool result resumes over the limit (2 blocks of 60,000 bytes: 120,000 bytes; 900 blocks: 58.5 MB), because the reader cuts each block on its own. Reproduced | Accepted hole (owner decision after round 2): only a session file edited by hand can put several text blocks in one result, and the 64 MiB file limit bounds it. The code does not change; the `coding-agent.md` bound row states it |
| 2.4 | spec | The TUI shows the first 4 lines of a result and `… N more lines`, so the notice at the end of a cut result of 5 or more lines is not shown in the transcript (`result_lines/2` in `Helyx.TUI.Transcript`). The head notice of `Helyx.Text.truncate/2` has the same place. Read from the code | Fixed in round 3 (owner decision): `cut_result/1` puts the notice line first, so the TUI preview and the model see it; the TUI does not change, and the notices of `Helyx.Text.truncate` stay as they are |
| 2.5 | spec | Replaced mechanism item 7 named only two input sources for the repair copy; an in-VM provider and a third-party tool are not bounded before the cut | Fixed: item 7 names every source and states the copy as accepted |
| 2.6 | spec | The bash result adds a prefix and an exit line (about 130 bytes) around the `truncate/2` output, which the compile-time check does not count | Kept: the result fits by about 14 KB; the doc claims only that the output of `truncate/2` is not cut again |
| 2.7 | spec | The `cut_result/1` doc said "every invalid byte"; the repair replaces each invalid sequence | Fixed |
| 2.8 | standards | `tool-text-out-of-core.md` kept false sentences of #121 (the "After" line, Ownership, Tests, Out of scope) | Fixed: the sentences are rewritten to the state after #508; the #121 design text of the Core check is replaced by a short history |
| 2.9 | standards | Names: `bound/2` and `valid/1` read as a noun and an adjective; `(#508)` in a code comment | Fixed: `cut_text/2`, `repair/1`, the ticket number removed |
| 2.10 | standards | The tests write the literal 65,536 | Kept: the tests state the documented bound |

Round 2 reproduced only 2.3, a ceiling that the doc stated before the round, so the loop ends. The fixes of this round are wording, docs, and renames.

## Round 3 (reduced)

Owner decisions after round 2: the notice goes first (2.4), the multi-block resume is an accepted hole (2.3), and the "pi's read and bash defaults" comment in `text.ex` stays (1.9).

Fix, counted from its diff against `28e1fa8` without test files and Markdown: 11 lines added plus removed in 1 code file (`message.ex`: the `notice/2` text, the order of the concatenation, and the doc). It adds or removes no function and changes no arity, return type, or spec, so the round is reduced. The `Helyx.Tool` moduledoc wording came after the round (3.3). Tests: every assertion of the notice place is now notice first, and `tui_test.exs` checks that the preview of a cut result of 20,000 lines shows `[cut at`.

Bounds sensor:

```
bounds sensor: 1 candidate functions, 0 flagged, 0 without an answer
```

| # | Axis | Finding | Resolution |
| - | ---- | ------- | ---------- |
| 3.1 | failure path | Held: `cut_result/1` at every size from 8 under to 8 over the limit with 1- to 4-byte characters at offsets 0 to 3, invalid bytes, 300 random binaries of 65,534 to 200,000 bytes, and 4,000,000 invalid bytes. Each result is valid UTF-8 of at most 65,536 bytes, starts with `[cut at K of T bytes]` and a newline, and a second cut leaves it unchanged (the resume path). With the old order the new TUI test fails: the notice is line 20,001 of the preview | — |
| 3.2 | spec | The order is within the decision: A1 and Q2 ask for the head and a notice and name no position. The bound holds because `room` reserves the notice at the limit, and the moved newline does not change its length. The render path shows the notice: `result_lines/2` takes the first four lines. Read from the code | — |
| 3.3 | spec | The `Helyx.Tool` moduledoc and the test name in `message_test.exs` still said "its head and a notice", which reads as head first, while the docs of this round say "a notice line and its head" | Fixed: the wording only; no further round, because the round reproduced no defect |
| 3.4 | failure path | A tool can start its own output with a `[cut at ...]` line. It was the same before this round, and the size bound holds | Not changed: the notice is information for the user and the model, not a marker that code parses |

Round 3 reproduced no defect, so the loop ends. Its fixes are wording.

## Round 4 (reduced, after the rebase)

The branch was rebased on master after #510 (the stream event `{:resume_id, ...}`, the field `:resume_id`, `ProviderConn.resumed`) and #511 (the resume label count), at merge `c208bfe`. One conflict, in `docs/features/one-provider-path.md`, was mechanical: the #508 `tool_result` line and the #510 `{:resume_id, id, cut}` line are both kept. `stream.ex`, `stream_events_test.exs`, `stream_test.exs`, and `test/support/interfaces.ex` merged without a conflict. The rebase changes no #508 code line, so the round is reduced; the coordinator asked for it, with the base `origin/master`, so the agents saw the full diff on the new master.

Bounds sensor:

```
bounds sensor: 4 candidate functions, 0 flagged, 0 without an answer
```

| # | Axis | Finding | Resolution |
| - | ---- | ------- | ---------- |
| 4.1 | spec | The merge keeps the #510 renames (`stream.ex` dispatches and matches `{:resume_id, id, cut}`, no `{:resume,` stream event is left) and the #511 change. `Stream.check/1` passes each provider `tool_result` through `cut_result/1`; the hands, the codec, the notice place, and the TUI preview hold the invariant. Read from the code; the stream, message, file, hands, TUI, and text tests pass | — |
| 4.2 | failure path | Held through `Stream.check/1`: 65,536 bytes unchanged, 65,537 cut with the notice first, 21,846 invalid bytes (65,538 after the repair) cut, surrogates, overlong forms, 2- to 4-byte characters across the cut at offsets 0 to 4, an empty text; each output is valid UTF-8 of at most 65,536 bytes and a second check leaves it unchanged. `truncate/2,3` output with invalid bytes stays at most 51,289 bytes and `cut_result/1` leaves it unchanged. Not reached: the hands cancel race against a direct answer under `:erlang.suspend_process/1` (read from the code only), and an end-to-end run of the harness providers | — |

Round 4 reproduced no defect, so the loop ends.

## Round 5 (full): head and tail

Owner decision of 2026-10-12 (ticket comment): the cut keeps the head and the tail, with a marker line in the middle, and the notice stays first, because errors and exit codes are at the tail. This replaces the bound "the cut keeps the head" of the rounds above. `Helyx.Text.truncate` does not change.

Fix, counted from its diff against `509afae` without test files and Markdown: 33 lines added plus removed in 2 code files (`message.ex`, and the `Helyx.Tool` moduledoc); the first version added a function (`marker/1`), so the round is full. Result: `[cut to <kept> of <total> bytes, start and end kept]`, the head, `[… cut …]`, the tail; the head and the tail each get half of the room after the notice and the marker, each cut on a character boundary.

Simplify: one `room` split into `head_room` and `tail_room` (simplification, standards); a fixed marker `[… cut …]` in place of `[… <cut> bytes cut …]`, because the notice already gives the counts, which also takes the variable marker out of `room` (simplification, altitude); the result is built with `IO.iodata_to_binary/1`, one copy of the exact size, where appends left a 128 KB binary for a 64 KB result (efficiency); a tuple field in place of an `if` in `stream_events_test.exs` (simplification). Skipped: a shared trim with `Helyx.Text.cap/3` (reuse: Core does not call the plugin); a session test that compares with `cut_result/1` in place of the format regex (simplification: each entry point states the format the user sees); dropping the half-split and second-cut assertions (simplification: both are in the design); dropping "start and end kept" from the notice (altitude, standards: the TUI preview shows the notice and not the marker, so the notice alone says that the middle is gone).

Bounds sensor (base `509afae`):

```
bounds sensor: 0 candidate functions, 0 flagged, 0 without an answer
```

| # | Axis | Finding | Resolution |
| - | ---- | ------- | ---------- |
| 5.1 | Codex | Verdict needs-attention on the committed range: at `509afae`, the head-only cut drops a final failure line of a 100,000-byte result. Codex saw that the working tree fixes it | Fixed by this round: the reviewed change keeps the tail; `message_test.exs` checks that `exit 3` at the end of a 200,000-byte text is kept |
| 5.2 | failure path | A session file with four text blocks in one tool result resumes at 245,536 bytes, and the notice is not first, because the reader cuts each block on its own. Reproduced | Accepted hole (owner decision after round 2, row 2.3): only a session file edited by hand reaches it, within the 64 MiB file limit. The code does not change |
| 5.3 | failure path | Held: `cut_result/1` at 65,535 to 65,539 and 200,000 bytes with 1- to 4-byte characters at offsets 0 to 3, invalid input of 30 KB and 5 MB, split sequences; each result is at most 65,536 bytes of valid UTF-8, the notice is first, the tail is kept, and a second cut changes nothing. Every live path passes the cut | — |
| 5.4 | spec | Held: the same properties over every size from 8 under to 8 over the limit, 300 random binaries, 4,000,000 invalid bytes, and a text that holds `[… cut …]`; every doc that said "keeps the head" gives the new shape | — |
| 5.5 | spec | `tool-text-out-of-core.md` item 6 said the tail keeps the exit code in "What the user sees", but the TUI preview shows four lines, so the TUI user sees the notice and not the tail | Fixed: the item says the tail is kept for the model and the stored transcript, and that the preview does not show it. A preview change is outside #508 |
| 5.6 | standards | The `cut_result/1` doc gave reasons ("so a reader of the head sees it", the tail and exit codes); the reasons belong in the feature doc | Fixed: the doc states the contract only |
| 5.7 | standards | Magic numbers 11 and 7 with a comment in `message_test.exs` | Fixed: `byte_size/1` of the literal texts |
| 5.8 | standards | The notice wording is copied into seven test files and four docs | Kept: the tests state the format at each entry point, as the rounds above decided for the literal 65,536 |

Round 5 reproduced no new defect: 5.1 is the defect that this round fixes, and 5.2 is an accepted hole that the record states. The loop ends. The fixes after the reviews are wording, names, and a test literal.

## Gate

The coordinator runs the Codex gate after the commit of round 5. Its result and the escapes row are not in this record yet.

Gate r1 (Codex): 0 findings, approve.
