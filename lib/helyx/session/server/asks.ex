defmodule Helyx.Session.Server.Asks do
  @moduledoc false
  # The asks of the tool calls of the running turn
  # (docs/features/question-tool.md): the only writer of `asks` in
  # `Helyx.Session.Turn`. Each entry is the ask id, a new random id
  # (`Helyx.Session.Id`), so a late answer to an ask that ended never
  # reaches another ask; the caller of `Helyx.Tool.ask/1`, the Task of the
  # running call, which waits for its reply; and the ask that the `:ask`
  # event and the snapshot give. The end of the call ends its asks
  # (`call_end/2`), and the end of the turn ends them all (`finish/1`),
  # before its `turn_end`.

  import Helyx.Session.Server.Events, only: [emit: 3]

  alias Helyx.Session.Id
  alias Helyx.Session.Server.State
  alias Helyx.Session.Turn

  # An ask of a call that runs in the current turn, when a subscriber can
  # answer. The reply waits for the answer.
  def ask(
        %State{activity: %Turn{tool_queue: %{running: running}}} = state,
        from,
        call_id,
        tool,
        request
      )
      when is_map_key(running, call_id) do
    if Enum.any?(state.subscribers, fn {_pid, entry} -> elem(entry, 3) end) do
      ask = %{ask_id: Id.new(), call_id: call_id, tool: tool, request: request}
      {:noreply, state |> put_asks(asks(state) ++ [{ask.ask_id, from, ask}]) |> emit(:ask, ask)}
    else
      {:reply, {:error, :no_client}, state}
    end
  end

  def ask(state, _from, _call_id, _tool, _request), do: {:reply, {:error, :not_running}, state}

  # The first answer to an open ask goes to its caller; any other answer
  # finds no ask.
  def answer(state, ask_id, answer) do
    case List.keytake(asks(state), ask_id, 0) do
      {{^ask_id, from, _ask}, rest} ->
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
      Enum.split_with(asks(state), fn {_id, _from, ask} -> ask.call_id == call_id end)

    state |> put_asks(rest) |> end_asks(ended)
  end

  # The end of the turn: its calls get no answer, and the hands kill them.
  def finish(state) do
    open = asks(state)
    state |> put_asks([]) |> end_asks(open)
  end

  # The asks of a snapshot, oldest first.
  def snapshot(state), do: Enum.map(asks(state), &elem(&1, 2))

  defp end_asks(state, entries) do
    Enum.reduce(entries, state, fn {ask_id, _from, _ask}, state ->
      emit(state, :ask_end, %{ask_id: ask_id, outcome: :ended})
    end)
  end

  # Only a running turn has asks.
  defp asks(%State{activity: %Turn{asks: asks}}), do: asks
  defp asks(_state), do: []

  defp put_asks(%State{activity: %Turn{} = turn} = state, asks),
    do: %{state | activity: %{turn | asks: asks}}
end
