# One provider path

Status: design decided on 2026-10-02, built in #298, #299, and #300 (build order steps 1 to 3). Built from the code at `58471ac`. The design went through five review rounds in one proposal with `session-subscribers.md`. The last round found no blocking issue.

## Goal

Core has two turn paths today. The local path runs an API provider's `stream/3` in a stream Task and runs the tool loop in the session. The connected path was built for Claude Code and Codex: a provider process, requests with replies, a tool queue with a start ask, and a completion wait (ADR 0007).

This feature makes the connected protocol the one provider protocol and renames it from "harness" to "provider". The OpenAI provider runs on it through a helper, `Helyx.Provider.Loop`. Then the local path is deleted. The protocol gets one addition: an async context request, so that an API provider gets a fresh context before each model call.

The protocol is not replaced. Its replies are how a provider process and the session agree on order: the start ask sees a terminal first, the interrupt reply confirms the stop, and the tool result reply confirms the write. Two earlier designs replaced the replies with message order, and two reviews found race gaps in each. So every reply stays.

Core then names no plugin kind (the rule in `AGENTS.md`, "Key design constraints"). A rule that every provider needs, such as the order of tool results, the completion before the next turn, and the outcome of a steer, stays in Core.

## Interface changes

### Renames

The behaviour of each renamed part stays the same.

| Today | After |
|---|---|
| `Helyx.Session.Harness` | `Helyx.Session.ProviderProcess` |
| Callbacks `harness_init/3`, `harness_request/3`, `harness_info/2` | `init/3`, `request/3`, `info/2`, required for every provider |
| `stream/3` | Not a callback of `Helyx.Provider`. It is the callback of `Helyx.Provider.Loop`. |
| `Helyx.Provider.turn/1`, `turn_mode` | Deleted |
| `:harness_down`, `:harness_ready`, `:harness_reply`, `:harness_request` | `:provider_down`, `:provider_ready`, `:provider_reply`, `:provider_request` |
| `harness_ms`, `@harness_close_ms`, `@harness_reply_ms`, `:harness_timeout` | `provider_ms`, `@provider_close_ms`, `@provider_reply_ms`, `:provider_timeout` |
| `Connection`, `Wait.harness`, `Hands.connect` | `ProviderConn`, `Wait.provider`, `Hands.start_provider` |
| Option `:harness_session_id` | `:resume_id` |
| Event `{:harness_session, id, cut}` | `{:resume, id, cut}`. The session file keeps the stored entry name `harness_session`, so no reader change and no migration test. |
| Client event `:harness_session` | `:provider_session`. Its data key `harness_session_id` is `resume_id`; the other data stays. The session file keeps its stored key `harness_session_id`. `tui/view_model.ex` changes in the same PR. |
| Event `:program_turn`, `Message.harness_id?/1` | `:turn_start`, `Message.resume_id?/1` |
| `Helyx.HarnessIO` (plugins) | Unchanged. It is plugin code for programs, so the harness name is correct there. |

### The contract

This is today's connected contract with the new names and one addition. The moduledoc of `provider.ex` gives it in short form. "The provider protocol" below holds every rule of it.

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

