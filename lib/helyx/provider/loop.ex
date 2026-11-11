defmodule Helyx.Provider.Loop do
  @moduledoc """
  The provider callbacks of a model provider, over one model call at a time
  (`docs/features/one-provider-path.md`, "`Helyx.Provider.Loop`").

  A model provider implements `stream/3` and adds `use Helyx.Provider.Loop`,
  which declares `Helyx.Provider` and defines its `init/3`, `request/3`,
  and `info/2`.
  The helper runs each model call in a model Task, so the provider process
  stays free for a steer or an interrupt. It holds no handles and sends no
  `resume` or `turn_start` event.

  `stream/3` returns an enumerable of stream events for one model call:

    * `{:text_delta, binary}`, `{:thinking_delta, binary}`: a delta of text
      or of thinking text
    * `{:tool_call, Helyx.Message.ToolCall.t()}`: one complete tool call,
      with the arguments of `Helyx.Provider`
    * `{:done, %{stop_reason: stop_reason, usage: Helyx.Usage.t() | nil}}`:
      the call finished
    * `{:error, term}`: the call failed

  `opts` carry `:core`, `:session_id`, `:turn_id`, `:cwd`, and
  `:max_output_tokens`, the session's limit or nil: a provider that applies
  it defines `max_output_tokens?/0` (`docs/features/output-limit.md`). The
  model Task consumes the enumerable up to the first `done` or `error`. Any
  other event, or a call whose id repeats in the message, ends the provider
  process with `{:bad_stream_event, event}`; Core checks the rest as it
  checks every provider event. A stream faster than the provider process
  ends at over 10,000 waiting messages with `{:error, {:provider_behind,
  length, 10_000}}`.

  A turn: the helper replies `:ok` to `{:turn, ...}` and calls the model
  with the context. A done with calls sends `message_end`, then a
  `tool_request` for every call of the message at once, in call order; the
  session runs or rejects them. A done with calls and the stop reason
  `:max_tokens` sends no `tool_request`: each call gets the error result
  "tool call not run: the reply was cut at the token limit". The results
  join the transcript as `tool_result` events in call order, each when
  every call before it has its result. When every call has its result, the
  held steers go out as `user_message` events, then `{:need_context,
  turn_id}`, and the next model call gets the fresh context. A done with
  no calls ends the turn, unless a steer is held: then the steers go out
  and the model is called again in the same turn; the usage of that call
  goes into the usage of the next message of the provider process
  (`docs/features/usage-and-limits.md`, "Per provider"). A call that an
  abort or an error ends reports no usage, so the next usage of the
  provider process has `cost: nil`. A stream error, a stream that ends
  with no terminal (`:stream_ended`), a model Task that raises, throws, or
  exits (`{:task_exit, reason}`), and a context error end the turn; the
  provider process stays. An exit signal that kills the model Task, such
  as one from a process linked to it, ends the provider process too,
  through the link (L4).

  A steer of the live turn is held for the next model call; after the
  terminal it gets `:rejected`. A steer held while a context is built goes
  out when the context comes, with a new context request, before any
  model call. An interrupt kills the model Task and waits
  for its death before its `:ok`. A close or an idle close ends the process.
  A compact request gets `:unsupported`.
  A model call has no deadline: the user aborts it.
  """

  alias Helyx.Message
  alias Helyx.Session.Stream

  @callback stream(model :: String.t(), context :: Helyx.Context.t(), opts :: keyword()) ::
              {:ok, Enumerable.t()} | {:error, term()}

  # `phase` is the state of one model call at a time: `:idle` with no
  # turn; `{:calling, turn, task, content?, calls}` with the model Task in
  # flight, `content?` set by a text, a thinking text, or a call; `{:results,
  # turn, calls}` while the calls wait for their results; and `{:context,
  # turn}` while the session builds a fresh context. `calls` are the calls
  # of the message with no result in the transcript yet, in call order, each
  # `{call, result}` with the result nil until it comes; the call id is the
  # request id. `steers` the ids of the held steers of the live turn.
  # `usage` is the usage of a call that sent no `message_end`, or nil; it
  # outlives the turn. `lost?` is the flag: a call since the last usage
  # ended with no usage, so the next usage has no cost.
  @enforce_keys [:provider, :model, :opts]
  defstruct [
    :provider,
    :model,
    :opts,
    :usage,
    phase: :idle,
    lost?: false,
    steers: []
  ]

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

  @doc "Whether `module` is a model provider of this helper."
  @spec loop?(module()) :: boolean()
  def loop?(module),
    do:
      __MODULE__ in List.flatten(Keyword.get_values(module.module_info(:attributes), :behaviour))

  @doc "The state of a provider process of `provider`, from the `init/3` arguments."
  @spec new(module(), String.t(), keyword()) :: %__MODULE__{}
  def new(provider, model, opts),
    do: %__MODULE__{
      provider: provider,
      model: model,
      opts: Keyword.take(opts, ~w(core session_id cwd max_output_tokens)a)
    }

  @doc "The `request/3` callback of `Helyx.Provider`."
  @spec request(Helyx.Provider.request(), Helyx.Provider.from(), %__MODULE__{}) ::
          {:ok, [Helyx.Provider.action()], %__MODULE__{}}
  # A turn starts in `:idle`, or replaces a turn that the session ended
  # while it waited for a context (e.g. `:context_timeout`).
  def request({:turn, turn_id, context}, from, %{phase: :idle} = state),
    do: {:ok, [{:reply, from, :ok}], model_call(%{state | steers: []}, context, turn_id)}

  def request({:turn, turn_id, context}, from, %{phase: {:context, _}} = state),
    do: {:ok, [{:reply, from, :ok}], model_call(%{state | steers: []}, context, turn_id)}

  # A steer of the live turn is held for the next model call.
  def request({:steer, turn_id, steer_id, _text}, from, state) do
    if live?(state.phase, turn_id),
      do: {:ok, [{:reply, from, :ok}], %{state | steers: state.steers ++ [steer_id]}},
      else: {:ok, [{:reply, from, :rejected}], state}
  end

  # The `:ok` goes out only after the model Task is dead (L3).
  def request({:interrupt, turn_id}, from, state) do
    if live?(state.phase, turn_id),
      do: {:ok, [{:reply, from, :ok}], stop(state)},
      else: {:ok, [{:reply, from, :ok}], state}
  end

  # The session sends one result for each request. The `aborted` results
  # that it sends at an interrupt end the calls too; the events after them
  # are of a turn that the session ended, and it drops them.
  def request(
        {:tool_result, turn_id, id, result},
        from,
        %{phase: {:results, turn_id, calls}} = state
      ) do
    calls =
      Enum.map(calls, fn
        {%Message.ToolCall{id: ^id} = call, nil} -> {call, result}
        entry -> entry
      end)

    send_ready([{:reply, from, :ok}], turn_id, calls, state)
  end

  def request({:context, turn_id, result}, from, %{phase: {:context, turn_id}} = state) do
    case result do
      # A steer held while the context was built goes out first, and the
      # model gets a context with it (C2).
      {:ok, _context} when state.steers != [] ->
        request_context([{:reply, from, :ok}], turn_id, state)

      {:ok, context} ->
        {:ok, [{:reply, from, :ok}], model_call(state, context, turn_id)}

      {:error, _} = error ->
        {:ok, [{:reply, from, :ok}, {:event, turn_id, error}], end_turn(state)}
    end
  end

  # The context of a model provider is the session's transcript: it keeps
  # no history to compact.
  def request({:compact, _turn_id, _instructions}, from, state),
    do: {:ok, [{:reply, from, :unsupported}], state}

  # An answer that is still in flight when the session ends the turn: the
  # `aborted` results of an interrupt, and the context answer.
  def request({:tool_result, _turn_id, _id, _result}, from, %{phase: :idle} = state),
    do: {:ok, [{:reply, from, :ok}], state}

  def request({:context, _turn_id, _result}, from, %{phase: :idle} = state),
    do: {:ok, [{:reply, from, :ok}], state}

  # A close, an idle close, and an approval that a model provider never
  # asks for.
  def request({:approval, _turn_id, _approval_id, _answer}, from, state),
    do: {:ok, [{:reply, from, :ok}], state}

  def request(request, from, state) when request in [:close, :idle_close],
    do: {:ok, [{:reply, from, :ok}], state}

  defp live?({:calling, turn, _, _, _}, turn), do: true
  defp live?({:results, turn, _}, turn), do: true
  defp live?({:context, turn}, turn), do: true
  defp live?(_phase, _turn), do: false

  @doc "The `info/2` callback of `Helyx.Provider`."
  @spec info(term(), %__MODULE__{}) :: {:ok, [Helyx.Provider.action()], %__MODULE__{}}
  def info({__MODULE__, pid, event}, %{phase: {:calling, _, %Task{pid: pid}, _, _}} = state),
    do: event(event, state)

  def info({ref, result}, %{phase: {:calling, _, %Task{ref: ref}, _, _}} = state) do
    Process.demonitor(ref, [:flush])
    terminal(result, state)
  end

  # A signal that ends the Task with `:normal` passes the catch of `run/5`
  # and the link.
  def info(
        {:DOWN, ref, :process, _, reason},
        %{phase: {:calling, _, %Task{ref: ref}, _, _}} = state
      ),
      do: terminal({:failed, reason}, state)

  # A message of an old model Task, or any other message.
  def info(_message, state), do: {:ok, [], state}

  defp event({:tool_call, %Message.ToolCall{} = call}, state), do: call(call, state)

  # Core checks the payload. A `{:tool_call, term}` that is not a
  # `%Message.ToolCall{}` is a contract break, as the moduledoc says.
  defp event(
         {tag, _} = event,
         %{phase: {:calling, turn, task, _, calls}} = state
       )
       when tag in [:text_delta, :thinking_delta],
       do: {:ok, [{:event, turn, event}], %{state | phase: {:calling, turn, task, true, calls}}}

  defp event(event, _state), do: bad(event)

  # A call id names its result, so a call id that repeats in one message
  # breaks the contract, whether the session answered the first call or not.
  # The reason names the call with `%{}`, as the errors of Core do.
  defp call(call, %{phase: {:calling, turn, task, _, calls}} = state) do
    if Enum.any?(calls, fn {%{id: id}, _} -> id == call.id end),
      do: bad({:tool_call, %{call | arguments: %{}}})

    phase = {:calling, turn, task, true, calls ++ [{call, nil}]}
    {:ok, [{:event, turn, {:tool_call, call}}], %{state | phase: phase}}
  end

  # The process ends as it ends at a malformed event of the provider.
  defp bad(event), do: exit({:shutdown, {:bad_stream_event, event}})

  # A usage that is not valid goes to Core in the done, which Core rejects.
  defp terminal({:done, %{stop_reason: _, usage: usage} = fields} = done, state) do
    if usage == nil or Helyx.Usage.valid?(usage),
      do: called(fields, state),
      else: finish(done, state)
  end

  defp terminal({:failed, reason}, state), do: terminal({:error, {:task_exit, reason}}, state)
  defp terminal(:stream_ended, state), do: terminal({:error, :stream_ended}, state)
  defp terminal({:error, _} = error, state), do: finish(error, %{state | lost?: true})
  # A malformed done, which Core rejects.
  defp terminal({:done, _} = done, state), do: finish(done, state)

  # A call that finished with a valid usage. The kept usage joins it.
  defp called(
         %{stop_reason: stop, usage: usage} = fields,
         %{phase: {:calling, turn, _, content?, calls}} = state
       ) do
    usage = state.usage |> join(usage) |> lose(state.lost?)
    done = {:done, %{fields | usage: usage}}
    message_end = {:event, turn, {:message_end, stop, usage}}
    state = %{state | usage: nil, lost?: state.lost? and usage == nil}

    # A call sets `content?`. No call of a reply cut at the token limit
    # runs (#494).
    cond do
      calls == [] and state.steers == [] ->
        finish(done, state)

      stop == :max_tokens and calls != [] ->
        cut = {:error, Stream.not_run("the reply was cut at the token limit")}
        calls = for {call, _} <- calls, do: {call, cut}
        send_ready([message_end], turn, calls, state)

      content? ->
        dispatch([message_end], turn, calls, state)

      true ->
        dispatch([], turn, calls, %{state | usage: usage})
    end
  end

  defp join(nil, usage), do: usage
  defp join(kept, nil), do: kept
  defp join(kept, usage), do: Helyx.Usage.add(kept, usage)

  defp lose(%Helyx.Usage{} = usage, true), do: Helyx.Usage.unpriced(usage)
  defp lose(usage, _lost?), do: usage

  defp finish(terminal, %{phase: {:calling, turn, _, _, _}} = state),
    do: {:ok, [{:event, turn, terminal}], end_turn(state)}

  # Every call of the message goes to the session at once, in call order.
  defp dispatch(actions, turn, calls, state) do
    requests =
      for {call, _} <- calls,
          do: {:event, turn, {:tool_request, call.id, call.name, call.arguments}}

    send_ready(actions ++ requests, turn, calls, state)
  end

  # The results that every call before them has, in call order. With no
  # call left, the held steers and the context request (C2).
  defp send_ready(actions, turn, calls, state) do
    {done, open} = Enum.split_while(calls, fn {_, result} -> result != nil end)

    results = for {call, result} <- done, do: {:event, turn, {:tool_result, call.id, result}}
    state = %{state | phase: {:results, turn, open}}

    if open == [],
      do: request_context(actions ++ results, turn, state),
      else: {:ok, actions ++ results, state}
  end

  defp request_context(actions, turn, state) do
    steers = for id <- state.steers, do: {:event, turn, {:user_message, id}}

    {:ok, actions ++ steers ++ [{:need_context, turn}],
     %{state | phase: {:context, turn}, steers: []}}
  end

  defp end_turn(state), do: %{state | phase: :idle, steers: []}

  # The turn ends while its model Task may run (an interrupt, a new turn):
  # `Task.shutdown/2` unlinks, kills, waits for the `:DOWN`, and flushes the
  # reply. Events that the Task sent before stay in the mailbox; `info/2`
  # drops them by the pid. The killed call reports no usage: the flag.
  defp stop(%{phase: {:calling, _, task, _, _}} = state) do
    Task.shutdown(task, :brutal_kill)
    %{state | phase: :idle, steers: [], lost?: true}
  end

  defp stop(state), do: end_turn(state)

  # `Task.async/1` links and monitors the model Task. The provider process
  # never ends with `:normal`, so the link ends the Task with it (L1, L2).
  defp model_call(state, context, turn) do
    %{provider: provider, model: model} = state
    opts = [turn_id: turn] ++ state.opts
    parent = self()
    task = Task.async(fn -> run(provider, model, context, opts, parent) end)
    %{state | phase: {:calling, turn, task, false, []}}
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
