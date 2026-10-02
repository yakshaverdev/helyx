defmodule Helyx.Provider do
  # The text of a notice: an error line of a program with room for context.
  # The one source: the session checks it, and the bundled providers cut to
  # it (`Helyx.HarnessIO.cap_error/1`).
  @max_notice_bytes 2_000

  @moduledoc """
  Produces assistant messages for a session.

  A provider plugin implements this behaviour. `id/0` is the prefix in a model
  ref such as `fake/echo`. Core calls `id/0` once, at start: an `id/0` that
  raises, throws, exits, or returns a value that is not a binary, or an id
  that two providers share, stops Core from starting. A provider that does
  not export `init/3`, `request/3`, and `info/2` stops it too.

  Every provider runs in one provider process per session (ADR 0002, ADR
  0007). An API provider, which calls a model and lets the session run the
  tools, implements `stream/3` of `Helyx.Provider.Loop` and adds `use
  Helyx.Provider.Loop`, which defines the three callbacks. A harness
  provider drives an agent program that runs the whole turn and its own
  tools (`docs/features/long-lived-harness.md`).

  ## Events

  A provider sends the events of a turn as actions (see below):

    * `{:text_delta, binary}`: a delta of assistant text
    * `{:thinking_delta, binary}`: a delta of thinking text
    * `{:tool_call, Helyx.Message.ToolCall.t()}`: one complete tool call
    * `{:notice, text}`: a notice for the user, such as an error of the
      program that a later part of the turn made obsolete. `text` is valid
      UTF-8 of at most #{@max_notice_bytes} bytes (`max_notice_bytes/0`).
      The session sends it as a `:notice` event and keeps it out of the
      transcript and the assistant message
    * `{:done, %{stop_reason: stop_reason, usage: map}}`: the call finished
    * `{:error, term}`: the call failed

  Consecutive deltas of one kind form one block. A tool call arrives whole;
  a provider that streams tool call arguments assembles them first. There is
  no image event: providers do not produce image blocks. A malformed event
  stops the provider process with `{:bad_stream_event, event}`.

  `stop_reason` is the closed set that `Helyx.Message` owns
  (`Helyx.Message.stop_reasons/0`): a provider normalizes whatever its wire
  protocol reports into it.

  ## The provider process

  The three callbacks run in one provider process per session, a Task of
  the hands, so `Helyx.Tool.hold/1` works in them and a provider that holds
  a handle implements `release/3`:

    * `init/3` starts the provider. `tools` are the checked tool
      specs of session start; `opts` carry `:core`, `:session_id`, `:cwd`,
      and `:resume_id`: the id of the program session to resume,
      or nil for a fresh one. The session passes the id of the provider's
      last `resume` event only when the last assistant message of the
      transcript came from this provider, so a lost id or a switch from
      another provider gives nil.
    * `request/3` gets a request from Core with its `from`. The
      provider replies now or later with the action `{:reply, from,
      value}`: `{:turn, ...}` and `{:interrupt, ...}` take `:ok` or
      `{:error, reason}`, and `:close` takes `:ok` after the program exited.
      `{:steer, turn_id, steer_id, text}` comes only after the `:ok` of
      its turn. It takes `:ok` when the program has the steer,
      `:rejected` when it is confirmed that the program did not get it
      (the terminal of the turn went out first, or the program refused
      it), and `{:error, reason}` when it is not known. The session queues
      a rejected steer for the next turn and never sends a steer again.
      While a written steer is unresolved, the provider does not end the
      turn; when the program takes it, the provider sends the event
      `{:user_message, steer_id, text}`, and the session appends the user
      message there.
      `:idle_close` comes after the session was idle with the program
      for `provider_ms.idle` (`Helyx.Session.Server`): it takes `:ok` after
      the program exited, as `:close`, or `:busy` when the program still
      runs work of its own, such as a background task. With `:busy` the
      program stays, and the session asks again after the next idle time.
    * `info/2` gets every other message of the provider process: the
      port data, a monitor, a timer.

  Each callback returns actions: `{:event, turn_id, event}` with a stream
  event, `{:reply, from, value}`, `{:cancel_tool, turn_id, call_id}`, and
  `{:need_context, turn_id}`.
  Each event passes the check of the events above. A turn ends at its
  `done` or `error` event. A provider can also send:

    * `{:message_end, stop_reason, usage}`: the assistant message so far is
      complete; its tool calls ran inside the program. Send it once per
      message, only after content (a delta or a tool call) that no earlier
      `message_end` closed, and only when every call of the messages before
      it has its result: the session gives every call that is still open an
      `aborted` result at each `message_end` and drops a later result. At
      the end of the turn, a provider sends every `message_end` that it did
      not send yet, and the session aborts the calls with no result
    * `{:tool_result, call_id, {:ok | :error, binary}}`: the result of a
      tool call of a completed message. The provider cuts the text to the
      tool result limits before it sends the event, as a tool does; the
      session does not cut it. A text over `@max_tool_result_bytes`
      (`Helyx.Session.Stream`) fails the turn with
      `{:tool_result_too_large, bytes, limit}`
    * `{:resume, id, cut}`: the program started a fresh program
      session with this id; `cut` is the number of transcript messages the
      provider left out of what it sent to it

  A malformed event, a reply of
  the wrong shape or for no open request, an error reply to `{:turn, ...}`
  or `{:interrupt, ...}`, and a bad return stop the provider process: its
  port closes, and the watchdog stops the program. At most `@max_open`
  (`Helyx.Session.ProviderProcess`) requests are open at once: Core answers one
  more with `{:error, :busy}` and does not give it to the provider.

  A turn that the program starts by itself: the event `:turn_start`, with
  a new `turn_id` that the provider makes (an id that
  `Helyx.Message.resume_id?/1` accepts), opens
  it. With no turn and no wait the session
  opens a turn with that id and no user message, and emits
  `turn_start` with `%{origin: :program}`; the later events of the turn and
  its terminal work as for any turn, and so do a steer and an interrupt of
  it. At any other time the session drops it and its events. The provider
  then must accept the next `{:turn, ...}` while the program turn runs.

  Helyx tools inside the program: the event `{:tool_request, call_id, name,
  arguments}` asks the session to run the Helyx tool `name`. `call_id` is
  the id of the call in the program's own events, which put the call and
  its result in the transcript; this event only runs the tool. A request
  that the provider cannot map to such an id gets an error answer from the
  provider and gives no event. A provider that answers a request with a
  call id itself must record that id first: a later request with the
  same id in the turn gets an error too and gives no event. Core records
  the ids of the events it gets; it does not see the ids that the
  provider answered. The session runs the requests of a turn one
  at a time and sends each result as the request `{:tool_result, turn_id,
  call_id, {:ok | :error, text}}`, which takes `:ok` when it is written.
  The provider replies to every `tool_result` request inside the same
  callback, so the result is written before the next request; otherwise
  the provider process stops with `{:tool_result_not_answered, turn_id,
  call_id}`. A `tool_result` request does not count in the `@max_open` open
  requests. Core also sends this request itself with an error result: `aborted` for
  each open tool request at the end of its turn, at the interrupt before
  the provider sees it, and for a request of a turn that is not running;
  an error for a request over `@max_tools` (`Helyx.Session.ProviderProcess`), the
  limit of the requests of a turn, one running and the rest waiting,
  and for a call id that the turn used before. A second tool request
  with the id of an open request is a bad action and stops the provider
  process too. The action `{:cancel_tool, turn_id, call_id}` withdraws a
  request: the session stops its run, and a later result is dropped.

  A fresh context: the action `{:need_context, turn_id}` asks for the
  context of the running turn, built again from the transcript, with
  ModelContext and Compaction run on it with `:turn_id` in their options
  (`docs/features/one-provider-path.md`, "The context request"). The
  session applies every event before it in the action list first, so the
  context holds them. Core accepts it only for the running turn and only
  when no context request of that turn is open; any other one is a bad
  action and stops the provider process. The context comes as the request
  `{:context, turn_id, {:ok, context} | {:error, reason}}`, under
  `prepare_ms` (`Helyx.Session.Hands`); a failed or killed build gives
  `{:error, reason}`. The provider replies `:ok` inside the same callback,
  as to a `tool_result` request, or the provider process stops with
  `{:context_not_answered, turn_id}`; the request does not count in the
  `@max_open` open requests. After its interrupt or its terminal, the
  provider must not wait for the context: the request may never come.

  Every request has a deadline: a kill of the provider process armed with
  the request at the OTP timer server (`:timer.kill_after/2`), which Core
  cancels when the provider replies. A connect has `connect_ms`
  (`Helyx.Session.Hands`) from the start to the end of `init/3`. A
  callback that blocks is killed at the bound, however busy the session
  is. The turn fails with
  `:provider_timeout`. A crash fails it with `{:task_exit, reason}`, and a
  stop with its reason. The next turn starts a new provider process.
  """

  use Helyx.Interface, mode: :multi, required: true

  @type stop_reason :: Helyx.Message.stop_reason()

  @type stream_event ::
          {:text_delta, String.t()}
          | {:thinking_delta, String.t()}
          | {:tool_call, Helyx.Message.ToolCall.t()}
          | {:notice, String.t()}
          | {:done, %{stop_reason: stop_reason(), usage: map()}}
          | {:error, term()}
          | {:message_end, stop_reason(), map()}
          | {:tool_result, String.t(), {:ok | :error, String.t()}}
          | {:resume, String.t(), non_neg_integer()}
          | {:user_message, String.t(), String.t()}
          | {:tool_request, call_id :: String.t(), name :: String.t(), arguments :: map()}
          | :turn_start

  @typedoc "The ref of a request from Core, for its reply."
  @type from :: reference()

  @type request ::
          {:turn, turn_id :: String.t(), Helyx.Context.t()}
          | {:steer, turn_id :: String.t(), steer_id :: String.t(), text :: String.t()}
          | {:interrupt, turn_id :: String.t()}
          | {:tool_result, turn_id :: String.t(), call_id :: String.t(),
             {:ok | :error, String.t()}}
          | {:context, turn_id :: String.t(), {:ok, Helyx.Context.t()} | {:error, term()}}
          | :close
          | :idle_close

  @type action ::
          {:event, turn_id :: String.t(), stream_event()}
          | {:reply, from(), term()}
          | {:cancel_tool, turn_id :: String.t(), call_id :: String.t()}
          | {:need_context, turn_id :: String.t()}

  @doc "The byte limit of the text of a `{:notice, text}` stream event."
  @spec max_notice_bytes() :: pos_integer()
  def max_notice_bytes, do: @max_notice_bytes

  @doc """
  Finds the provider plugin whose id matches a model ref prefix. It reads the
  ids that Core checked at start and calls no plugin code.
  """
  @spec find(Helyx.Core.name(), String.t()) ::
          {:ok, module()} | {:error, {:unknown_provider, String.t()}}
  def find(core, id) do
    with :error <- Map.fetch(Helyx.Core.provider_ids(core), id),
         do: {:error, {:unknown_provider, id}}
  end

  @callback id() :: String.t()
  @callback release(
              handles :: [term()],
              mode :: :deliver | :cancel | :retry,
              deadline :: integer()
            ) ::
              [term()]

  @callback init(model :: String.t(), tools :: [Helyx.Tool.spec()], opts :: keyword()) ::
              {:ok, state :: term()} | {:error, term()}
  @callback request(request(), from(), state :: term()) :: {:ok, [action()], term()}
  @callback info(msg :: term(), state :: term()) ::
              {:ok, [action()], term()} | {:stop, reason :: term(), term()}

  @optional_callbacks release: 3
end
