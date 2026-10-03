defmodule Helyx.Provider.Loop do
  # The reason of a rejected call: transcript text in the result
  # "tool call not run: <reason>".
  @max_reason_bytes 1_024

  @moduledoc """
  The provider callbacks of an API provider, over one model call at a time
  (`docs/features/one-provider-path.md`, "`Helyx.Provider.Loop`").

  An API provider implements `stream/3` and adds `use Helyx.Provider.Loop`,
  which declares `Helyx.Provider` and defines its `init/3`, `request/3`,
  and `info/2`.
  The helper runs each model call in a model Task, so the provider process
  stays free for a steer or an interrupt. It holds no handles and sends no
  `resume` or `turn_start` event.

  `stream/3` returns an enumerable of stream events for one model call:

    * `{:text_delta, binary}`, `{:thinking_delta, binary}`: a delta of text
      or of thinking text
    * `{:tool_call, Helyx.Message.ToolCall.t()}`: one complete tool call
    * `{:rejected_tool_call, Helyx.Message.ToolCall.t(), reason}`: a call
      that must not run, such as one whose arguments did not decode. It
      goes into the assistant message with the arguments that decoded, or
      `%{}`, and its result is `{:error, "tool call not run: " <> reason}`.
      `reason` is valid UTF-8 of at most #{@max_reason_bytes} bytes and
      never holds the raw arguments
    * `{:notice, text}`: a notice for the user (`Helyx.Provider`)
    * `{:done, %{stop_reason: stop_reason, usage: map}}`: the call finished
    * `{:error, term}`: the call failed

  `opts` carry `:core`, `:session_id`, `:turn_id`, and `:cwd`. The model
  Task consumes the enumerable up to the first `done` or `error`. Any other
  event, a `rejected_tool_call` whose reason breaks its rule, or an
  enumerable that halts by itself on another value, ends the provider
  process with `{:bad_stream_event, event}`; Core checks the rest as it
  checks every provider event. A stream faster than the provider process
  ends at over 10,000 waiting messages with `{:error, {:provider_behind,
  length, 10_000}}`.

  A turn: the helper replies `:ok` to `{:turn, ...}` and calls the model
  with the context. A done with calls sends `message_end`, then a
  `tool_request` for every valid call of the message at once, in call
  order; the session runs them. A rejected call has its error result from
  the start. The results join the transcript as `tool_result` events in call
  order, each when every call before it has its result. When every call
  has its result, the held steers go out as `user_message` events, then
  `{:need_context, turn_id}`, and the next model call gets the fresh
  context. A done with no calls ends the turn, unless a steer is
  held: then the steers go out and the model is called again in the same
  turn. A stream error, a stream that ends with no terminal (`:stream_ended`),
  a model Task that raises, throws, or exits (`{:task_exit, reason}`), and
  a context error end the turn; the provider process stays. An exit
  signal that kills the model Task, such as one from a process linked to
  it, ends the provider process too, through the link (L4).

  A steer of the live turn is held for the next model call; after the
  terminal it gets `:rejected`. A steer held while a context is built goes
  out when the context comes, with a new context request, before any
  model call. An interrupt kills the model Task and waits
  for its death before its `:ok`. A close or an idle close ends the process.
  A model call has no deadline: the user aborts it.
  """

  alias Helyx.Message
  alias Helyx.Session.Stream

  @callback stream(model :: String.t(), context :: Helyx.Context.t(), opts :: keyword()) ::
              {:ok, Enumerable.t()} | {:error, term()}

  # `turn` is the live turn id or nil; `task` the model Task; `calls` the
  # calls of the message with no result in the transcript yet, in call
  # order, each `{request_id, call, result}` with the result nil until it
  # comes; `steers` the held steers.
  @enforce_keys [:provider, :model, :opts]
  defstruct [:provider, :model, :opts, :turn, :task, content?: false, calls: [], steers: []]

  @doc false
  defmacro __using__(_opts) do
    quote do
      @behaviour Helyx.Provider
      @behaviour Helyx.Provider.Loop

      @impl Helyx.Provider
      def init(model, _tools, opts), do: {:ok, Helyx.Provider.Loop.new(__MODULE__, model, opts)}

      @impl Helyx.Provider
      defdelegate request(request, from, state), to: Helyx.Provider.Loop

      @impl Helyx.Provider
      defdelegate info(message, state), to: Helyx.Provider.Loop
    end
  end

  @doc "The state of a provider process of `provider`, from the `init/3` arguments."
  @spec new(module(), String.t(), keyword()) :: %__MODULE__{}
  def new(provider, model, opts),
    do: %__MODULE__{
      provider: provider,
      model: model,
      opts: Keyword.take(opts, ~w(core session_id cwd)a)
    }

  @doc "The `request/3` callback of `Helyx.Provider`."
  @spec request(Helyx.Provider.request(), Helyx.Provider.from(), %__MODULE__{}) ::
          {:ok, [Helyx.Provider.action()], %__MODULE__{}}
  def request({:turn, turn_id, context}, from, state) do
    state = %{end_turn(stop_task(state)) | turn: turn_id}
    {:ok, [{:reply, from, :ok}], model_call(state, context)}
  end

  def request({:steer, turn_id, steer_id, text}, from, %{turn: turn_id} = state),
    do: {:ok, [{:reply, from, :ok}], %{state | steers: state.steers ++ [{steer_id, text}]}}

  def request({:steer, _, _, _}, from, state), do: {:ok, [{:reply, from, :rejected}], state}

  # The `:ok` goes out only after the model Task is dead (L3).
  def request({:interrupt, turn_id}, from, %{turn: turn_id} = state),
    do: {:ok, [{:reply, from, :ok}], end_turn(stop_task(state))}

  # The session sends one result for each request. The `aborted` results
  # that it sends at an interrupt end the calls too; the events after them
  # are of a turn that the session ended, and it drops them.
  def request({:tool_result, turn_id, id, result}, from, %{turn: turn_id} = state) do
    calls =
      Enum.map(state.calls, fn
        {^id, call, nil} -> {id, call, result}
        entry -> entry
      end)

    send_ready([{:reply, from, :ok}], %{state | calls: calls})
  end

  def request({:context, turn_id, result}, from, %{turn: turn_id} = state) do
    case result do
      # A steer held while the context was built goes out first, and the
      # model gets a context with it (C2).
      {:ok, _context} when state.steers != [] ->
        request_context([{:reply, from, :ok}], state)

      {:ok, context} ->
        {:ok, [{:reply, from, :ok}], model_call(state, context)}

      {:error, _} = error ->
        {:ok, [{:reply, from, :ok}, {:event, turn_id, error}], end_turn(state)}
    end
  end

  # A close, an idle close, and a request of a turn that is not live.
  def request(_request, from, state), do: {:ok, [{:reply, from, :ok}], state}

  @doc "The `info/2` callback of `Helyx.Provider`."
  @spec info(term(), %__MODULE__{}) :: {:ok, [Helyx.Provider.action()], %__MODULE__{}}
  def info({__MODULE__, pid, event}, %{task: %Task{pid: pid}} = state), do: event(event, state)

  def info({ref, result}, %{task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    terminal(result, %{state | task: nil})
  end

  # A signal that ends the Task with `:normal` passes the catch of `run/5`
  # and the link.
  def info({:DOWN, ref, :process, _, reason}, %{task: %Task{ref: ref}} = state),
    do: terminal({:failed, reason}, %{state | task: nil})

  # A message of an old model Task, or any other message.
  def info(_message, state), do: {:ok, [], state}

  defp event({:tool_call, %Message.ToolCall{} = call}, state), do: call(call, nil, state)

  defp event({:rejected_tool_call, %Message.ToolCall{} = call, reason} = event, state) do
    if is_binary(reason) and byte_size(reason) <= @max_reason_bytes and String.valid?(reason),
      do: call(call, {:error, Stream.not_run(reason)}, state),
      else: bad(event)
  end

  # Core checks the payload.
  defp event({tag, _} = event, state)
       when tag in [:text_delta, :thinking_delta, :tool_call, :notice],
       do:
         {:ok, [{:event, state.turn, event}],
          %{state | content?: state.content? or tag != :notice}}

  defp event(event, _state), do: bad(event)

  # The session rejects a request id that its turn used before, and a
  # model can repeat a call id, so each call gets a request id of its own.
  defp call(call, result, state) do
    id = Integer.to_string(System.unique_integer([:positive]))
    state = %{state | calls: state.calls ++ [{id, call, result}], content?: true}
    {:ok, [{:event, state.turn, {:tool_call, call}}], state}
  end

  # The process ends as it ends at a malformed event of the provider.
  defp bad(event), do: exit({:shutdown, {:bad_stream_event, event}})

  defp terminal({:done, %{stop_reason: stop, usage: usage}} = done, state) do
    message_end = {:event, state.turn, {:message_end, stop, usage}}

    # A call sets `content?`.
    cond do
      state.calls == [] and state.steers == [] -> finish(done, state)
      state.content? -> dispatch([message_end], state)
      true -> dispatch([], state)
    end
  end

  defp terminal({:failed, reason}, state), do: finish({:error, {:task_exit, reason}}, state)
  defp terminal(:stream_ended, state), do: finish({:error, :stream_ended}, state)
  # An error, or a malformed done that Core rejects.
  defp terminal({tag, _} = terminal, state) when tag in [:done, :error],
    do: finish(terminal, state)

  # The result of an enumerable that halts by itself on another value.
  defp terminal(other, _state), do: bad(other)

  defp finish(terminal, state), do: {:ok, [{:event, state.turn, terminal}], end_turn(state)}

  # Every valid call of the message goes to the session at once, in call
  # order.
  defp dispatch(actions, state) do
    requests =
      for {id, call, nil} <- state.calls,
          do: {:event, state.turn, {:tool_request, id, call.name, call.arguments}}

    send_ready(actions ++ requests, state)
  end

  # The results that every call before them has, in call order. With no
  # call left, the held steers and the context request (C2).
  defp send_ready(actions, state) do
    {done, open} = Enum.split_while(state.calls, fn {_, _, result} -> result != nil end)

    results =
      for {_, call, result} <- done, do: {:event, state.turn, {:tool_result, call.id, result}}

    state = %{state | calls: open}

    if open == [],
      do: request_context(actions ++ results, state),
      else: {:ok, actions ++ results, state}
  end

  defp request_context(actions, state) do
    steers = for {id, text} <- state.steers, do: {:event, state.turn, {:user_message, id, text}}
    {:ok, actions ++ steers ++ [{:need_context, state.turn}], %{state | steers: []}}
  end

  defp end_turn(state), do: %{state | turn: nil, calls: [], steers: []}

  # `Task.shutdown/2` unlinks, kills, waits for the `:DOWN`, and flushes the
  # reply. Events that the Task sent before stay in the mailbox; `info/2`
  # drops them by the pid.
  defp stop_task(%{task: nil} = state), do: state

  defp stop_task(%{task: task} = state) do
    Task.shutdown(task, :brutal_kill)
    %{state | task: nil}
  end

  # `Task.async/1` links and monitors the model Task. The provider process
  # never ends with `:normal`, so the link ends the Task with it (L1, L2).
  defp model_call(state, context) do
    %{provider: provider, model: model} = state
    opts = [turn_id: state.turn] ++ state.opts
    parent = self()
    task = Task.async(fn -> run(provider, model, context, opts, parent) end)
    %{state | task: task, calls: [], content?: false}
  end

  # A raise, a throw, or an exit of the model call is its result, so the
  # provider process stays for the next turn (L2).
  defp run(provider, model, context, opts, parent) do
    case provider.stream(model, context, opts) do
      {:ok, stream} -> consume(stream, parent)
      {:error, _} = error -> error
    end
  catch
    :exit, reason ->
      {:failed, reason}

    :throw, value ->
      {:failed, {{:nocatch, value}, __STACKTRACE__}}

    :error, error ->
      {:failed, {Exception.normalize(:error, error, __STACKTRACE__), __STACKTRACE__}}
  end

  # Each event goes to the provider process with the mailbox check of a
  # session send, so a stream faster than that process stops at the bound,
  # and an interrupt waits behind at most that many messages.
  defp consume(stream, parent) do
    Enum.reduce_while(stream, :stream_ended, fn
      {tag, _} = terminal, _acc when tag in [:done, :error] ->
        {:halt, terminal}

      event, acc ->
        case Stream.send_checked(parent, {__MODULE__, self(), event}, :provider_behind) do
          :ok -> {:cont, acc}
          error -> {:halt, error}
        end
    end)
  end
end
