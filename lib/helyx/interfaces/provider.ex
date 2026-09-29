defmodule Helyx.Provider do
  @moduledoc """
  Produces assistant messages for a session.

  A provider plugin implements this behaviour. `id/0` is the prefix in a model
  ref such as `fake/echo`. Core calls `id/0` once, at start: an `id/0` that
  raises, throws, exits, or returns a value that is not a binary, or an id
  that two providers share, stops Core from starting. `stream/3` returns an
  enumerable of stream events for one provider call:

    * `{:text_delta, binary}`: a delta of assistant text
    * `{:thinking_delta, binary}`: a delta of thinking text
    * `{:tool_call, Helyx.Message.ToolCall.t()}`: one complete tool call
    * `{:rejected_tool_call, Helyx.Message.ToolCall.t(), reason}`: one tool
      call that the session must not run, such as a call whose arguments
      the provider could not decode. The call goes into the assistant
      message in stream order, with the arguments the provider could
      decode, or `%{}`. Its result is `{:error, "tool call not run: " <>
      reason}`. `reason` is valid UTF-8 of at most 1,024 bytes; it must not
      hold the raw arguments. Only a local turn accepts this event
    * `{:done, %{stop_reason: stop_reason, usage: map}}`: the call finished
    * `{:error, term}`: the call failed

  A provider with an external turn (`turn/0` returns `:external`, ADR 0002)
  runs the whole turn and its own tools inside one call. Four behaviours
  follow from that flag:

    * A steer aborts the turn and starts a new turn with the steer text.
    * Tool calls arrive with their results. The session records them and
      does not run them.
    * The provider keeps its own conversation state. The session resumes
      it by id.
    * The stream runs under the session's hands.

  Its stream can also carry:

    * `{:message_end, stop_reason, usage}`: the assistant message so far is
      complete; its tool calls ran inside the provider. Send it once per
      message, only after content (a delta or a tool call) that no earlier
      `message_end` closed, and only when every call of the messages before
      it has its result: the session gives every call that is still open an
      `aborted` result at each `message_end` and drops a later result. At
      the end of the call, a provider sends every `message_end` that it did
      not send yet, and the session aborts the calls with no result
    * `{:tool_result, call_id, {:ok | :error, binary}}`: the result of a
      tool call of a completed message. The provider cuts the text to the
      tool result limits before it sends the event, as a tool does; the
      session does not cut it. A text over 65,536 bytes fails the turn with
      `{:tool_result_too_large, bytes, 65_536}`
    * `{:harness_session, id, cut}`: the call started a fresh harness
      session with this id; `cut` is the number of transcript messages the
      provider left out of what it sent to it

  Consecutive deltas of one kind form one block. A tool call arrives whole;
  a provider that streams tool call arguments assembles them first. There is
  no image event: providers do not produce image blocks. A malformed event
  fails the turn with `{:bad_stream_event, event}`.

  `stop_reason` is the closed set that `Helyx.Message` owns
  (`Helyx.Message.stop_reasons/0`): a provider normalizes whatever its wire
  protocol reports into it.

  The session calls `stream/3` with `opts` carrying `:core`, `:session_id`,
  `:turn_id`, and `:cwd`, so a provider can scope state and label its calls.
  A provider with an external turn also gets `:harness_session_id`: the id
  of the harness session to resume, or nil for a fresh one. The session
  passes the id of the provider's last `harness_session` only when the last
  assistant message of the transcript came from this provider, so a lost
  id or a switch from another provider gives nil.

  The stream of an external turn runs as a Task of the session's hands
  (`Helyx.Session.Hands`), so it can hold the OS resources of its program with
  `Helyx.Tool.hold/1` and must then implement `release/3`, with the
  contract of `c:Helyx.Tool.release/3`. An abort returns only when the
  release has returned (ADR 0004).

  The session consumes the enumerable in a Task and builds the assistant
  message from the events. Consumption stops at the first `done` or `error`.
  A stream that ends without one fails the turn with `:stream_ended`. The
  turn's outcome is the Task's outcome: a stream that raises, including in
  its cleanup after `done`, fails the turn with `{:task_exit, reason}`.

  ## A connected provider

  A provider with an external turn that also exports `harness_init/3` is
  connected (ADR 0007, `docs/features/long-lived-harness.md`): its program
  lives for the session, not for the turn, and the session does not call
  `stream/3`. The three callbacks run in one harness process per session, a
  Task of the hands, so `Helyx.Tool.hold/1` works in them and the provider
  implements `release/3`:

    * `harness_init/3` starts the program. `tools` are the checked tool
      specs of session start; `opts` carry `:core`, `:session_id`, `:cwd`,
      and `:harness_session_id` as for `stream/3`.
    * `harness_request/3` gets a request from Core with its `from`. The
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
      `:idle_close` comes after the session was idle for 30 minutes with
      the program: it takes `:ok` after the program exited, as `:close`,
      or `:busy` when the program still runs work of its own, such as a
      background task. With `:busy` the program stays, and the session
      asks again after the next idle time.
    * `harness_info/2` gets every other message of the harness process: the
      port data, a monitor, a timer.

  Each callback returns actions: `{:event, turn_id, event}` with a stream
  event of an external turn, `{:reply, from, value}`, and `{:cancel_tool,
  turn_id, call_id}`. Each event passes the same check as a stream event. A
  turn ends at its `done` or `error` event. A malformed event, a reply of
  the wrong shape or for no open request, an error reply to `{:turn, ...}`
  or `{:interrupt, ...}`, and a bad return stop the harness process: its
  port closes, and the watchdog stops the program. At most 8 requests are
  open at once: Core answers one more with `{:error, :busy}` and does not
  give it to the provider.

  Every request has a deadline: a kill of the harness process armed with
  the request at the OTP timer server (`:timer.kill_after/2`), which Core
  cancels when the provider replies. A connect has 30,000 ms from the
  start to the end of `harness_init/3`. A callback that blocks is killed at
  the bound, however busy the session is. The turn fails with
  `:harness_timeout`. A crash fails it with `{:task_exit, reason}`, and a
  stop with its reason. The next turn starts a new harness process.
  """

  use Helyx.Interface, mode: :multi, required: true

  @type stop_reason :: Helyx.Message.stop_reason()

  @type stream_event ::
          {:text_delta, String.t()}
          | {:thinking_delta, String.t()}
          | {:tool_call, Helyx.Message.ToolCall.t()}
          | {:rejected_tool_call, Helyx.Message.ToolCall.t(), String.t()}
          | {:done, %{stop_reason: stop_reason(), usage: map()}}
          | {:error, term()}
          | {:message_end, stop_reason(), map()}
          | {:tool_result, String.t(), {:ok | :error, String.t()}}
          | {:harness_session, String.t(), non_neg_integer()}
          | {:user_message, String.t(), String.t()}

  @typedoc "The ref of a request from Core, for its reply."
  @type from :: reference()

  @type request ::
          {:turn, turn_id :: String.t(), Helyx.Context.t()}
          | {:steer, turn_id :: String.t(), steer_id :: String.t(), text :: String.t()}
          | {:interrupt, turn_id :: String.t()}
          | :close
          | :idle_close

  @type action ::
          {:event, turn_id :: String.t(), stream_event()}
          | {:reply, from(), term()}
          | {:cancel_tool, turn_id :: String.t(), call_id :: String.t()}

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

  @doc """
  The turn of a provider plugin: `provider.turn()` when it is exported, else
  `:local`. A `turn/0` that raises, throws, exits, or returns another value
  than `:local` or `:external` is an error. An `:external` provider that
  exports `harness_init/3` gives `:connected`. It is plugin code, so the
  session calls this in the caller of a start, a resume, or a switch, and
  keeps the result.
  """
  @spec turn(module()) :: {:ok, :local | :external | :connected} | :error
  def turn(provider) do
    turn = if function_exported?(provider, :turn, 0), do: provider.turn(), else: :local

    case turn do
      :local -> {:ok, :local}
      :external -> {:ok, connected(provider)}
      _other -> :error
    end
  catch
    _class, _reason -> :error
  end

  # An external provider with `harness_init/3` is connected (ADR 0007).
  # Core loaded the module at its start, so the export check calls no
  # plugin code.
  defp connected(provider) do
    if function_exported?(provider, :harness_init, 3), do: :connected, else: :external
  end

  @callback id() :: String.t()
  @callback turn() :: :local | :external
  @callback release(
              handles :: [term()],
              mode :: :deliver | :cancel | :retry,
              deadline :: integer()
            ) ::
              [term()]
  @callback stream(model :: String.t(), context :: Helyx.Context.t(), opts :: keyword()) ::
              {:ok, Enumerable.t()} | {:error, term()}

  @callback harness_init(model :: String.t(), tools :: [Helyx.Tool.spec()], opts :: keyword()) ::
              {:ok, state :: term()} | {:error, term()}
  @callback harness_request(request(), from(), state :: term()) :: {:ok, [action()], term()}
  @callback harness_info(msg :: term(), state :: term()) ::
              {:ok, [action()], term()} | {:stop, reason :: term(), term()}

  @optional_callbacks turn: 0,
                      release: 3,
                      harness_init: 3,
                      harness_request: 3,
                      harness_info: 2
end