# Requests, Core -> provider (unchanged, plus one):
#   {:turn, turn_id, context}  {:steer, turn_id, steer_id, text}  {:interrupt, turn_id}
#   {:tool_result, turn_id, call_id, result}  :close  :idle_close
#   {:context, turn_id, {:ok, Helyx.Context.t()} | {:error, reason}}   # new
#
# Actions, provider -> Core (unchanged, plus one):
#   {:event, turn_id, event}  {:reply, from, value}  {:cancel_tool, turn_id, call_id}
#   {:need_context, turn_id}                                            # new
```

### The provider protocol

The rules of the contract above, as built (#298, #299, #300). The moduledoc of `Helyx.Provider` states the contract in short form and links here.

**Start.** Core calls `id/0` once, at start. An `id/0` that raises, throws, exits, or returns a value that is not a binary, or an id that two providers share, stops Core from starting. A provider that does not export `init/3`, `request/3`, and `info/2` stops it too.

**The process.** The three callbacks run in one provider process per session, a Task of the hands, so `Helyx.Tool.hold/1` works in them, and a provider that holds a handle implements `release/3`. `info/2` gets every other message of the provider process: the port data, a monitor, a timer.

**Init.** `init/3` gets the checked tool specs of session start. Its `opts` carry `:core`, `:session_id`, `:cwd`, and `:resume_id`: the id of the program session to resume, or nil for a fresh one. The session passes the id of the provider's last `resume` event only when the last assistant message of the transcript came from this provider, so a lost id or a switch from another provider gives nil.

**Replies.** `request/3` gets a request from Core with its `from`. The provider replies now or later with the action `{:reply, from, value}`.

- `{:turn, ...}` and `{:interrupt, ...}` take `:ok` or `{:error, reason}`.
- `:close` takes `:ok` after the program exited.
- `{:steer, turn_id, steer_id, text}` comes only after the `:ok` of its turn. It takes `:ok` when the program has the steer, `:rejected` when it is confirmed that the program did not get it (the terminal of the turn went out first, or the program refused it), and `{:error, reason}` when it is not known. The session queues a rejected steer for the next turn and never sends a steer again. While a written steer is unresolved, the provider does not end the turn. When the program takes it, the provider sends the event `{:user_message, steer_id}`, and the session appends the user message there, with its own text of the steer. A taken steer first closes the open assistant message, as a `message_end` does, and then gives `aborted` to every call that is still open, the calls of the message it closed too (`take_steer/2` in `Helyx.Session.Server.Messages`).
- `:idle_close` comes after the session was idle with the program for `provider_ms.idle` (`Helyx.Session.Server`). It takes `:ok` after the program exited, as `:close`, or `:busy` when the program still runs work of its own, such as a background task. With `:busy` the program stays, and the session asks again after the next idle time.

**Actions and events.** `init/3` returns `{:ok, state}` or `{:error, reason}`. `request/3` and `info/2` return `{:ok, actions, state}`, and `info/2` can also return `{:stop, reason, state}`. The actions are `{:event, turn_id, event}` with a stream event, `{:reply, from, value}`, `{:cancel_tool, turn_id, call_id}`, and `{:need_context, turn_id}`. Each event passes the check of `Helyx.Session.Stream`. A turn ends at its `done` or `error` event. Consecutive deltas of one kind form one block. A tool call arrives whole; a provider that streams tool call arguments assembles them first. There is no image event: providers do not produce image blocks. `stop_reason` is the closed set that `Helyx.Message` owns (`Helyx.Message.stop_reasons/0`): a provider normalizes whatever its wire protocol reports into it. A `{:notice, text}` event is a notice for the user, such as an error of the program that a later part of the turn made obsolete. Its text is valid UTF-8 of at most `Helyx.Provider.max_notice_bytes/0` bytes. The session sends it as a `:notice` event and keeps it out of the transcript and the assistant message.

- `{:message_end, stop_reason, usage}`: the assistant message so far is complete. Its tool calls ran inside the program, or the provider runs them after it as `tool_request` events (`Helyx.Provider.Loop`); each call gets its result as a `tool_result` event. Send it once per message, only after content (a delta or a tool call) that no earlier `message_end` closed, and only when every call of the messages before it has its result: at each `message_end` the session gives every call of the earlier messages that is still open an `aborted` result and drops a later result; the calls of the closed message stay open for their `tool_result` events until the next `message_end` or a taken steer. The `done` event closes the last assistant message, so a provider sends no `message_end` for that message: a `message_end` right before `done` adds an empty assistant message (`Helyx.Session.Server`, `end_turn/2`). An `error` event drops the content that no `message_end` and no taken steer closed. At the end of the turn, the session gives `aborted` to every call with no result.
- `{:tool_result, call_id, {:ok | :error, binary}}`: the result of a tool call of a completed message. The provider cuts the text to the tool result limits before it sends the event, as a tool does; the session does not cut it. A text over `@max_tool_result_bytes` (`Helyx.Session.Stream`) fails the turn with `{:tool_result_too_large, bytes, limit}`.
- `{:resume, id, cut}`: the program started a fresh program session with this id; `cut` is the number of transcript messages the provider left out of what it sent to it.

**Stops.** A malformed event (the reason `{:bad_stream_event, event}`), a reply of the wrong shape or for no open request, an error reply to `{:turn, ...}` or `{:interrupt, ...}`, and a bad return stop the provider process: its port closes, and the watchdog stops the program. Core does not limit the open requests: the session bounds each kind (`Bounds` in `docs/features/long-lived-harness.md`, #361).

**A program turn.** A turn that the program starts by itself: the event `:turn_start`, with a new `turn_id` that the provider makes (an id that `Helyx.Message.resume_id?/1` accepts), opens it. With no turn and no wait, the session opens a turn with that id and no user message, and emits `turn_start` with `%{origin: :provider}`. The later events of the turn and its terminal work as for any turn, and so do a steer and an interrupt of it. At any other time the session drops it and its events, and each tool request of it gets `aborted` ("Helyx tools inside the program"); a context request of it gets nothing. The provider then must accept the next `{:turn, ...}` while the program turn runs. The provider process passes every `:turn_start` with a valid id to the session, and only the session decides (#358).

**Helyx tools inside the program.** The event `{:tool_request, call_id, name, arguments}` asks the session to run the Helyx tool `name`. `call_id` is an id that the provider maps to its call: the call id of the program's own events, which put the call and its result in the transcript, or a request id that the provider makes (`Helyx.Provider.Loop`, which sends the call and its result as `tool_call` and `tool_result` events with the model's call id). This event only runs the tool. A request that the provider cannot map to such an id gets an error answer from the provider and gives no event. The session is the only owner of the tool requests of a turn (#358): the provider process checks each request (`Helyx.Session.Stream`) and passes it on. The session runs the requests of a turn one at a time, and at most 16 wait behind the running one (`Helyx.Session.Server.Tools`). It sends each result as the request `{:tool_result, turn_id, call_id, {:ok | :error, text}}`, which takes `:ok` when it is written, with the armed kill of every session request. Each call gets exactly one result: the result of its run, or an error result from the session. The error results: `aborted` for each open request at the end of its turn, before the interrupt or the next turn; `aborted` for a request of a turn that is not current (ended, or a program turn that the session did not open); "too many Helyx tool calls" for a request over the 16 waiting; and "tool call not run" for a request whose arguments hold an integer over the digit limit. A tool result can arrive after the interrupt or the next turn of its turn. Each call still gets exactly one result. A tool request whose call id is open in the turn (it runs or waits) is outside the contract: the session fails the turn and stops the provider process. A request whose call id the turn already answered is not checked anywhere and runs again: accepted, because no real program reuses a call id; tool-use ids are unique API ids (#369). The action `{:cancel_tool, turn_id, call_id}` withdraws a request: the session kills its run, drops the result of the run, and answers the call `aborted`; a waiting request gets `aborted` at once.

**A fresh context.** The action `{:need_context, turn_id}` asks for the context of the running turn, built again from the transcript, with ModelContext and Compaction run on it with `:turn_id` in their options ("The context request" below). The session applies every event before it in the action list first. The context holds the transcript. A `message_end` or a taken steer (its `user_message` event; a `user_message` that takes no steer closes nothing) closes the open assistant message and appends it, so only the current assistant message that neither closed is not in the context. The session accepts it only for its submitted turn with no context request open (`Turn.phase`); for the current turn at any other time it is a bad action, the turn fails, and the provider process stops. A request of a turn that is not current is dropped. The context comes as the request `{:context, turn_id, {:ok, context} | {:error, reason}}`, under `prepare_ms` (`Helyx.Session.Hands`); a failed or killed build gives `{:error, reason}`. The provider replies `:ok` within the reply bound, as to a `tool_result` request. After its interrupt or its terminal, the provider must not wait for the context: the session does not send a context for a turn that ended.

**Deadlines.** Every request from the session has a deadline: a kill of the provider process armed with the request at the OTP timer server (`:timer.kill_after/2`), which Core cancels when the provider replies. A connect has `connect_ms` (`Helyx.Session.Hands`) from the start to the end of `init/3`. A callback that blocks is killed at the bound, however busy the session is. The turn fails with `:provider_timeout`. A crash fails it with `{:task_exit, reason}`, and a stop of the provider process with its stop reason, for example `{:provider_stop, reason}` from `info/2` or `{:provider_init, reason}` from `init/3`. Core takes this reason from the exit reason of the provider process (`Helyx.Session.Hands`): `:killed` gives `:provider_timeout`, `{:shutdown, reason}` gives `reason`, and any other exit gives `{:task_exit, reason}`. The one exception: when the release of a handle that the provider process held is not confirmed, the turn fails with that release error. So a callback or a linked process that exits with `:killed` or with `{:shutdown, reason}` gives the same failure as a deadline or a stop. The next turn starts a new provider process. Every `tool_result` and `context` request comes from the session with its armed kill (#358), so a provider that does not answer one is killed at the bound.

### The context request

**C1 Why.** Today the session builds the context once, before `{:turn}`. A harness needs no more, because its program keeps its own history. An API provider calls the model again after each tool round, and each call needs the transcript with the new results and the taken steers. ModelContext and Compaction run on each such context with `:turn_id` in their options.

**C2 Order.** The provider returns `{:need_context, turn_id}` as an action, after the events that the context must hold. The loop in the provider process handles the actions in list order and sends each to the session from one process. So the session applies those events before it gets the request. Only the current assistant message that no `message_end` and no taken steer closed is not in the context ("A fresh context" above). When the message has content, the helper sends `message_end` before its tool requests and its `user_message` events, so its context holds the message.

**C3 Core.** The session accepts the action only for its submitted turn with no context request open (the phase `:context` of `Helyx.Session.Turn`). For the current turn at any other time it is a bad action: the turn fails, and the provider process stops. The session builds the base context from its transcript and tools and runs the prepare Task in the hands, as it does before `{:turn}` today, under `prepare_ms`. The session sends the result as the request `{:context, turn_id, result}`. A failed or killed Task gives `{:error, reason}`. The provider replies `:ok`, as for `{:tool_result}`. The request is not in the pool of 8.

**C4 Abort and end.** A turn that ends takes its open context request with it: the session sends no context for it. At an interrupt or a failed turn, the cancel request of the hands kills the prepare Task with the other Tasks of the turn (the hands cancel every Task of the turn id). At a normal terminal, the session sends the cancel request only when a Helyx tool still runs. Otherwise the prepare Task of an open context request runs on until its result, at most `prepare_ms` (accepted in #299). The session drops a late `{:prepared}` of a turn that is not current, as it does today. The provider gets no answer and must not wait for one after its interrupt or its terminal. A `:turn_start` during a turn does not end that turn: the session drops it, so the turn keeps its tool requests and its open context request, and the dropped turn's tool requests get `aborted` (#319).

**C5 Harness providers.** Claude Code and Codex never send `:need_context`. Their code does not change for it.

### `Helyx.Provider.Loop`

A public adapter in Core, `lib/helyx/provider/loop.ex` (Decision Q1). An API provider keeps `stream/3` and adds `use Helyx.Provider.Loop`. The helper defines `init/3`, `request/3`, and `info/2`. It runs each model call in a separate process, the model Task, so the provider process stays free to handle a steer or an interrupt. It has a `@moduledoc` contract and its own tests, and changes to it follow the compatibility rules of an interface.

| Request or message | What the helper does |
|---|---|
| `{:turn, id, context}` | Replies `:ok` at once, then starts the first model call with the context. |
| A stream event | Sends the deltas and the calls as events. A call with arguments that do not decode is a rejected call: the helper sends it as a `tool_call` with the arguments that it could decode, or `%{}`, and remembers its reason. The reason is valid UTF-8 of at most 1,024 bytes and never holds the raw arguments. |
| The stream's done with calls | Sends `message_end`. Then it sends the event `{:tool_request, request_id, name, args}` for every valid call of the message at once, in call order. The session owns the queue and runs them one at a time (#358). A request id is unique in the node (`System.unique_integer/1`), because the session rejects a request id that is open in its turn and a model can repeat a call id in one message. A rejected call has the result `{:error, "tool call not run: " <> reason}` from the start; it joins in call order as every result does. Past the 16 waiting requests of the session, a call gets its "too many Helyx tool calls" error: a message with more than 17 valid calls can lose some, and how many depends on how fast the first calls end (a known ceiling of the session bound, #362). |
| `{:tool_result, id, request_id, result}` | Replies `:ok` and keeps the result by its request id. In the same callback it sends the event `{:tool_result, call_id, result}` for each call that has its result when every earlier call also has its result, in call order, so the results join the transcript in call order whatever order they come in. |
| All calls have results | Sends `{:user_message, steer_id}` for each held steer, then `{:need_context, id}`, in that order (C2). |
| `{:context, id, {:ok, context}}` | Replies `:ok` and starts the next model call. If a steer came while the context was built, it sends its `user_message` and a new `{:need_context, id}` instead, so the model call gets the steer (C2). |
| `{:context, id, {:error, reason}}` | Replies `:ok` and ends the turn with `{:error, reason}`. The process stays. |
| The stream's done with no calls | If it holds a steer: sends its `user_message`, then `:need_context`, and calls the model again. Otherwise it sends `{:done, ...}`. |
| The stream's error, an end with no terminal, `{ref, {:failed, reason}}` or the `:DOWN` of the model Task (L2) | Sends `{:error, reason}`, `{:error, :stream_ended}`, or `{:error, {:task_exit, reason}}`. These are today's reasons. The provider process stays. |
| `{:steer, id, steer_id, text}` | In a live turn: replies `:ok` and holds the steer for the next model call. After its terminal: replies `:rejected`. |
| `{:interrupt, id}` | Stops the model Task with `Task.shutdown(task, :brutal_kill)` and waits for its death (L3), drops its held steers and its wait for a context or a result, and then replies `:ok`. |
| `:idle_close`, `:close` | Replies `:ok`, and the process ends with `{:shutdown, :closed}` (L1). It has no program to keep. |

The helper never sends `{:resume, ...}` or `:turn_start`, and it holds no handles, so it has no `release/3`.

### Process lifetime

A link stops a linked process only when the other process exits with a reason other than `:normal`. Today the loop of `harness.ex` returns normally on several stop paths (`:closed`, `{:stop, reason}` for a bad event or a bad return). A model Task could then outlive its provider process. These rules close that gap for every exit path.

**L1 No normal end.** `Session.ProviderProcess` never ends with the reason `:normal`.

- Returned stops: every stop path that the loop returns today ends with `exit({:shutdown, reason})`: a close, an idle close, a bad event, a bad action, a bad return, a stop, and an error reply to a turn or an interrupt.
- Explicit normal exits: the body of the process (the call of `init/3` and the whole loop) runs inside one `try` with `catch :exit, :normal`, which ends the process with `exit({:shutdown, {:exit, :normal}})`. So a callback that calls `exit(:normal)` cannot end the process normally. Any other exit, a raise, and a throw already end it with a reason that is not `:normal`.
- A deadline kills the process with `:killed`.

None of these reasons is `:normal`, so every process linked to the provider process that does not trap exits ends with it. This also covers a linked process of an external provider plugin. The hands take the outcome of a Task from its exit (`hands.ex`, `outcome/4`): `harness_reason/1` (renamed) maps `{:exit, {:shutdown, reason}}` to the reason that it reports today.

Stated limit: `Process.exit(self(), :normal)` in a callback ends the calling process with `:normal`, and no catch can stop that. Plugin code is compiled into the node, so this is accepted, for the same reason as the other plugin effects that `coding-agent.md` accepts. The lifetime tests cover `exit(:normal)`, not this call.

**L2 The model Task.** The helper starts each model call with `Task.async/1`, which links and monitors it, and keeps its `%Task{}`. The body of the Task catches a raise, a throw, and an exit around the stream and returns `{:failed, reason}` as its result. So a failing model call becomes the terminal `{:error, {:task_exit, reason}}`, and the provider process stays for the next turn. A Task that ends with a `:normal` signal, which no catch sees and the link does not carry, ends the turn the same way from its `:DOWN`. The provider process does not trap exits.

**L3 Interrupt.** At `{:interrupt, id}`, the helper calls `Task.shutdown(task, :brutal_kill)`, the pattern of today's `shutdown_stream`: it unlinks the Task, kills it, waits for its `:DOWN`, and flushes its reply. It returns only after the Task is dead. The helper replies `:ok` to the interrupt only after that, so the abort never completes while a model call still runs. The helper keeps the reference of its current Task only, and ignores any message whose Task reference is not that one, such as a reply of an old Task.

**L4 A kill from outside.** A process other than the helper that kills the model Task ends the provider process too, through the link. The turn fails, and the next turn starts a new provider process. This is today's rule for a crash of a harness process.

### What users and clients see

| Today, with an API provider | After | Why acceptable |
|---|---|---|
| A steer that arrives in the last model call of a turn starts a new turn | It continues the same turn: one `agent_end`, not two | The transcript order is the same, and Claude Code and Codex behave like this today |
| `tool_execution_start` comes when each call starts to run | It comes for every call of the message at its `message_end`. The calls still run one at a time. | One rule for every provider. A client sees a call as started before it runs. |
| A snapshot lists only the running call | It lists every call with no result | The same reason |
| Client event `:harness_session` with the data key `harness_session_id` | `:provider_session` with the data key `resume_id` | Core names no plugin kind. The TUI changes in the same PR. |

ADR 0006 §5 requires a version increase for a rename and for a change of meaning. The rename of `:harness_session` and the new meanings of `tool_execution_start` and of the snapshot `running` are such changes. So this feature raises `contract_version` by itself. If `session-subscribers.md` lands in the same release, the two share one increase. The client compatibility tests go in the same PR as the increase.

### ADR changes

- ADR 0002 gets a revision: one provider kind. Every provider runs in a provider process. An API provider uses `Helyx.Provider.Loop`. This lands with the deletion of the local path.
- ADR 0007 gets a note: the provider process is for every provider, not only a harness.

## Replaced mechanism

1. Every part of the old mechanism.

The local path (`server.ex`, `stream.ex`, `turn.ex`, `provider.ex`). "loop" means the part moves to `Helyx.Provider.Loop`.

| Local mechanism today | Fate | Replacement or reason |
|---|---|---|
| The stream Task under the Core task supervisor, `Stream.run/1` | loop | The model Task of the helper |
| The context build in the stream Task before each call | kept | The prepare Task of the hands, through `{:need_context}` (C1–C4) |
| `Turn.calls`: the calls of a message run one at a time, in call order | loop | The helper sends every call of the message at once and puts the results in call order (#362). Core's tool queue runs them one at a time. |
| `{:rejected_tool_call, call, reason}`, `Turn.reject`, `Turn.rejection`, the `rejected` field | loop | The helper records the call and sends its error result. `Stream.check` rejects the event as malformed. |
| The 1,024-byte reason bound and the no-raw-arguments rule | loop | Checked in the helper. Core checks the result text with the tool result limit. |
| Queued steers join the transcript before the next provider call (`start_provider_call`, `append_steers`) | changed | A steer of a running turn goes to the provider (today's connected rule). The helper sends its `user_message` before the next model call. The transcript order is the same. |
| A steer left at the end of a local turn starts a new turn | changed | The helper calls the model again in the same turn. |
| `tool_execution_start` at each local run | changed | The connected rule: at the `message_end` of the message |
| `started_calls`: a local snapshot lists only the running call | changed | The snapshot lists every call with no result (the connected rule) |
| `shutdown_stream` (unlink, kill, flush), the `task` field, the `:EXIT` of the stream Task | loop | L2–L4. The session dies, the hands kill the provider process, and L1 ends the Task. |
| A local stream failure ends the turn, and nothing stays | changed | The provider process stays after an error terminal. A crash of the process ends the turn, and the next turn starts a new process (the connected rule). |
| `connected?` in `Stream.check` | deleted | One event set: today's connected set. `rejected_tool_call` is malformed for every provider. |
| `Helyx.Provider.turn/1`, the `turn_mode` field and switch | deleted | One path |

The connected path (`harness.ex`, `wait.ex`, `steers.ex`, `server.ex`). Every mechanism stays with its behaviour; only the names change.

| Mechanism | Fate |
|---|---|
| A kill per request at the OTP timer server, cancelled at the reply; the connect kill and `:provider_ready` | kept |
| The pool `@max_open` 8, with `{:error, :busy}` over it. Tool results and context results are outside the pool. | kept, then removed by #361: the session bounds each request kind |
| `live`, `calls`, `seen`, `running`, `started`, `waiting`; `@max_tools` 17; used ids; the duplicate open id as a bad action | kept, then moved to the session by #358 |
| The `{:tool_start}` ask with `:ok` or `:dropped` | kept, then removed by #358 |
| `end_tools` at the terminal, the interrupt, and the next turn, except a started call | kept, then removed by #358 |
| `write_result`: a reply inside the callback, else `{:tool_result_not_answered}` | kept, then removed by #358 |
| `cancel_tool`: started → kill, running and not started → `:dropped` at the ask, waiting → leaves the queue | kept, then moved to the session by #358 |
| An error reply to `{:turn}` or `{:interrupt}` ends the process; an error reply to a steer does not | kept |
| The loop returns `:closed` or `{:stop, reason}`, and the hands report the return value | changed: the loop exits with `{:shutdown, reason}` (L1). The reported reasons stay the same. |
| `program_turn` with the id check | kept as `:turn_start` |
| Every event checked; a terminal capped with `cap_integers`; the session mailbox cap of 10,000 | kept |
| The server phases `preparing`, `submitting`, `submitted` (#358 adds `context`), with a steer of `preparing` in the prompt and a steer of `submitting` sent at the `:ok` | kept |
| `Wait`: `hands`, `interrupt`, `reply`, `idle`, `harness`, `tool`, `callers`, `steers`, `results`, and its end condition | kept, with `harness` as `provider`; #358 makes `tool` a list `tools`; #361 keeps only `hands`, `reply`, `provider`, and `callers` (`long-lived-harness.md`, "Built in #361") |
| Steer states `:sent`, `:taken`, `:answered`, `:ended`, `:noticed`, and the effects take, requeue, notice | kept |
| The idle close with `:busy`; the close at a model switch and at the end; the four `:harness_down` clauses | kept |
| The resume id: `Transcript.resumable/3`, the #269 counts, the #282 fork rule | kept, with the stored entry name unchanged |

#358 moved the turn and its Helyx tool calls to the session, the only owner. Removed: `live`, `calls`, `seen`, `running`, `started`, `waiting`, and `context?` in the provider process; the `{:tool_start}` ask and its bound; `end_tools`; `{:turn_dropped, id}` (#339) with its accepted hole of a reused program turn id; `write_result` and `{:tool_result_not_answered}` / `{:context_not_answered}`, because every `tool_result` and `context` request now has its armed kill. A used call id is no longer answered "used before": it stops the provider process, as an open one did. The waiting bound of 16 moved to the session.

#362 removed the copy of that queue in `Helyx.Provider.Loop`: the `tool` field (the one request that waited for its result), the request counter `n`, the `{Helyx.Provider.Loop, :next, turn_id}` message to itself with its `info/2` clause, and the `context?` field with its guard on `{:context, ...}`. The session queue runs the calls one at a time. Each call gets a request id from `System.unique_integer/1` when it joins the list. The helper keeps the results by request id and sends them in call order. The session sends a context only after a `need_context` (C3), so the helper needs no record of an open request. `steers` stays: a `user_message` while calls are open would give them `aborted` in the session (`Messages.take_steer/2`), so a steer waits for the last result. Removed tests: "the next call goes out only after the result of the one before" and "a result that comes before the interrupt starts no next call after it". "Calls run in call order, one at a time" became "every call goes out at once; the results join in call order, whatever order they come in".

#369 made the session the one owner of the Helyx tool-call ids. The session checks only an open id (`tool` and `waiting` in `Helyx.Session.Turn`); `Turn.ids`, the set of every id of the turn, is gone. An answered id runs again. This is accepted, because no real program reuses an id. The reuse check of #203 came from a design rule, and no run showed a reuse. The `used` sets of both harness providers and the reuse check of `Helyx.HarnessIO.admit/3` are gone; each provider keeps its check that a call maps to a tool use and its answer for a call with no Helyx turn. The event `{:user_message, steer_id, text}` became `{:user_message, steer_id}`: the session always appended its own text. Removed tests: the provider tests of a reused call id (Codex: the two `used before` answers in "a call with no turn, one that does not map, ..."; Claude Code: "a call id that the provider rejected never gives a tool request later in the turn", now a test of the bad name and bad arguments only). The session test of an answered id now checks that it runs again.

#379 derives the open tool calls from the transcript: they are the calls of the last assistant message that the tool results after it do not answer (`Transcript.open_calls/1`, the rule of `insert_aborted`). No message goes between a call and its result, so no earlier call can be open. `Turn.calls`, the stored copy, is gone, and `Messages.abort_open_calls/1` is the one writer of the `aborted` results (`abort_turn_calls` is gone). The `:tool_result` clause and `Turn.snapshot/2` read the derived value; `running` and the `tool_execution_start`/`end` events do not change. Each lookup is O(n) over the transcript, as `append_message` is. Removed: the rule that a call id reused in a later message stays open until its own result; no real provider reuses an id (#369). Removed test: the `open_calls/1` case of one id in two assistant messages, now a case of one id twice in one message.

2. Removed replies: none. Every reply of the connected protocol stays. The local path had no replies; its order guarantees move as follows. Calls in call order: the helper sends the results as `tool_result` events in call order, and the session queue runs the calls one at a time (#362). Steers before the next model call: the helper sends the `user_message` events before `{:need_context}` in one action list, and the session applies them before it builds the context (C2).

3. Tests of the old mechanism:

| File | Tests | After |
|---|---|---|
| `test/helyx/session/harness_test.exs` | 56 | All kept, renamed to `provider_process_test.exs`. |
| `test/helyx/session/harness_tools_test.exs` | 26 | All kept, renamed. The tested code does not change. |
| `test/helyx/session/stream_test.exs` | 16 | The tests of `Stream.run` move to the tests of the helper. The tests of `Stream.check` and `Stream.prepare` stay. The `connected?` cases merge. |
| `test/helyx/interfaces/provider_test.exs` | 2 | The tests of `turn/1` are deleted. |
| `loop_test.exs`, `stream_events_test.exs`, `boundary_test.exs`, `persistence_test.exs`, `sweep_test.exs`, and the other session tests on `Helyx.Test.Provider` | — | They run through the helper. `Helyx.Test.Provider` in `test/support/interfaces.ex` keeps its scripted `stream/3` models and adds `use Helyx.Provider.Loop`. |

These tests change their property:

- `stream_events_test.exs`, "a snapshot of a local turn lists only the running call": it lists every call with no result.
- `stream_events_test.exs`, "a rejected tool call fails a connected turn, and nothing reaches the transcript": it becomes "a rejected_tool_call event is malformed".
- `loop_test.exs`, "a steer left at turn end starts a new turn": the steer continues the same turn.
- The tests that check when `tool_execution_start` comes. It now comes for every call at the `message_end`:
  - `loop_test.exs`: "tool calls run on the hands and the loop continues until the provider stops", "tool calls run one at a time, in call order" (the run order stays; the event order changes), "abort during tool calls ends the turn and answers every open call", "killing the session kills the hands and the tool Task", "steers during a tool run reach the next provider call after the result, in order", "abort drops queued steers and follow-ups", "a full queue rejects the next steer or follow-up", and the test at the digit limit.
  - `boundary_test.exs`: "a switch during a turn takes effect on the next turn".
  - `persistence_test.exs`: "resume after a crash mid-turn answers every open tool call".
  - `sweep_test.exs`: the test that waits for `tool_execution_start`.

Each such test keeps its property where only the event timing changes. The PR lists each test that changes and why.

`loop_test.exs`, "a rejected call gets an error result with its reason; the text and the good call stay", and "tool calls run one at a time, in call order" keep their run properties through the helper and the session queue.

New tests:

- `provider_process_test.exs`: a context request gives a fresh context with `:turn_id`; an interrupt during a context request; a second open context request stops the process; a context error ends the turn and keeps the process; every stop path (close, bad event, bad return, stop, error reply, deadline kill) and a callback that calls `exit(:normal)` in `init/3`, `request/3`, or `info/2` each end a linked process (L1).
- Helper tests: a bad event ends the provider process and its model Task. A raising, throwing, or exiting stream gives `{:task_exit, reason}`, and the process takes the next turn. The `:ok` of an interrupt comes only after the model Task is dead, and a late message of the old Task changes nothing (L3). Calls run in call order, a rejected call gets its result, and a steer continues the turn.
- Client compatibility tests: a snapshot carries the new `contract_version`. The TUI renders `:provider_session`, the new `tool_execution_start` timing, and the new snapshot `running`. A client that does not support the version says so and does not render (ADR 0006 §5).
- Plugin tests: callback renames only for Claude Code and Codex. OpenAI and the fake provider run through the helper.

4. What clients see: the table "What users and clients see" above.

5. States with no bound: a model call; the model calls of a turn in the helper; the `calls` list of one message in the helper (see Bounds).

## Bounds

| What | Bound | Over the bound |
|---|---|---|
| Open tool requests of a turn | one runs, 16 wait (`server/tools.ex`, `@max_waiting`) | the session answers the call with the error result "too many Helyx tool calls" |
| Open context requests | 1 per turn, and only for the submitted turn (C3) | a bad action, the turn fails, the process stops |
| Tool result and context result requests in flight | at most one per tool request and context request of the provider; at the end of a turn, at most 17 aborted results go out in one batch. No answer is awaited: a late reply is dropped by its ref (#361) | the armed kill of each request; a kill that fires in the next turn fails that turn |
| Steers | 32, queued and open together (`queue.ex`, `@limit`) | `{:error, :queue_full}` |
| Events into the session | the session mailbox cap, 10,000 (`stream.ex`, `send_checked/3`) | nothing is sent, `{:error, {:session_behind, length, 10_000}}` |
| Deadlines | `connect_ms` 30 s and `prepare_ms` 10 s (`hands.ex`; `prepare_ms` also for each context request), the reply bound 2 s per request (`server/state.ex`, `@provider_reply_ms`), the close bound 5 s (`@provider_close_ms`), idle 30 min | the kill of the provider process. The helper replies to `{:turn}` at once, so the 2 s bound never covers a model call. |
| A model call | unbounded: the user aborts it. The same as the local path today. | — |
| Model calls of a turn in the helper | unbounded: the model decides when to stop, as in the local path today | — |
| The `calls` list of one message in the helper | unbounded, as the local path was | — |
| The provider process mailbox | from Core: bounded by the rows above. From the provider's own port or Task: the plugin's concern, as today. From the model Task: the same cap of 10,000 (`send_checked/3`). | the model call ends with `{:error, {:provider_behind, length, 10_000}}` |

## Ownership

| Resource | Created by | Held by | Released on normal end | Released when the holder crashes | Released on abort |
|---|---|---|---|---|---|
| The model Task | the helper, `Task.async/1` | the provider process (link and monitor) | its result | the link ends it, because the provider process never exits `:normal` (L1) | `Task.shutdown(task, :brutal_kill)` before the `:ok` (L3) |
| The provider process | the hands, `Hands.start_provider` | the hands | `:close` or `:idle_close` | the hands kill it | the interrupt, else the kill per request |
| The Helyx tool requests of a turn and their answers | the provider's `tool_request` events | the session (`Turn.tool`, `Turn.waiting`, `Helyx.Session.Server.Tools`) | each gets its result | a crash of the provider process fails the turn; the hands kill the running call | the waiting ones and the killed running one get `aborted` before the interrupt |
| The prepare Task of a context request | the hands | the hands | its result, also after the terminal of the turn, at most `prepare_ms`; the session drops the late result (C4) | the hands end with the session | the cancel of the turn's Tasks (C4) |

## Out of scope

- Removing any reply of the provider protocol, the tool result ack, or the steer ledger. Each is its own ticket with its own inventory (the "Replaced mechanism" section of `TEMPLATE.md`).
- Splitting `server.ex`. Measure after this feature and `session-subscribers.md`.
- An Anthropic Messages provider (ADR 0002).

## Decisions

- **Q1, where the helper lives (2026-10-02):** A, in Core, as a supported public adapter. Every API provider needs it, and it adapts the one interface to a simpler one, as `Helyx.Tool.hold/1` helps the tool interface. It knows no plugin kind. Option B put it in `plugins/bundled`; the Core tests that use `Helyx.Test.Provider` would then need their own copy of the loop, or move to `plugins/bundled`, because the root project cannot depend on `helyx_plugins`.
- **No deadline for a model call** (review 1). Abort and close have deadlines.
- **The session does not own the request deadlines with its own timer.** ADR 0007 rejects this: a busy session would kill late, and a late `:rejected` steer, which is queued again today, would become a notice.
- **The helper gives each call a tool request id of its own** (`System.unique_integer/1`, #362) and maps each one to the model's call id. A request id that is open in the turn stops the provider process (#358), and a model can repeat a call id in one message. The transcript, `tool_execution_start` and `tool_execution_end`, and the snapshot still carry the model's real call ids.
- **`:provider_behind` is a stream error that a client sees.** When the model Task finds the provider process mailbox at the cap, the model call ends with `{:error, {:provider_behind, length, 10_000}}`. The client sees it as the error reason of that model call.

## Build order

1. Renames, with no change of behaviour except the client event. The `contract_version` increase and the client compatibility tests.
2. The context request (C1–C5) and the lifetime rules (L1), with their tests.
3. `Helyx.Provider.Loop` (L2–L4), OpenAI and the test fakes on it, and the deletion of the local path. The ADR 0002 revision and the ADR 0007 note.
