# Review: #368, OpenAI provider and tools keep the bounds, one Text cap helper

Date: 2026-10-03. Branch `ticket/368-openai-tools-cap`, base `origin/master` at `f8092d1`.

## Invariant

Entry points: `Helyx.Provider.OpenAI.Events.events/1` for every SSE chunk, the drain of a non-200 body in `Helyx.Provider.OpenAI`, `Helyx.Text.cap/3` and `truncate/2,3`, and `run/2` of the read and bash tools. A chunk outside the documented OpenAI streaming shape ends the stream with one `bad_chunk` error. SSE lines stay within 1 MiB. The ids, names, and arguments of the tool calls of one response stay within 10 MiB, and a call index is from 0 to 10,000. The error body stays within 16 KiB, and a cut body is valid UTF-8. A cut line of a tool result is valid UTF-8 of at most 51,200 bytes; an uncut line is repaired by the hands. Accepted holes: a missing index is a contract break with no handler; an offset after the last line is an empty ok result; a float offset is an error; the bash kept tail can start with a partial character that the hands repair; a transport error while an error body drains fails the turn as a Task exit.

## What changed

- `openai/events.ex`: one shape check (`fields/1`, `call?/1`) replaces the per-field gate. The id and index identity rules, the implied index, the conflict detection, the `ids` map, the flat entry and fragment charges, and `pending_cr` are gone. One counter holds the bytes of the ids, names, and arguments. The arguments are one binary that each fragment appends to, so the count is what the parser holds (measured: 2,000,000 two-byte fragments in 0.35 s, binary memory equal to the bytes).
- `openai.ex`: `drain/1` uses `Helyx.Text.cap/3` and has no `rescue`.
- `text.ex`: `cap/3` replaces `cut/2` and `clean_edge/2`.
- `tool/read.ex`: no offset-past-end error, no line count, no float offset, and one error text.
- `tool/bash.ex`: no working directory NUL check (the session checks the cwd, `Helyx.Session` line 158), and `keep_tail/1` does not clean the start (the hands repair it, `Helyx.Session.Hands.scrub/1`).

## Kept, with the reason

