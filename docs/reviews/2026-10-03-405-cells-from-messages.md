# Review: #405, TUI tool cells from the messages

Branch `ticket/405-cells-from-messages`, base `origin/master` `4685a02`.

Invariant: the TUI makes a tool cell for each call of the streaming message and for each call of an ended assistant message, open with the label "awaiting result" until the oldest open cell with that call id gets its `tool_execution_end` result; it ignores `tool_execution_start`; `ViewModel.from_snapshot/1` gives the same cells without `Snapshot.turn.running`, which Core no longer sends; a result with no open cell makes no cell. Accepted: the call line is made at stream time and again at `message_end`, once per cell and never per frame; `contract_version` stays until #406; `from_snapshot/1` keeps its own pairing until #407.

## Round 1 (full)

Simplify: four agents. Applied: the streaming split in `Transcript.items/1` matches `{:tool, _, _, _}` (was `is_tuple/1`), and the moduledoc of `streaming` says how its line is made. Skipped: a public `Message.tool_calls/1` in Core (a Core API for a TUI helper), a shared test helper for transcript texts (small), reuse of the streaming cells at `message_end` (the message is the source; the cost is one capped line per call per message), a stale comment in `turn.ex` (still true: the open calls come from the transcript).

Bounds sensor:

```
bounds sensor: 8 candidate functions, 1 flagged, 0 without an answer
  plugins/bundled/lib/helyx/tui/view_model.ex:174  SIZE  defp fold(vm, %Event{type: :message_end, data: %{message: %M
```

The failure-path agent attacked the flag: each line is capped at `@render_max_bytes`, multibyte included; 3,000 calls in one message cost 4 ms at the stream and 4 ms at `message_end`. Not a defect.

| Axis | Finding | Resolution |
| --- | --- | --- |
| Standards | `streaming` type admitted every `cell()` | Fixed: new `tool_cell()` type |
| Standards | `tool_calls/1` bound `c` | Fixed: `call` |
| Standards | `stream/2` skips `Message.add_block/2` for a call with no reason given | Fixed: comment |
| Standards, spec | No "Replaced mechanism" record; deleted tests not listed | Fixed: section "Replaced mechanism (#405)" in `docs/features/session-snapshot.md` |
| Spec | Moduledoc said the line is made once; `message_end` makes it again | Fixed: the moduledoc states both |
| Spec | Moduledoc said `streaming` is shared through `add_block/2`, but it holds tool cells | Fixed: only text and thinking deltas go through it |
| Failure path | No defect reproduced. Note: `attach_result/2` `nil -> cells` has no Core path that reaches it | Kept: the existing tests of a second result and of an unknown call record it, and #406 sets the tolerant-reader rule for event payloads |
| Codex | Approve, no findings | none |

Round 1 reproduced no defect, so the loop ends. The fixes are types, a variable name, comments, and docs.
