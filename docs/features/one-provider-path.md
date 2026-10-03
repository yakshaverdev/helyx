# One provider path

## Goal

Every provider speaks one protocol and runs in a provider process of its session (ADR 0002, ADR 0007). An API provider runs on it through the helper `Helyx.Provider.Loop`. Core names no plugin kind (`AGENTS.md`, "Key design constraints").

## Interface

### The contract

The moduledoc of `provider.ex` gives it in short form. "The provider protocol" below holds every rule of it.

```elixir
defmodule Helyx.Provider do
  @callback id() :: String.t()
  @callback init(model :: String.t(), tools :: [Helyx.Tool.spec()], opts :: keyword()) ::
              {:ok, state :: term()} | {:error, term()}
  @callback request(request(), from(), state :: term()) :: {:ok, [action()], term()}
  @callback info(msg :: term(), state :: term()) ::
              {:ok, [action()], term()} | {:stop, reason :: term(), term()}
  @callback release(handles, mode, deadline) :: [term()]
  @optional_callbacks release: 3
end

# Requests, Core -> provider:
#   {:turn, turn_id, context}  {:steer, turn_id, steer_id, text}  {:interrupt, turn_id}
#   {:tool_result, turn_id, call_id, result}  :close  :idle_close
#   {:context, turn_id, {:ok, Helyx.Context.t()} | {:error, reason}}
#
# Actions, provider -> Core:
#   {:event, turn_id, event}  {:reply, from, value}  {:cancel_tool, call_id}
#   {:need_context, turn_id}
```

### The provider protocol

