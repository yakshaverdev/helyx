defmodule Helyx.Provider do
  @moduledoc """
  Produces assistant messages for a session. This is the contract in short
  form; every rule of it is in `docs/features/one-provider-path.md`, "The
  provider protocol", and the reasons are in ADR 0002 and ADR 0007.

  A provider plugin implements this behaviour. `id/0` is the prefix in a model
  ref such as `fake/echo`. Core calls `id/0` once, at start: an `id/0` that
  raises, throws, exits, or returns a value that is not a binary, or an id
  that two providers share, stops Core from starting. A provider that does
  not export `init/3`, `request/3`, and `info/2` stops it too.

  Every provider runs in one provider process per session. An API provider,
  which calls a model and lets the session run the tools, implements
  `stream/3` of `Helyx.Provider.Loop` and adds `use Helyx.Provider.Loop`,
  which defines the three callbacks. A harness provider drives an agent
  program that runs the whole turn and its own tools
  (`docs/features/long-lived-harness.md`).

  ## Callbacks

  The callbacks run in the provider process, a Task of the hands, so
  `Helyx.Tool.hold/1` works in them, and a provider that holds a handle
  implements `release/3`.

    * `init/3` starts the provider. `opts` carry `:core`, `:session_id`,
      `:cwd`, and `:resume_id`, the id of a program session to resume or nil.
    * `request/3` gets a `t:request/0` from Core with its `from`. The
      provider replies now or later with the action `{:reply, from, value}`.
    * `info/2` gets every other message of the provider process.

  `init/3` returns `{:ok, state}` or `{:error, reason}`. `request/3` and
  `info/2` return `{:ok, actions, state}`, and `info/2` can also return
  `{:stop, reason, state}`. An action is `{:event, turn_id, event}`,
  `{:reply, from, value}`, `{:cancel_tool, call_id}` (withdraws a
  tool request), or `{:need_context, turn_id}` (asks for a fresh context of
  the running turn). A malformed event or action, a reply of the wrong shape
  or for no open request, and a bad return stop the provider process.

  ## Replies

    * `{:turn, ...}`, `{:interrupt, ...}`: `:ok` or `{:error, reason}`. An
      error reply stops the provider process.
    * `{:steer, ...}`: `:ok` when the program has the steer, `:rejected`
      when it is confirmed that the program did not get it, and
      `{:error, reason}` when it is not known.
    * `{:tool_result, ...}`, `{:context, ...}`: `:ok` when written. A
      tool result can arrive after the interrupt or the next turn of its
      turn. Each call still gets exactly one result.
    * `:close`: `:ok` after the program exited.
    * `:idle_close`: `:ok` after the program exited, or `:busy` when the
      program still runs work of its own.

  ## Events

  A provider sends these events. A turn ends at its `done` or `error`
  event, or when the provider process ends. `done` closes the last
  assistant message.

    * `{:text_delta, binary}`: a delta of assistant text
    * `{:thinking_delta, binary}`: a delta of thinking text
    * `{:tool_call, Helyx.Message.ToolCall.t()}`: one complete tool call.
      `arguments` is a map, or the raw argument text (a binary) when it
      does not decode to a JSON object. Such a call joins the transcript
      with `%{}` and never runs: its result is `tool call not run: the
      arguments are not a valid JSON object`. Any other `arguments` fails
      the turn
    * `{:done, %{stop_reason: stop_reason, usage: map}}`: the call finished.
      `stop_reason` is one of `Helyx.Message.stop_reasons/0`
    * `{:error, term}`: the call failed
    * `{:message_end, stop_reason, usage}`: the assistant message so far is
      complete. The session gives an `aborted` result to every call of the
      earlier messages that has no result yet; the calls of this message
      stay open for their `tool_result` events until the next
      `message_end` or a taken steer
    * `{:tool_result, call_id, {:ok | :error, binary}}`: the result of a
      tool call of a completed message. The provider cuts the text to the
      tool result limits; a text over `@max_tool_result_bytes`
      (`Helyx.Session.Stream`) fails the turn
    * `{:resume, id, cut}`: the program started a fresh program session
    * `{:user_message, steer_id}`: the program took a steer. The
      session closes the open assistant message and gives `aborted` to
      every call that is still open
    * `{:tool_request, call_id, name, arguments}`: run the Helyx tool
      `name`. `arguments` follows the rule of a `tool_call`
    * `:turn_start`: the program started a turn by itself

  `init/3` and every request from the session have a deadline. When the
  reply has not come by it, Core kills the provider process, and a running
  turn fails with `:provider_timeout`, or with the release error of a
  handle that the provider held.
  """

  use Helyx.Interface, mode: :multi, required: true

  @type stop_reason :: Helyx.Message.stop_reason()

  @type stream_event ::
          {:text_delta, String.t()}
          | {:thinking_delta, String.t()}
          | {:tool_call, Helyx.Message.ToolCall.t()}
          | {:done, %{stop_reason: stop_reason(), usage: map()}}
          | {:error, term()}
          | {:message_end, stop_reason(), map()}
          | {:tool_result, String.t(), {:ok | :error, String.t()}}
          | {:resume, String.t(), non_neg_integer()}
          | {:user_message, String.t()}
          | {:tool_request, call_id :: String.t(), name :: String.t(),
             arguments :: map() | String.t()}
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
          | {:cancel_tool, call_id :: String.t()}
          | {:need_context, turn_id :: String.t()}

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
