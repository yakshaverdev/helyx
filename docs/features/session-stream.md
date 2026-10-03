# Session stream

## Goal

Move the code that runs inside the provider Task out of `Helyx.Session` into one module, `Helyx.Session.Stream`. The session then holds the state, the queues, the transcript, and every decision, and one module holds the work of a provider call.

Before this change, `call_provider/1` (called by `start_provider_call/1`) built a closure that runs in the provider Task: the context build, compaction, `provider.stream/3`, and the consumption of the stream (`consume/4`, `harness_event/1`, `done_terminal/3`, `capped_usage/1`, `forward/5` in `lib/helyx/session.ex`). The session module is 931 lines after #119, and a reader must go through this code to read the turn loop. Issue #120, from the Core cleanup plan (`docs/reviews/2026-09-26-core-cleanup-plan.md`).

This is a move, not a redesign. The events, their order, the checks, and the terminals do not change. The `kind` flag stays: #123 replaces it.

## Interface changes

A new internal module, `@moduledoc false`, at `lib/helyx/session/stream.ex`:

```elixir
@type terminal :: {:done, %{stop_reason: atom(), usage: map()}} | {:error, term()} | :stream_ended

@spec run(%{
        model_context: module() | nil,
        compaction: module() | nil,
        provider: module(),
        model: String.t(),
        context: Helyx.Context.t(),
        opts: keyword(),
        session: pid(),
        turn_id: String.t(),
        harness?: boolean()
      }) :: terminal()
```

`run/1` runs in the provider Task. It builds the context with the ModelContext plugin, runs the Compaction plugin, calls `provider.stream/3`, and consumes the stream. The session resolves both plugins once, at its start (#122); `nil` means no plugin, and the context goes on unchanged. It sends the session the same messages as today:

- `{:stream_event, turn_id, event}` for each event that passes the checks
- `{:rejected_call, turn_id, call, reason}` before the stream event of a call with an integer over the digit limit, or of a rejected tool call from the provider (#146 added the reason; #380 removed the provider event, see `rejected-tool-call.md`)

It returns the first terminal, with `Message.cap_integers/1` applied, as the closure did before this change.

The session keeps `start_provider_call/1`, `call_provider/1`, and `start_stream/3`. The closure becomes `fn -> Helyx.Session.Stream.run(args) end`. No public function, behaviour, or event shape changes. Later, #227 made `run/1` check the context of the plugins before `provider.stream/3` (see "The context check (#227)").

## Which checks move, and which stay

The stream module owns the checks of stream events: the event shapes, `String.valid?/1` on deltas, `Message.harness_id?/1` on harness ids, `Message.big_integer?/1` and `Message.encodable?/1` on tool call arguments and usage, the stop-reason set (`Helyx.Message.stop_reasons/0`), and the harness event rules.

Some input reaches the session with no stream event. These checks stay at their boundary:

| Input | Where | Check |
| --- | --- | --- |
| `:DOWN` reason of a crashed provider Task | the `:DOWN` clause of `handle_info/2` | `Message.cap_integers/1` |
| crash reason of the stream Task of an external turn | `Helyx.Session.Hands`, where the hands make the `{:task_exit, reason}` terminal | `Message.cap_integers/1` |
| client text | `prompt/2`, `steer/2`, `follow_up/2` | `String.valid?/1` |

The terminal cap at the end of `run/1` stays too. The hands cap only the crash reason, the one terminal that `run/1` did not cap. The other terminals of the hands are text. The session does not cap the `:stream_end` terminal again.

## The context check (#227)

The ModelContext and the Compaction plugin are outside Core, so their returns are a boundary. `run/1` builds the context with `Helyx.Session.Stream.prepare/4`, the check that #199 added for a connected turn (`docs/features/long-lived-harness.md`). So a local, an external, and a connected turn check the context in the same way.

- The check runs after each plugin. A return passes when it is a `Helyx.Context` with exactly its three fields, a `system` that is nil or a string, and `messages` and `tools` that are lists. The check does not look into the list elements.
- A return that fails the check ends the provider call before `provider.stream/3` with the terminal `{:error, {:bad_context, plugin}}`, where `plugin` is `:model_context` or `:compaction`. The turn fails with that reason. The reason names the plugin, never the value.
- A plugin that raises is not a return: the Task crashes, and the turn fails with `{:task_exit, reason}`, as before.
- The session stays, and the next turn runs the plugins again.

## Bounds

No new input, buffer, or wait. These rows of `docs/features/coding-agent.md` keep their values; only the module that applies them changes:

| What | Bound | Over the bound |
| ---- | ----- | -------------- |
| integer in tool call arguments and in usage | 100 digits (`Helyx.Message.big_integer?/1`) | a call goes on with arguments `%{}` and is rejected with an error result; a usage fails the turn as a malformed event (#435) |
| stream event shape | the shapes of `Helyx.Provider` | the turn fails with `{:bad_stream_event, event}` |
| harness tool result text | #121 changed this row: the provider cuts the text (`Helyx.Text.truncate/2`, `:tail`), and `Helyx.Session.Stream` checks 65,536 bytes | See the two rows "Harness tool result text" of `docs/features/coding-agent.md` |

The rows in `docs/features/coding-agent.md` that name `consume/3` or the session as the place of a check are updated to name `Helyx.Session.Stream`.

## Ownership

No new resource. The rows for the provider stream Task do not change: a model stream is a Task of the Core task supervisor, linked to the session; a harness stream is a Task of the hands (ADR 0003). `Helyx.Session.Stream` holds no resource; it runs inside that Task.

## Tests

- The session tests pass with no change to their assertions. They cover the event order, the rejected call, the malformed events, and the harness events.
- A new `test/helyx/session/stream_test.exs` calls `run/1` directly with the test providers of `test/support/interfaces.ex` and a test process as `session`. It checks the messages that arrive and the terminal: a valid stream, a malformed event, an integer over the digit limit in arguments and in usage, invalid UTF-8 in a delta, and a harness event from a model provider.

## Out of scope

- The `kind` flag and its branches in the session: #123.
- The truncation of harness tool results: #121 (`docs/features/tool-text-out-of-core.md`).
- The split of the session into more modules: #119 and #124.