The rules of the contract above (#298, #299, #300).

**Start.** Core calls `id/0` once, at start. An `id/0` that raises, throws, exits, or returns a value that is not a binary, or an id that two providers share, stops Core from starting. A provider that does not export `init/3`, `request/3`, and `info/2` stops it too.

**The process.** The three callbacks run in one provider process per session, a Task of the hands, so `Helyx.Tool.hold/1` works in them, and a provider that holds a handle implements `release/3`. `info/2` gets every other message of the provider process: the port data, a monitor, a timer.

**Init.** `init/3` gets the checked tool specs of session start. Its `opts` carry `:core`, `:session_id`, `:cwd`, and `:resume_id`: the id of the program session to resume, or nil for a fresh one. The session passes the id of the provider's last `resume` event only when the last assistant message of the transcript came from this provider and its stop reason is not `:aborted` or `:error` (`Transcript.resumable/3`).

**Replies.** `request/3` gets a request from Core with its `from`. The provider replies now or later with the action `{:reply, from, value}`.

- `{:turn, ...}` and `{:interrupt, ...}` take `:ok` or `{:error, reason}`.
- `:close` takes `:ok` after the program exited.
- `{:steer, turn_id, steer_id, text}` comes only after the `:ok` of its turn. It takes `:ok` when the program has the steer, `:rejected` when it is confirmed that the program did not get it (the terminal of the turn went out first, or the program refused it), and `{:error, reason}` when it is not known. The session queues a rejected steer for the next turn and never sends a steer again. While a written steer is unresolved, the provider does not end the turn. When the program takes it, the provider sends the event `{:user_message, steer_id}`, and the session appends the user message there, with its own text of the steer. A taken steer first closes the open assistant message, as a `message_end` does, and then gives `aborted` to every call that is still open, the calls of the message it closed too (`take_steer/2` in `Helyx.Session.Server.Records`).
- `:idle_close` comes after the session was idle with the program for `provider_ms.idle` (`Helyx.Session.Server`). It takes `:ok` after the program exited, as `:close`, or `:busy` when the program still runs work of its own, such as a background task. With `:busy` the program stays, and the session asks again after the next idle time.

**Actions and events.** `init/3` returns `{:ok, state}` or `{:error, reason}`. `request/3` and `info/2` return `{:ok, actions, state}`, and `info/2` can also return `{:stop, reason, state}`. The actions are `{:event, turn_id, event}` with a stream event, `{:reply, from, value}`, `{:cancel_tool, call_id}` (#384), and `{:need_context, turn_id}`. Each event passes the check of `Helyx.Session.Stream`. `Helyx.Session.ProviderProcess` drops an empty text or thinking delta. A turn ends at its `done` or `error` event. Consecutive deltas of one kind form one block. A tool call arrives whole; a provider that streams tool call arguments assembles them first. There is no image event: providers do not produce image blocks. `stop_reason` is the closed set that `Helyx.Message` owns (`Helyx.Message.stop_reasons/0`, without `aborted` and `error`, which only the session gives, #432): a provider normalizes whatever its wire protocol reports into it. A `done` or `error` terminal leaves the check with the integer cap (`Helyx.Message.cap_integers/1`), ready to send; the provider process sends it as it is (#383).

- `{:message_end, stop_reason, usage}`: optional (#385). The assistant message so far is complete, with this usage. `Helyx.Provider.Loop` sends it before its `tool_request` events; the harness providers send none. The session closes the open assistant message by itself, with no usage, at the first `tool_result` of one of its calls (stop reason `:tool_use`), at a taken steer (stop reason from the message, as before), and at the terminal. Send it once per message, only after content (a delta or a tool call) that no earlier close closed, and only when every call of the messages before it has its result: at each close the session gives every call of the earlier messages that is still open an `aborted` result and drops a later result; the calls of the closed message stay open for their `tool_result` events until the next close. The `done` event closes the last assistant message, so a provider sends no `message_end` for that message: a `message_end` right before `done` adds an empty assistant message (`Helyx.Session.Server.Records.finish/2`). At an `error` event or an abort, open content with text only joins with stop `:error` or `:aborted` (#432); open content with a tool call joins with stop `:tool_use`, and its calls get `aborted` (#385). At the end of the turn, the session gives `aborted` to every call with no result.
- `{:tool_result, call_id, {:ok | :error, binary}}`: the result of a tool call. The first result of a call of the open message closes that message first (#385). The provider cuts the text to the tool result limits before it sends the event, as a tool does; the session does not cut it. A text over `@max_tool_result_bytes` (`Helyx.Session.Stream`) fails the turn with `{:tool_result_too_large, bytes, limit}`.
- `{:resume, id, cut}`: the program started a fresh program session with this id; `cut` is the number of transcript messages the provider left out of what it sent to it.

**Stops.** A malformed event (the reason `{:bad_stream_event, event}`), a reply of the wrong shape or for no open request, an error reply to `{:turn, ...}` or `{:interrupt, ...}`, and a bad return stop the provider process: its port closes, and the watchdog stops the program. Core does not limit the open requests: the session bounds each kind (`Bounds` in `docs/features/session-lifecycle.md`).

**A program turn.** A turn that the program starts by itself: the event `:turn_start`, with a new `turn_id` that the provider makes (an id that `Helyx.Message.resume_id?/1` accepts), opens it. With no turn and no wait, the session opens a turn with that id and no user message, and emits `turn_start` with `%{origin: :provider}`. The later events of the turn and its terminal work as for any turn, and so do a steer and an interrupt of it. At any other time the session drops it and its events, and each tool request of it gets `aborted` ("Helyx tools inside the program"); a context request of it gets nothing. The provider then must accept the next `{:turn, ...}` while the program turn runs. The provider process passes every `:turn_start` with a valid id to the session, and only the session decides (#358).

**Helyx tools inside the program.** The event `{:tool_request, call_id, name, arguments}` asks the session to run the Helyx tool `name`. `call_id` is an id that the provider maps to its call: the call id of the program's own events, which put the call and its result in the transcript, or the model's call id (`Helyx.Provider.Loop`, which sends the call and its result as `tool_call` and `tool_result` events). This event only runs the tool. A request that the provider cannot map to such an id gets an error answer from the provider and gives no event. The session is the only owner of the tool requests of a turn (#358): the provider process checks each request (`Helyx.Session.Stream`) and passes it on. The session runs the requests of a turn one at a time, and at most 16 wait behind the running one (`Helyx.Session.ToolQueue`). It sends each result as the request `{:tool_result, turn_id, call_id, {:ok | :error, text}}`, which takes `:ok` when it is written, with the armed kill of every session request. Each call gets exactly one result: the result of its run, or an error result from the session. The error results: `aborted` for each open request at the end of its turn, before the interrupt or the next turn; `aborted` for a request of a turn that is not current (ended, or a program turn that the session did not open); "too many Helyx tool calls" for a request over the 16 waiting; "Helyx tool calls too large" for a request that takes the running and waiting calls over 8 MiB (#430; a withdrawn running call keeps its bytes until the result of its run); and "tool call not run" for a request whose arguments hold an integer over the digit limit. A tool result can arrive after the interrupt or the next turn of its turn. Each call still gets exactly one result. A tool request whose call id is open in the turn (it runs or waits) is outside the contract: the session fails the turn and stops the provider process. A request whose call id the turn already answered is not checked anywhere and runs again: accepted, because no real program reuses a call id; tool-use ids are unique API ids (#369). `Helyx.Provider.Loop` checks one message itself: a call id that repeats in it ends the provider process (#380). The action `{:cancel_tool, call_id}` withdraws a request of the running turn: the session kills its run, drops the result of the run, and answers the call `aborted`; a waiting request gets `aborted` at once.

**A fresh context.** The action `{:need_context, turn_id}` asks for the context of the running turn, built again from the transcript, with ModelContext and Compaction run on it with `:turn_id` in their options ("The context request" below). The session applies every event before it in the action list first. The context holds the transcript. A `message_end`, the first `tool_result` of a call of the open message, or a taken steer (its `user_message` event; a `user_message` that takes no steer closes nothing) closes the open assistant message and appends it, so only the current assistant message that none of them closed is not in the context. The session accepts it only for its submitted turn with no context request open (`Turn.phase`); for the current turn at any other time it is a bad action, the turn fails, and the provider process stops. A request of a turn that is not current is dropped. The context comes as the request `{:context, turn_id, {:ok, context} | {:error, reason}}`, under `prepare_ms` (`Helyx.Session.Server.State`); a failed or killed build gives `{:error, reason}`. The provider replies `:ok` within the reply bound, as to a `tool_result` request. After its interrupt or its terminal, the provider must not wait for the context: the session does not send a context for a turn that ended.

**Deadlines.** Every request from the session has a deadline: a kill of the provider process armed with the request at the OTP timer server (`:timer.kill_after/2`), which Core cancels when the provider replies. A connect has `connect_ms` (`Helyx.Session.Hands`) from the start to the end of `init/3`. A callback that blocks is killed at the bound, however busy the session is. The turn fails with `:provider_timeout`. A crash fails it with `{:task_exit, reason}`, and a stop of the provider process with its stop reason, for example `{:provider_stop, reason}` from `info/2` or `{:provider_init, reason}` from `init/3`. Core takes this reason from the exit reason of the provider process (`Helyx.Session.Hands`): `:killed` gives `:provider_timeout`, `{:shutdown, reason}` gives `reason`, and any other exit gives `{:task_exit, reason}`. The one exception: when the release of a handle that the provider process held is not confirmed, the turn fails with that release error. So a callback or a linked process that exits with `:killed` or with `{:shutdown, reason}` gives the same failure as a deadline or a stop. The next turn starts a new provider process. Every `tool_result` and `context` request comes from the session with its armed kill (#358), so a provider that does not answer one is killed at the bound.

### The context request

**C1 Why.** A harness program keeps its own history. An API provider calls the model again after each tool round, and each call needs the transcript with the new results and the taken steers. ModelContext and Compaction run on each such context with `:turn_id` in their options.

**C2 Order.** The provider returns `{:need_context, turn_id}` as an action, after the events that the context must hold. The loop in the provider process handles the actions in list order and sends each to the session from one process. So the session applies those events before it gets the request. Only the current assistant message that no close closed is not in the context ("A fresh context" above). When the message has content, the helper sends `message_end` before its tool requests and its `user_message` events, so its context holds the message.

**C3 Core.** The session accepts the action only for its submitted turn with no context request open (the phase `:context` of `Helyx.Session.Turn`). For the current turn at any other time it is a bad action: the turn fails, and the provider process stops. The session builds the base context from its transcript and tools and runs the prepare Task, as it does before `{:turn}`, under `prepare_ms`. The session sends the result as the request `{:context, turn_id, result}`. A failed or killed Task gives `{:error, reason}`. The provider replies `:ok`, as for `{:tool_result}`.

**C4 Abort and end.** A turn that ends takes its open context request with it: the session sends no context for it. At every turn end the session kills the prepare Task (#386). The session drops a late `{:prepared}` of a turn that is not current. The provider gets no answer and must not wait for one after its interrupt or its terminal. A `:turn_start` during a turn does not end that turn: the session drops it, so the turn keeps its tool requests and its open context request, and the dropped turn's tool requests get `aborted` (#319).

**C5 Harness providers.** Claude Code and Codex never send `:need_context`.

### `Helyx.Provider.Loop`

A public adapter in Core, `lib/helyx/provider/loop.ex` (Decision Q1). An API provider keeps `stream/3` and adds `use Helyx.Provider.Loop`. The helper defines `init/3`, `request/3`, and `info/2`. It runs each model call in a separate process, the model Task, so the provider process stays free to handle a steer or an interrupt. It has a `@moduledoc` contract and its own tests, and changes to it follow the compatibility rules of an interface.

| Request or message | What the helper does |
|---|---|
| `{:turn, id, context}` | Replies `:ok` at once, then starts the first model call with the context. |
| A stream event | Sends the deltas and the calls as events. A call whose arguments do not decode to a JSON object carries the raw argument text; Core gives it `%{}` and its rejection (`Helyx.Session.Stream.check/1`, #380). |
| The stream's done with calls | Sends `message_end`. Then it sends the event `{:tool_request, request_id, name, args}` for every call of the message at once, in call order. The session owns the queue and runs them one at a time (#358). The request id is the model's call id (#380). A call id that repeats in one message ends the provider process with `{:bad_stream_event, {:tool_call, call}}`, the generic contract break: the session could have answered the first call already, so its open-id check does not cover it. A call with a rejection reason (`Stream.check/1`) gets `{:error, "tool call not run: " <> reason}` from the session; it joins in call order as every result does. Past the 16 waiting requests of the session, a call gets its "too many Helyx tool calls" error: a message with more than 17 valid calls can lose some, and how many depends on how fast the first calls end (a known ceiling of the session bound, #362). |
| `{:tool_result, id, request_id, result}` | Replies `:ok` and keeps the result by its request id. In the same callback it sends the event `{:tool_result, call_id, result}` for each call that has its result when every earlier call also has its result, in call order, so the results join the transcript in call order whatever order they come in. |
| All calls have results | Sends `{:user_message, steer_id}` for each held steer, then `{:need_context, id}`, in that order (C2). |
| `{:context, id, {:ok, context}}` | Replies `:ok` and starts the next model call. If a steer came while the context was built, it sends its `user_message` and a new `{:need_context, id}` instead, so the model call gets the steer (C2). |
| `{:context, id, {:error, reason}}` | Replies `:ok` and ends the turn with `{:error, reason}`. The process stays. |
| The stream's done with no calls | If it holds a steer: sends its `user_message`, then `:need_context`, and calls the model again. Otherwise it sends `{:done, ...}`. |
| The stream's error, an end with no terminal, `{ref, {:failed, reason}}` or the `:DOWN` of the model Task (L2) | Sends `{:error, reason}`, `{:error, :stream_ended}`, or `{:error, {:task_exit, reason}}`. The provider process stays. |
| `{:steer, id, steer_id, text}` | In a live turn: replies `:ok` and holds the steer for the next model call. After its terminal: replies `:rejected`. |
| `{:interrupt, id}` | Stops the model Task with `Task.shutdown(task, :brutal_kill)` and waits for its death (L3), drops its held steers and its wait for a context or a result, and then replies `:ok`. |
| `:idle_close`, `:close` | Replies `:ok`, and the process ends with `{:shutdown, :closed}` (L1). It has no program to keep. |

The helper never sends `{:resume, ...}` or `:turn_start`, and it holds no handles, so it has no `release/3`.

### Process lifetime

A link stops a linked process only when the other process exits with a reason other than `:normal`.

**L1 No normal end.** `Session.ProviderProcess` never ends with the reason `:normal`.

- Returned stops: every stop path of the loop ends with `exit({:shutdown, reason})`: a close, an idle close, a bad event, a bad action, a bad return, a stop, and an error reply to a turn or an interrupt.
- Explicit normal exits: the body of the process (the call of `init/3` and the whole loop) runs inside one `try` with `catch :exit, :normal`, which ends the process with `exit({:shutdown, {:exit, :normal}})`. So a callback that calls `exit(:normal)` cannot end the process normally. Any other exit, a raise, and a throw already end it with a reason that is not `:normal`.
- A deadline kills the process with `:killed`.

None of these reasons is `:normal`, so every process linked to the provider process that does not trap exits ends with it. This also covers a linked process of an external provider plugin. The hands take the outcome of a Task from its exit (`hands.ex`, `outcome/4` and `down_reason/1`).

Stated limit: `Process.exit(self(), :normal)` in a callback ends the calling process with `:normal`, and no catch can stop that. Plugin code is compiled into the node, so this is accepted, for the same reason as the other plugin effects that `coding-agent.md` accepts. The lifetime tests cover `exit(:normal)`, not this call.

**L2 The model Task.** The helper starts each model call with `Task.async/1`, which links and monitors it, and keeps its `%Task{}`. The body of the Task catches a raise, a throw, and an exit around the stream and returns `{:failed, reason}` as its result. So a failing model call becomes the terminal `{:error, {:task_exit, reason}}`, and the provider process stays for the next turn. A Task that ends with a `:normal` signal, which no catch sees and the link does not carry, ends the turn the same way from its `:DOWN`. The provider process does not trap exits.

**L3 Interrupt.** At `{:interrupt, id}`, the helper calls `Task.shutdown(task, :brutal_kill)`: it unlinks the Task, kills it, waits for its `:DOWN`, and flushes its reply. It returns only after the Task is dead. The helper replies `:ok` to the interrupt only after that, so the abort never completes while a model call still runs. The helper keeps the reference of its current Task only, and ignores any message whose Task reference is not that one, such as a reply of an old Task.

**L4 A kill from outside.** A process other than the helper that kills the model Task ends the provider process too, through the link. The turn fails, and the next turn starts a new provider process.

## Bounds

| What | Bound | Over the bound |
|---|---|---|
| Open context requests | 1 per turn, and only for the submitted turn (C3) | a bad action, the turn fails, the process stops |
| Tool result and context result requests in flight | at most one per tool request and context request of the provider; at the end of a turn, at most 17 aborted results go out in one batch. No answer is awaited: a late reply is dropped by its ref (#361) | the armed kill of each request; a kill that fires in the next turn fails that turn |
| Helyx tool requests, steers, events into the session | `docs/features/session-lifecycle.md`, "Bounds" | — |
| Deadlines | `docs/features/session-lifecycle.md`, "Bounds" | the kill of the provider process |
| A model call | unbounded: the user aborts it. | — |
| Model calls of a turn in the helper | unbounded: the model decides when to stop | — |
| The `calls` list of one message in the helper | unbounded | — |
| The provider process mailbox | From the provider's own port or Task: the plugin's concern. From the model Task: a cap of 10,000 (`send_checked/3`). | the model call ends with `{:error, {:provider_behind, length, 10_000}}` |

## Ownership

| Resource | Created by | Held by | Released on normal end | Released when the holder crashes | Released on abort |
|---|---|---|---|---|---|
| The model Task | the helper, `Task.async/1` | the provider process (link and monitor) | its result | the link ends it, because the provider process never exits `:normal` (L1) | `Task.shutdown(task, :brutal_kill)` before the `:ok` (L3) |
| The provider process | the hands, `Hands.start_provider` | the hands | `:close` or `:idle_close` | the hands kill it | the interrupt, else the kill per request |
| The Helyx tool requests of a turn and their answers | the provider's `tool_request` events | the session (`Turn.tool_queue`, a `Helyx.Session.ToolQueue`, whose effects `Helyx.Session.Server.ToolRuns` runs) | each gets its result | a crash of the provider process fails the turn; the hands kill the running call | the waiting ones and the killed running one get `aborted` before the interrupt |
| The prepare Task of a context request | the session (#386) | the session, monitored | its result, or the kill at the turn end; the session drops a late result (C4) | the session kills it at its stop; after an untrappable kill, its armed kill | the kill at the turn end (C4) |

## Out of scope

- Removing any reply of the provider protocol, the tool result ack, or the steer ledger. Each is its own ticket with its own inventory (the "Replaced mechanism" section of `TEMPLATE.md`).
- An Anthropic Messages provider (ADR 0002).

## Decisions

- **Q1, where the helper lives (2026-10-02):** A, in Core, as a supported public adapter. Every API provider needs it, and it adapts the one interface to a simpler one, as `Helyx.Tool.hold/1` helps the tool interface. It knows no plugin kind. Option B put it in `plugins/bundled`; the Core tests that use `Helyx.Test.Provider` would then need their own copy of the loop, or move to `plugins/bundled`, because the root project cannot depend on `helyx_plugins`.
- **No deadline for a model call** (review 1). Abort and close have deadlines.
- **The session does not own the request deadlines with its own timer.** ADR 0007 rejects this: a busy session would kill late, and a late `:rejected` steer, which is queued again, would become a notice.
- **The request id of a call is the model's call id** (#380). #362 gave each call a second id from `System.unique_integer/1` because a model can repeat a call id in one message; no observed run showed it. The helper ends the provider process at a call id that repeats in one message, the generic failure of a malformed stream event.
- **`:provider_behind` is a stream error that a client sees.** When the model Task finds the provider process mailbox at the cap, the model call ends with `{:error, {:provider_behind, length, 10_000}}`. The client sees it as the error reason of that model call.
