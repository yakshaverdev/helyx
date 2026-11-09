defmodule Helyx.Session.Server.Calls do
  @moduledoc false
  # The calls of the client API (`Helyx.Session`) in the session process. A
  # call at or past its deadline does not act and gets no reply
  # (docs/features/session-lifecycle.md, "Late calls").

  alias Helyx.{Message, ModelRef}
  alias Helyx.Session.{History, Input}
  alias Helyx.Session.Server.{Asks, Compaction, Events, Records, Sources, State}
  alias Helyx.Session.Server.{TurnLoop, UIBlocks}

  require Logger

  @spec handle(term(), GenServer.from(), State.t()) ::
          {:reply, term(), State.t()} | {:noreply, State.t()}
  def handle({:until, deadline, request}, from, state) do
    if System.monotonic_time(:millisecond) < deadline do
      handle(request, from, state)
    else
      # The op name only, never the text of the call.
      Logger.info("late session call dropped: #{elem(request, 0)}")
      {:noreply, state}
    end
  end

  # The admission of a client message by phase (`TurnLoop.admit/3`).
  def handle({op, text, origin}, _from, %State{} = state)
      when op in [:prompt, :steer, :follow_up] do
    {reply, state} = TurnLoop.admit(op, Message.user(text, origin), state)
    {:reply, reply, state}
  end

  def handle({:compact, text}, _from, %State{} = state) do
    {reply, state} = Compaction.admit(text, state)
    {:reply, reply, state}
  end

  # The entry and the snapshot or the replay in one message, so every later
  # event reaches the caller. A repeated subscribe keeps the entry's monitor.
  def handle({:subscribe, pid, ref, opts}, _from, %State{} = state) do
    {reply, state} = Events.subscribe(state, pid, ref, opts)
    {:reply, reply, state}
  end

  # The caller waits for the answer (`Asks.ask/5`).
  def handle({:ask, kind, call_id, tool, request}, from, %State{} = state),
    do: {:noreply, Asks.ask(state, from, {kind, call_id}, tool, request)}

  # A UI block of a running call (`Helyx.Tool.show/2`).
  def handle({:ui_block, call_id, key, block}, {pid, _tag}, %State{} = state),
    do: UIBlocks.tool_block(state, pid, call_id, key, block)

  def handle({:answer, ask_id, answer}, _from, %State{} = state) do
    {reply, state} = Asks.answer(state, ask_id, answer)
    {:reply, reply, state}
  end

  # A page reads the transcript only (session-snapshot.md, "History").
  def handle({:history, instance_id, _before, _limit}, _from, %State{instance_id: id} = state)
      when instance_id != id,
      do: {:reply, {:error, :instance_changed}, state}

  def handle({:history, _instance_id, before, limit}, _from, %State{} = state),
    do: {:reply, History.page(state.transcript, before, limit), state}

  # A provider that cannot apply the session's limit leaves the model as
  # it was (docs/features/output-limit.md, decision 4). The caller read
  # whether the provider applies a limit (`Input.limit_supported?/2`).
  def handle({:set_model, %ModelRef{} = ref, provider, supported?}, _from, %State{} = state) do
    case Input.limit(supported? or state.init.max_output_tokens == nil, ref.provider) do
      :ok -> {:reply, :ok, TurnLoop.settle(Records.set_model(state, ref, provider))}
      error -> {:reply, error, state}
    end
  end

  # `Helyx.Tool.announce/1`, `put_tools/2`, and `notice/1`, from a source process.
  def handle({:announce, _groups} = request, from, %State{} = state),
    do: source_call(request, from, state)

  def handle({:put_tools, _group, _value} = request, from, %State{} = state),
    do: source_call(request, from, state)

  def handle({:notice, _text} = request, from, %State{} = state),
    do: source_call(request, from, state)

  # `Helyx.Tool.deferred/2` and `activate/1`, from a tool call.
  def handle({:deferred, version, wait_ms}, from, %State{} = state),
    do: Sources.deferred(state, from, version, wait_ms)

  def handle({:activate, names}, {pid, _tag}, %State{} = state) do
    {activated, state} = Sources.activate(state, call_turn(state, pid), names)
    {:reply, activated, state}
  end

  # `Helyx.Tool.transcript/0`, from a Task of the hands.
  def handle(:transcript, _from, %State{} = state),
    do: {:reply, Helyx.Summary.kept(state.transcript, state.summary), state}

  # The attach of a start (`Server.Open`): a start with other provider
  # options gets no session, because the session runs with its own.
  def handle({:attach, opts}, _from, %State{init: %{provider_opts: opts}} = state),
    do: {:reply, :ok, state}

  def handle({:attach, _provider_opts}, _from, %State{} = state),
    do: {:reply, {:error, :provider_opts_differ}, state}

  # The entry of `Helyx.Sessions.list_live/1`.
  def handle(:live, _from, %State{} = state) do
    live = %Helyx.Sessions.Live{
      id: state.id,
      instance_id: state.instance_id,
      cwd: state.cwd,
      model: ModelRef.to_string(state.model),
      status: if(state.activity == :idle, do: :idle, else: :running)
    }

    {:reply, live, state}
  end

  # The abort replies through `GenServer.reply/2` (`TurnLoop.abort/2`).
  def handle(:abort, from, %State{} = state), do: {:noreply, TurnLoop.abort(state, from)}

  # The stop of `Helyx.Sessions.stop/1`: `terminate/2` replies.
  def handle(:stop, from, %State{} = state), do: {:stop, :normal, %{state | stopper: from}}

  defp source_call(request, {pid, _tag}, state) do
    case Sources.call(state, pid, request) do
      {:ok, reply, state} -> {:reply, reply, state}
      :error -> {:reply, :error, state}
    end
  end

  # The turn of a caller that is a running call or hook Task of it (the
  # askers of `Asks`), else nil: a background run left its turn.
  defp call_turn(%State{activity: %Helyx.Session.Turn{id: id, askers: askers}}, pid)
       when is_map_key(askers, pid),
       do: id

  defp call_turn(_state, _pid), do: nil
end
