# Review: the cost of the transcript scans (#436)

Date: 2026-10-04. Base: `origin/master` (`8397956`). Scope: `bench/transcript.exs` (new). Resolution: no code in `lib/` changes. The script is in the root project, not in `plugins/bundled/bench/`, because `Records`, `State`, and `Transcript` are root modules.

## Invariant

At 10,000 messages, one append, one `Transcript.open_calls/1`, and one tool result each cost less than 1 ms on this machine. So the session keeps the transcript in order, with `transcript ++ [message]` and the reverse in `open_calls/1`. Accepted holes: the script does not time the file append or the event sends, and the median of one fixed state does not include the GC of a long session process.

## Measurement

`mix run bench/transcript.exs` from the repository root. Apple M4, Elixir 1.19.5, OTP 28. Three runs, one after the other, with no other process started by this work. Each value is the median of 101 runs of one step on the same state, in ms. The state has no file and no subscriber. The transcript is rounds of a user message, an assistant message with one tool call, and its result, and it ends with an open call.

| Messages | Step | Run 1 | Run 2 | Run 3 |
|----|----|----|----|----|
| 998 | append (`Records.append_user/2`) | 0.001 | 0.001 | 0.001 |
| 998 | `Transcript.open_calls/1` | 0.000 | 0.001 | 0.001 |
| 998 | tool result (`Records.tool_result/3`) | 0.002 | 0.002 | 0.001 |
| 9,998 | append | 0.022 | 0.024 | 0.025 |
| 9,998 | `Transcript.open_calls/1` | 0.007 | 0.007 | 0.008 |
| 9,998 | tool result | 0.049 | 0.047 | 0.044 |
| 49,997 | append | 0.131 | 0.129 | 0.126 |
| 49,997 | `Transcript.open_calls/1` | 0.021 | 0.028 | 0.030 |
| 49,997 | tool result | 0.253 | 0.263 | 0.264 |

The close of an assistant message (`Records.end_assistant/3`) is one `open_calls/1` and one append, about 0.032 ms at 10,000 messages. The steps grow linearly with the message count, as the ticket says. The largest step at 10,000 messages is 0.049 ms, 1/20 of the 1 ms limit of the ticket. So the transcript stays in order and no code changes. An estimate, not a measurement: each of the first 10,000 messages costs at most the largest step, so a session of 10,000 messages pays less than 0.5 s in all for these steps.

## Round 1 (full)

Simplify (4 agents): applied the transcript built with `Enum.drop(-1)` in place of a separate last round, `transcript` in the `State` literal, the open call id out of the timed function, and the sentence on `Records.end_assistant/3`. Skipped: a warm-up run and a GC between steps (the median of 101 runs hides both), and a shared `messages/1` with `plugins/bundled/bench/view_model.exs` (two Mix projects). The script changed in setup only, so the three runs were made again, and the table has the new numbers.

Bounds sensor:

```text
bounds sensor: 0 candidate functions, 0 flagged, 0 without an answer
```

| Axis | Findings | Reproduced defects | Resolution |
|----|----|----|----|
| Standards | 0 hard, 4 judgement calls, 5 smells | 0 | Fixed: the invariant in shorter sentences, "no other process", "1/20 of the limit", the whole-session line as an estimate from the largest step, the reason for the root location. Not taken: `bench/` in the AGENTS.md layout (outside the ticket); timing names such as `append_ms` (script names, no change after review); a map return from `run/1` and named sizes (the style of `view_model.exs`); the hand-built `State` (no constructor exists, and a new enforced key fails the script at once). |
| Spec | 3 partial, 2 not asked, 3 doubtful | 0 | Fixed: the sizes are stated as 998, 9,998, and 49,997; the whole-session line is an estimate; the GC hole is in the invariant. Not done by order of the orchestrator: the comment on the ticket. |
| Failure path | 0 | 0 | The steps are the real functions; with `partial: nil`, `close_if` does nothing. A probe carried one state through 300 real rounds (`append_user`, `delta`, `end_assistant`, `tool_result`) from about 10,000 messages, GC included, 5 runs: median round 0.109 to 0.125 ms, p99 0.17 to 0.32 ms, one cold first round of 3.0 to 4.5 ms in a new process. Not reached: a session file, subscribers, large tool arguments, the precommit host. |
| Codex adversarial | 0 | 0 | Verdict approve. |

No reproduced defect, so the loop ends.
