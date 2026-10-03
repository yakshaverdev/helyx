# Unknown values in the TUI

> Replaced in part by the ADR 0006 revision of 2026-10-03 (#404): section 5 and its contract version are gone, a client works with one Helyx version, and an unknown block kind shows a placeholder such as `[unsupported block: image]` instead of being dropped. #406 built this: the fold dispatches on the event type first, each known type checks its payload inside its own clause, and the block filter is gone. The text below that cites section 5 and the out-of-scope item on placeholders are history. The crash on a known event with a broken shape stays.

Ticket #211. Follows #206, which made the TUI ignore an unknown event type.

## Goal

A user runs the TUI against a newer Core. That Core adds a value inside a known event type: a new delta kind in `message_update`, a message with a new role, or a new content block kind. The TUI skips the part it does not know and keeps running. ADR 0006, section 5, lets the server add such a value within one contract version when a client that ignores it stays correct. So the TUI ignores it.

## Interface changes

No new function and no new event shape. `Helyx.TUI.ViewModel.apply/2` and `from_snapshot/1` change behavior:

| Input | Before | After |
| ----- | ------ | ----- |
| `message_update` whose data has no delta key that the TUI knows (`text_delta`, `thinking_delta`, `tool_call`) | crash | ignored, only `seq` moves |
| `message_update` with a well-formed delta when no assistant message is open (the deltas of a message of a new role) | a partial that shows as an assistant reply | dropped |
| `message_start` or `message_end` whose `%Message{}` has a role other than `:user` or `:assistant` | crash | ignored, only `seq` moves |
| assistant message with a block other than `Text`, `Thinking`, or `ToolCall`, an `Image` included (`message_end`, a snapshot message, a snapshot partial) | render crash | the block is dropped before the message becomes a cell |
| snapshot message of a new role | crash | no cell |
| snapshot partial of a role other than `:assistant` | shown as an assistant reply | no partial |

A user message and a tool result render through `Message.text/1`, which already skips a block that is not text.

### A known type with a missing required field

Decision: crash. Core makes every event from checked data, so a missing required field (for example a `message_start` with no `message`, or data that is not a map) is a bug in Core, and AGENTS.md says a state that only a bug can make crashes. The ignore rule covers a value that is present and new. It does not cover a value that is absent.

One exception: a `message_update` with no key that the TUI knows, an empty data map included, is ignored. A delta kind is a data key, so a missing delta and a new delta kind with a key the TUI does not know have the same shape to the TUI. The fold cannot tell them apart, and a crash on a new delta kind breaks ADR 0006. Core sends one delta key for each update (`Helyx.Session.Server`, `Map.new([event])`), and `Helyx.Session.Stream` checks each delta at the provider boundary. So a known key with a value of another type (a `text_delta` or `thinking_delta` that is not a binary, a `tool_call` that is not a `ToolCall`), or two known keys, is a shape error and crashes in the fold. A key that the TUI does not know next to a known key is an unknown field, and the fold ignores it.

A block of an assistant message that is not a struct is a shape error and crashes. A struct of a kind that the TUI does not render is a new value and is dropped. A user message and a tool result render through `Message.text/1`, which skips every block that is not a `Text`, so their blocks get no check here.

`message_update` carries no message id, so a client links a delta to the open message. Core streams one message at a time: `Helyx.Session.Server` sends `message_start` before the first delta and `message_end` before the next `message_start`. A newer Core that nests or interleaves messages changes a meaning that an old client must understand, so it raises the contract version (ADR 0006, section 5). The TUI does not handle it.

Accepted hole: a delta with no `message_start` before it is a bug in Core, but the TUI drops it and does not crash. Without a message id, it has the same shape as a delta of a message of a new role. Before this change such a delta opened a partial and did not crash either. A flag for an open hidden message would let the TUI tell the two apart; no ticket, since only a Core bug makes the event.

A change that a client must understand to stay correct raises the contract version (ADR 0006, section 5). So `tool_execution_end` still requires a `:tool_result` message: a new role there would leave the tool cell open forever, and Core must raise the version for it. `agent_end` already shows any stop reason other than `aborted` and `error` as a normal end. An `agent_end` with the stop reason `error` and no `error` field showed as a normal end before this change; now it crashes, as a missing required field does.

## Bounds

No new input, buffer, or wait. An ignored event of a known type costs one `seq` update; an event of an unknown type costs nothing. The block filter is one pass over the blocks of a message, once, when the message becomes a cell or when the snapshot mounts, not on each frame.

| What | Bound | Over the bound |
| ---- | ----- | -------------- |
| blocks of an assistant message | the provider stream and session limits, as before | unchanged |

## Ownership

No external resource.

## Out of scope

- A new field in a struct (`Message`, `ToolCall`): the struct is defined in Core, so a client in the same node has the same struct. No ticket, not planned.
- A rendered placeholder for an ignored value. The TUI shows nothing for it. No ticket, not planned.
