# Rejected tool call

## Goal

A provider can send one tool call that Core must not run, with the reason. Core records the call in the assistant message and answers it with an error result. The text and the other calls of the message stay, and the model can correct the call on the next provider call. Issue #146, finding D4 of `docs/reviews/2026-09-26-boundary-review.md`.

Today, in `Helyx.Provider.OpenAI`, one tool call whose arguments are not valid JSON fails the whole turn (`flush/1` and `decode_arguments/3`). The text and every other call are lost. The error holds the raw JSON, up to 10 MiB. Core already handles one bad call in proportion for an integer over the digit limit (`{:rejected_call, ...}` in `Helyx.Session.Stream`, `run_tool/2` in `Helyx.Session.Server`). This change gives providers the same path.

## Interface changes

`Helyx.Provider`, one new stream event for a local turn:

```elixir
{:rejected_tool_call, Helyx.Message.ToolCall.t(), reason :: String.t()}
```

- The call goes into the assistant message as a normal tool call, in stream order. The provider puts the arguments it could decode, or `%{}` when it could decode none.
- Core does not run the call. Its tool result is `{:error, "tool call not run: " <> reason}`. It takes the path of a result from the hands, so the events and the order of the calls do not change. A call of the same turn that is equal to a rejected call (the same id, name, and arguments) is also not run, as for the integer cap. Call ids are unique in a correct stream, so only a provider bug makes such a call.
- The event is valid only on a local turn. On an external turn it fails the turn with `{:bad_stream_event, event}`, as a harness event on a local turn does today. An external provider runs its own tools and sends its own `{:tool_result, id, {:error, text}}`.

Core, all internal:

- `Helyx.Session.Stream` checks the event (the same checks as `{:tool_call, _}`, plus the reason) and sends `{:rejected_call, turn_id, call, reason}` before the stream event of the call. The integer cap uses the same message, with its current text as the reason.
- `Helyx.Session.Turn` stores the reason with each rejected call. `run_tool/2` uses the stored reason in place of the fixed `@rejected_call_text`.

`Helyx.Provider.OpenAI`:

- A call whose arguments are not a JSON object becomes `{:rejected_tool_call, %ToolCall{id, name, arguments: %{}}, "the arguments are not a valid JSON object"}`. The reason does not hold the raw JSON.
- A call with no id (`""`) cannot get a paired result, because the next request must name the call by id. It still fails the turn: the Core stream boundary rejects every tool call with an empty id, with `{:bad_stream_event, {:tool_call, call}}`, and the call holds `%{}` as arguments, not the raw JSON (#345).

## Bounds

| What | Bound | Where enforced | Over the bound |
| --- | --- | --- | --- |
| reason text | UTF-8, at most 1,024 bytes | `Helyx.Session.Stream`, at the event check | the turn fails with `{:bad_stream_event, event}` |
| error of a call with no id | no raw arguments in the term | `Helyx.Provider.OpenAI` gives the call `%{}` as arguments; `Helyx.Session.Stream` rejects the empty id (#345) | n/a: the term holds the call, with `%{}` for bad JSON and the decoded arguments otherwise |
| result text | "tool call not run: " plus the reason: at most 1,043 bytes | follows from the reason bound | n/a |

No new buffer or wait. The argument byte bound of the OpenAI provider does not change.

## Ownership

No new resource.

## Tests

- Stream: a `{:rejected_tool_call, ...}` event gives `{:rejected_call, ...}` before the stream event; a reason that is not UTF-8 or is over 1,024 bytes fails the turn; the event on an external turn fails the turn.
- Session: a turn with text, one good call, and one rejected call keeps the text, runs the good call, and gives the rejected call the error result with its reason. The next provider call gets both results.
- OpenAI: bad JSON in one of two calls gives one `tool_call` and one `rejected_tool_call`; bad JSON in a call with no id gives a `rejected_tool_call` with an empty id and `%{}`, which Core rejects (#345).
- The session tests of the integer cap pass with no change to their assertions. The stream and `Turn` tests of the integer cap change only for the reason that the rejection message now carries.

## Docs

- The `Helyx.Provider` moduledoc lists the event.
- `docs/features/coding-agent.md`: the bounds rows of the OpenAI tool call arguments name the new result.
- `docs/agents/review-checklist.md`, Inputs from plugins: one bad call from a provider is rejected alone when it has an id.

## Out of scope

- Other providers. OpenAI is the only bundled provider with a local turn. A later local provider uses the event when its wire protocol can send bad arguments.
- A repair of bad JSON (for example, a cut at the end).
- A call with a bad name or a name that no tool has: Core already answers it with an error result from the hands.
