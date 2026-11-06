defmodule Helyx.Session.Server.Asks do
  @moduledoc false
  # The asks of the tool calls of the running turn
  # (docs/features/question-tool.md): the only writer of `asks` in
  # `Helyx.Session.Turn`. Each entry is the ask id, a new random id
  # (`Helyx.Session.Id`), so a late answer to an ask that ended never
  # reaches another ask; the caller, which waits for its reply; the ask
  # that the `:ask` event and the snapshot give; and the pid of the Task
  # that asked. The session takes an ask only from a Task in `askers`, of
  # the kind that its call names: the call Task of the call for
  # `Helyx.Tool.ask/1`, a hook Task of it for `Helyx.Hook.ask/1`
  # (docs/features/hooks.md). The hands send that record before the Task
  # runs (`asker/4`). The `:DOWN` of the Task drops its record and ends
  # its ask (`down/3`), the end of the call ends its asks (`call_end/2`),
  # and the end of the turn ends them all (`finish/1`), before its
  # `turn_end`.

  import Helyx.Session.Server.Events, only: [emit: 3]

  alias Helyx.Session.Id
  alias Helyx.Session.Server.State
  alias Helyx.Session.Turn

  # The record of a call or hook Task of the current turn, with a
  # monitor: at most one for each live Task of the turn. A Task of a turn
  # that is no longer current gets none: its call does not run, so it
  # cannot ask.
  def asker(%State{activity: %Turn{id: turn_id} = turn} = state, turn_id, pid, kind) do
    askers = Map.put(turn.askers, pid, {Process.monitor(pid), kind})
    %{state | activity: %{turn | askers: askers}}
  end

  def asker(state, _turn_id, _pid, _kind), do: state

  # A call Task that went on in the background is no call of the turn:
  # its record goes, as the hands drop it from the turn.
  def started(%State{activity: %Turn{askers: askers} = turn} = state, call_id) do
    {gone, kept} = Map.split_with(askers, fn {_pid, {_ref, kind}} -> kind == {:tool, call_id} end)
    Enum.each(gone, fn {_pid, {ref, _kind}} -> Process.demonitor(ref, [:flush]) end)
    %{state | activity: %{turn | askers: kept}}
  end

  def started(state, _call_id), do: state

  # An ask of a Task whose record has the kind, for a call that runs in
  # the current turn, when a subscriber can answer. The reply waits for
  # the answer.
  def ask(
        %State{activity: %Turn{tool_queue: %{running: running}, askers: askers}} = state,
        {pid, _tag} = from,
        {_kind, call_id} = kind,
        tool,
        request
      )
      when is_map_key(running, call_id) and
             elem(:erlang.map_get(pid, askers), 1) == kind do
    if Enum.any?(state.subscribers, fn {_pid, entry} -> elem(entry, 3) end) do
      ask = %{ask_id: Id.new(), call_id: call_id, tool: tool, request: request}
      state |> put_asks(asks(state) ++ [{ask.ask_id, from, ask, pid}]) |> emit(:ask, ask)
    else
      reply(state, from, {:error, :no_client})
    end
  end

  def ask(state, from, _kind, _tool, _request), do: reply(state, from, {:error, :not_running})

  defp reply(state, from, reply) do
    GenServer.reply(from, reply)
    state
  end

  # A call or hook Task of the turn ended: its record goes, and its ask
  # ends, whatever the cause. `:error` for a monitor of no record.
  def down(%State{activity: %Turn{askers: %{} = askers} = turn} = state, monitor, pid)
      when :erlang.map_get(pid, askers) |> elem(0) == monitor do
    state = %{state | activity: %{turn | askers: Map.delete(askers, pid)}}
    {ended, rest} = Enum.split_with(asks(state), &(elem(&1, 3) == pid))
    {:ok, state |> put_asks(rest) |> end_asks(ended)}
  end

  def down(_state, _monitor, _pid), do: :error

  # The first answer to an open ask goes to its caller; any other answer
  # finds no ask.
  def answer(state, ask_id, answer) do
    case List.keytake(asks(state), ask_id, 0) do
      {{^ask_id, from, _ask, _pid}, rest} ->
        GenServer.reply(from, {:ok, answer})
        {:ok, state |> put_asks(rest) |> emit(:ask_end, %{ask_id: ask_id, outcome: :answered})}

      nil ->
        {{:error, :not_waiting}, state}
    end
  end

  # A call whose result came while it asked, such as a Task that died, has
  # no caller left for an answer.
  def call_end(state, call_id) do
    {ended, rest} =
      Enum.split_with(asks(state), fn {_id, _from, ask, _pid} -> ask.call_id == call_id end)

    state |> put_asks(rest) |> end_asks(ended)
  end

  # The end of the turn: its calls get no answer, and the hands kill them.
  # The monitors of its Tasks go with it.
  def finish(state) do
    open = asks(state)

    Enum.each(askers(state), fn {_pid, {monitor, _kind}} ->
      Process.demonitor(monitor, [:flush])
    end)

    state |> put_asks([]) |> end_asks(open)
  end

  # The asks of a snapshot, oldest first.
  def snapshot(state), do: Enum.map(asks(state), &elem(&1, 2))

  defp end_asks(state, entries) do
    Enum.reduce(entries, state, fn {ask_id, _from, _ask, _pid}, state ->
      emit(state, :ask_end, %{ask_id: ask_id, outcome: :ended})
    end)
  end

  # Only a running turn has asks.
  defp asks(%State{activity: %Turn{asks: asks}}), do: asks
  defp asks(_state), do: []

  defp askers(%State{activity: %Turn{askers: askers}}), do: askers
  defp askers(_state), do: %{}

  defp put_asks(%State{activity: %Turn{} = turn} = state, asks),
    do: %{state | activity: %{turn | asks: asks}}
end