- `@max_call_index` (10,000): the ticket listed it for removal. It stays as a safety bound: a call that holds no bytes costs nothing in the byte count, so without the range a stream of empty deltas with new indexes, or a bignum index, grows the map without bound.
- `{:rejected_tool_call, ...}` for arguments that are not a JSON object, as the ticket says.
- The 1 MiB line cap, the 10 MiB tool call cap, the 16 KiB error body cap, the read bounds, the Edit overlap check, the bash command NUL check, the truncation notices, and the integer cap (#79).
- `Helyx.HarnessIO.cap_error/1` and the cut in `Helyx.TUI.ViewModel` do the same cut as `cap/3`. They are outside the scope of this worker (the harness providers change in parallel, #365); a follow-up can point them at `cap/3`.

## Deleted tests

- `text_test.exs`: the seven cut-edge tests of #68 and the never-valid text test (a cut on text that was never valid, an invalid byte away from the edge, a partial character at the far end, an edge with no whole character within three bytes, invalid bytes at the edge, continuation bytes with no lead byte, a prefix that no character has). `cap/3` drops every invalid byte of a cut line; one new test covers it.
- `read_test.exs`: the six tests of #78 (offset after the last line, trailing blank lines, the count of the error and the notice, the empty file, a huge offset error, the time of a read with a huge offset). The float and kind wording tests of #75 became one test with one error text, and a float is now in the error list.
- `bash_test.exs`: the character-boundary part of the `keep_tail` test (#51) and the working directory NUL test. The size boundary of `keep_tail` stays.
- `openai/events_test.exs`: the six conflict cases of #345, the indexless-delta tests, and the CRLF split test. The byte limit tests now count only ids, names, and arguments.
- `openai_test.exs`: the `content: 42` and `reasoning_content: %{"a" => 1}` deltas no longer disappear in the provider; they go to Core, which fails the turn. The test keeps `content: 42` and drops the map case.

## Round 1 (full)

Bounds sensor (`--diff origin/master`): 16 candidate functions, 3 flagged, 0 without an answer.

```
plugins/bundled/lib/helyx/provider/openai/events.ex:74  SIZE  defp data(payload, acc) do
plugins/bundled/lib/helyx/provider/openai/events.ex:147  SIZE  defp put_call(delta, acc) do
plugins/bundled/lib/helyx/tool/bash.ex:142  WAIT  defp collect(port, acc, dropped?) do
```

The first standards and spec briefs used `git diff origin/master` while `origin/master` had moved (#358 merged). The branch was rebased, the agents were told to read `git diff HEAD`, and Codex was rerun on the rebased tree.

Simplify (4 agents): no change applied. Rejected: point `keep_tail/1` at `cap/3` (it would drop a character that the next chunk completes); the claim that `<>` is quadratic (measured linear); restore the float and the missing-index rules (no evidence of a real model or gateway; the ticket removes them); the TUI cut (out of scope, noted above).

| # | Axis | Finding | Resolution |
|---|------|---------|------------|
| 1 | Standards | `first/2` and `size/1` are generic names | Renamed `keep_first/2` and `call_bytes/1` |
| 2 | Standards | the arguments `<>` is quadratic | Rejected: measured linear, and the failure-path agent measured 1.2 M one-byte fragments in 1.4 s with linear memory |
| 3 | Standards | the bash cwd and the hands repair are claims in comments | Verified: `Helyx.Session` line 158 checks the cwd; `Helyx.Session.Hands.scrub/1` repairs tool text |
| 4 | Spec | the tool call row says the first delta brings the id and any other shape fails, but `finish_reason`, `usage`, and text deltas are not checked | Fixed the doc row: it names what the check covers, that Core checks text deltas, and how `finish_reason` and `usage` are read |
| 5 | Spec | the float offset was accepted by #75 | Decision kept: #75 was a review finding with no observed model; recorded in the row |
| 6 | Spec | the deleted tests are not listed | Listed above |
| 7 | Failure path | a second id on an index is dropped, and an id that another index holds passes | Rejected as a defect: the OpenAI format gives the id on the first delta and names no second id; no gateway is known to send one. The doc row now says a call takes the id of the first delta that has one. A repeated call id across calls is handled by Core's documented rule (`Helyx.Provider.Loop`: a new request id for each call) |
| 8 | Codex (high) | `Bash.run/2` runs in the wrong directory for a cwd with a NUL | Rejected: the reproduction calls `run/2` directly with a value no caller can pass; the hands pass the session cwd, which `Helyx.Session` checks. The ticket removes this check |
| 9 | Codex (medium) | `false` for `delta`, `tool_calls`, or `function` took the `||` default and passed the shape check | Fixed: `field/3` defaults only a missing or null field; three shape tests added |

## Round 2 (full)

The round 1 fix adds `field/3` (a new function), so round 2 is a full round. Simplify (1 agent, four angles): `function["arguments"] || ""` was the last `||` default; changed to `field/3`. Bounds sensor (`--diff origin/master`): 13 candidate functions, 2 flagged, 0 without an answer.

```
plugins/bundled/lib/helyx/provider/openai/events.ex:74  SIZE  defp data(payload, acc) do
plugins/bundled/lib/helyx/tool/bash.ex:142  WAIT  defp collect(port, acc, dropped?) do
```

Invariant of the fix: a field that the OpenAI format lets be missing or null takes its default, and any value of the wrong type, `false` included, fails the one shape check.

| # | Axis | Finding | Resolution |
|---|------|---------|------------|
| 1 | Failure path | `"finish_reason": 5` gives `end_turn`, and `false` gives `stream_ended`, not `bad_chunk` | Fixed: the shape check covers `finish_reason` (a string or null) |
| 2 | Failure path | a `usage` of the wrong type, or a token count that is a string, is dropped | Fixed: the shape check covers `usage` (a map or null, with integer or null token counts); `usage/1` lost its fallback clause |
| 3 | Failure path, spec | `"error": null` is an API error | Fixed: only an `error` that is not null is an API error |
| 4 | Spec | the tool call row does not name the `tool_calls` list check, and `choices` can be null | Fixed the doc row |
| 5 | Spec | the record does not list the dropped map delta of `openai_test.exs`, and its invariant does not say that an uncut line is repaired by the hands | Fixed the record |
| 6 | Codex | a 1 MiB line whose CRLF splits across chunks errors, and the same line with a joined CRLF parses | Rejected: the ticket removes `pending_cr` as review-only accounting; no gateway sends a line near 1 MiB, and the SSE row states that a partial line counts its trailing `\r` |

Findings 1 to 3 land on the same mechanism, the shape check, so round 3 fixes the mechanism: every field that the parser reads is in the one check.

## Round 3 (full)

The round 2 fix changes more than 15 lines and adds functions, so round 3 is a full round. The fix code is the round 3 change; the round 2 table marks it Fixed because round 3 reviewed it. Simplify (1 agent, four angles): `optional?/2` with two closures became `string?/1` and `integer?/1`, and `usage?/1` takes nil. Rejected: move the branches of `chunk_events/3` into `data/2` (no gain), and the `<>` cost (measured). Bounds sensor (`--diff origin/master`): 14 candidate functions, 2 flagged, 0 without an answer.

```
plugins/bundled/lib/helyx/provider/openai/events.ex:74  SIZE  defp data(payload, acc) do
plugins/bundled/lib/helyx/tool/bash.ex:142  WAIT  defp collect(port, acc, dropped?) do
```

Invariant of the fix: the parser reads no chunk field that its one shape check has not checked, except the text and thinking deltas, which Core checks, and a non-null `error`, which goes out as `{:api_error, error}` and fails the turn.

| # | Axis | Finding | Resolution |
|---|------|---------|------------|
| 1 | Spec | the row and the comment name only the text deltas as checked by Core; the thinking deltas are too | Fixed the wording |
| 2 | Spec | the row does not say that a non-null `error` goes out as it came | Fixed the row |
| 3 | Spec | the record has no round 3 section | This section |
| 4 | Failure path | none: every wrong type of every checked field gave one `bad_chunk`; `"error": null` gave the text delta | n/a |
| 5 | Codex | approve, no material findings | n/a |

Round 3 reproduced no defect, so the loop ends. Not reached by the probes of any round: the OS state table of `Helyx.Tool.Bash.collect/3` (the `keep_tail/1` change does not touch the port), and a transport error during `drain/1` through a real adapter.
