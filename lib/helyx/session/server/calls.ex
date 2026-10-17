defmodule Helyx.Session.Server.Calls do
  @moduledoc false
  # The calls of the client API (`Helyx.Session`) in the session process. A
  # call at or past its deadline does not act and gets no reply
  # (docs/features/session-lifecycle.md, "Late calls").

  alias Helyx.{Message, ModelRef}
  alias Helyx.Session.History
  alias Helyx.Session.Server.{Compaction, Events, Records, State, TurnLoop}

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

  # The entry and the snapshot in one message, so every later event reaches
  # the caller. A repeated subscribe keeps the entry and its monitor.
  def handle({:subscribe, pid, tail}, _from, %State{} = state) do
    state = Events.subscribe(state, pid)
    {:reply, Events.snapshot(state, tail), state}
  end

  # A page reads the transcript only (session-snapshot.md, "History").
  def handle({:history, instance_id, _before, _limit}, _from, %State{instance_id: id} = state)
      when instance_id != id,
      do: {:reply, {:error, :instance_changed}, state}

  def handle({:history, _instance_id, before, limit}, _from, %State{} = state),
    do: {:reply, History.page(state.transcript, before, limit), state}

  def handle({:set_model, %ModelRef{} = ref, provider}, _from, %State{} = state),
    do: {:reply, :ok, TurnLoop.settle(Records.set_model(state, ref, provider))}

  # The abort replies through `GenServer.reply/2` (`TurnLoop.abort/2`).
  def handle(:abort, from, %State{} = state), do: {:noreply, TurnLoop.abort(state, from)}
end
