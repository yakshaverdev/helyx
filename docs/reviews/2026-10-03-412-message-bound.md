# Review: #412, bound the bytes of the open assistant message

Branch `ticket/412-message-bound`, base `origin/master` `277f346`.

Invariant: the session adds a text or thinking delta to the open assistant message only while the bytes of all such deltas of that message stay at or under 8 MiB (`@max_message_bytes` in `Helyx.Session.Turn`), counting from zero at each close of the message (`message_end`, the first result of one of its calls, a taken steer, the turn end); a delta past the bound is a contract break that stops the provider process and fails the turn through `TurnLoop.stop_provider/2` with `{:message_too_large, bytes, 8388608}`, with no truncation and no special handler. Entry point: the `stream_event` clause of `Helyx.Session.Server`. Accepted: the tool calls of the open message are not counted (the ticket names text and thinking only), and one waiting event in the session mailbox has no byte bound in Core.

## What bounded a delta before

- Harness providers (Claude Code, Codex): one delta is within one stdout line, 16 MiB (`@line_max_bytes` in `Helyx.HarnessIO`). The number of delta lines is not bounded.
- OpenAI-compatible provider: one delta is within one SSE line, 1 MiB (`@max_line_bytes` in `Helyx.Provider.OpenAI.Events`). The number of lines is not bounded.
- `Helyx.Provider.Loop`: no byte check; it forwards each delta, and only counts waiting messages (10,000, `send_checked/3`).
- Core: `Stream.check/1` checked a delta for UTF-8 only, and the session appended every delta to `Turn.partial`.

## Changed tests

- `turn_test.exs`, "assistant_message builds the content in stream order": `Turn.add_block/2` now returns `{:ok, turn}`; the test matches it. What it checks is the same.

## Round 1 (full)

Simplify: four agents. Applied: the provider doc names the value (8 MiB) next to the attribute. Skipped: count the tool calls of the open message too (altitude agent; the ticket names text and thinking, so the wider bound is a decision for the owner, reported as open); a smaller test bound through config (efficiency agent; config only for tests); a helper that returns the session from `harness_turn/2` (reuse agent; one caller).

Bounds sensor:

```
bounds sensor: 0 candidate functions, 0 flagged, 0 without an answer
```

| Axis | Finding | Resolution |
| --- | --- | --- |
| Codex | Verdict approve, no findings | none |
| Failure path | No defect reproduced. Probed: reset at a taken steer and at a first result, a 2-byte character across the bound, a delta queued behind the failing one (dropped), one `message_end` with the error, the next prompt passes | none |
| Standards, spec | No test with a multibyte character at the limit | Fixed: `message_over_bound` sends one byte under 8 MiB, then a 2-byte character across the bound; the bytes in the error are 8,388,609 |
| Standards | The new `@max_session_queue` comment and the doc row said Core does not cap one waiting event, but a tool result is capped before the send | Fixed: Core caps a tool result before the send and the open message in the session, not one waiting delta or tool call |
| Standards | The doc row names `forward/6`, which does not exist | Fixed: `Helyx.Session.Stream.send_checked/3` |
| Standards | Tool calls of the open message are not counted, and the row gives no ticket | Fixed in the row: unbounded in Core, open with no ticket yet; reported to the orchestrator |
| Spec | At 64 bytes for each token the bound has no margin; the comment must state the margin plainly | Fixed: the comment states about 512 KiB for a 128K response at 4 bytes for each token, a margin of 16 times, and that 64 bytes for each token still fits |
| Spec | The doc does not say what `Provider.Loop` bounds | Fixed: the row says it only counts waiting messages |
| Spec | The row "Harness tool calls and messages per harness turn" still says the deltas are each only within the line cap | Fixed: it points to the row "Open assistant message" |
| Standards | The bound sits in the `thinking_delta` bullet of the provider doc | Fixed: its own paragraph after the event list |
| Standards | The error spec is `term()` | Fixed: `{:message_too_large, pos_integer(), pos_integer()}` |
| Standards | Outside facts (the 128K output limit) belong in a research note | Kept: the ticket asks for the reason at the attribute; the row cites the source and date |
| Standards | The number and its reason appear in four places | Kept: the attribute comment is what the ticket asks for; the doc and the provider contract name the value for readers |
| Spec | No separate test one under the bound | Kept: `message_over_bound` passes 8 MiB minus one byte before the failing delta, and `message_at_bound` passes at the bound |

Round 1 reproduced no defect, so the loop ends.
