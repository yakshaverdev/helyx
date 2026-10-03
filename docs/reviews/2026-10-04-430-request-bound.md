# Review: #430, a byte bound on tool requests; drop empty deltas

Branch `ticket/430-request-bound`, base `origin/master` `10b0775`.

Invariant: tool requests enter the session only through `Helyx.Session.ProviderProcess` and `Stream.check/1`, which now carries the encoded call bytes as `{:tool_request, call, bytes}`; `Helyx.Session.ToolQueue` keeps the running and waiting requests of a turn at most `Turn.max_message_bytes/0` (8 MiB) together and answers a request past that at once with the fixed error result "Helyx tool calls too large", on the same path as the count bound; the bytes of a call leave the sum at its hands result, at a cancel of a waiting call, and at the turn end; a withdrawn running call keeps its bytes until its hands result, because the hands still hold it; an empty text or thinking delta is dropped in `ProviderProcess` before the check and makes no block and no event. Renames: `Session.Tools` to `Session.ToolQueue`, `Server.Tools` to `Server.ToolRuns`, `State.tools` to `State.tool_specs`, `Turn.tools` to `Turn.tool_queue`. Known open ceiling, outside this ticket: alternating 1-byte text and thinking deltas still make one block per delta within the 8 MiB byte bound.

## Input paths probed

- Tool requests: only `ProviderProcess.action/2` sends `{:tool_request, ...}` to the session, after `Stream.check/1`. No other sender (disk, client, terminal).
- Deltas: only `ProviderProcess.action/2` sends `{:stream_event, turn_id, delta}`, and it is the only caller of `Stream.check/1`. A resumed file holds blocks, not deltas.

## Ticket text against the repo

The ticket asks to update "the bounds table row of tool requests" in `coding-agent.md`. That file has no such row. The row is in `one-provider-path.md` ("Open tool requests of a turn"), and it is updated; `coding-agent.md` gets one sentence in the "Open assistant message" row, which names the same constant. The history paragraph of #395 in `one-provider-path.md` keeps the old module names.

## Round 1 (full)

Simplify: four agents. Applied: one `id/1` helper in `ToolQueue` for the three `fn {c, _} -> c.id end`; the test alias `ToolQueue, as: Tools` is gone. Skipped: a running total field (derived sum over at most 17 entries is enough, and it has no sync to keep); `running: {id, bytes}` (two pattern matches outside the queue read `running` as an id); rename the `tools` variables in `ToolQueue` (pre-existing names, larger diff); tests derive 8 MiB from `Turn.max_message_bytes/0` (tests pin the documented value, as the #412 and #416 tests do); move the empty-delta drop into `Stream.check/1` (needs a new return shape for one case); a per-block cost in `Turn.add_block/3` (altitude agent: alternating 1-byte deltas; outside the ticket, recorded as open).

Bounds sensor:

```
bounds sensor: 5 candidate functions, 0 flagged, 0 without an answer
```

| Axis | Finding | Resolution |
| --- | --- | --- |
| Codex | Verdict approve, no findings | none |
| Failure path | No defect reproduced. Probed through `Stream.check/1`: a call at exactly 8 MiB runs, 8 MiB + 1 is rejected, multibyte arguments; a small request while 8 MiB runs is rejected; a withdrawn running call keeps its bytes until its result; check order (open id, rejection, bytes, count); every sender and reader of the changed shapes. Not reached: the hands and OS state table (names only changed there), an endless empty-delta loop through a real provider | none |
| Standards | `describe "request/3"` and the "scheduler" comment are stale | Fixed |
| Standards | The empty-delta drop has no feature doc | Kept: the ticket is the design, and the provider moduledoc states the contract |
| Standards | `call, bytes` travel together; `running` and `running_bytes` differ in shape from waiting | Kept: see simplify skips |
| Spec | The session-level test covers a single call over 8 MiB, not a sum over the bound | Fixed: the test runs a 4 MiB call, rejects a second 4 MiB call and a single 8 MiB call, and runs a small one after |
| Spec | A withdrawn running call keeps its bytes, which the ticket text does not say | Fixed: stated in `one-provider-path.md`; the unit test name says "a cancel of a waiting call" |

Round 1 reproduced no defect, so the loop ends.
