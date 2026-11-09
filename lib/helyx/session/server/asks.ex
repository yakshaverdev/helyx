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
  # (docs/features/hooks.md). The hands send that record when they start
  # the Task, and the session lets the Task run once it handled it
  # (`asker/4`). The `:DOWN` of the Task, or the answer of a hook Task
  # from the hands, drops its record and ends its ask (`down/3`,
  # `ended/2`), the end of the call ends its asks (`call_end/2`), the
  # result of the call in the transcript ends the records of its Tasks and
  # their asks (`result_joined/2`), and the end of the turn ends them all
  # (`finish/1`), before its `turn_end`. So a Task is recorded only while
  # its call has no result: a UI block of a call (`Helyx.Session.Server.UIBlocks`)
  # and an ask, an input UI block, never come after the call's result
  # (docs/features/ui-blocks.md).

  import Helyx.Session.Server.Events, only: [emit: 3]

  alias Helyx.Session.{Id, Transcript, Turn}
  alias Helyx.Session.Server.State

  # The record of a call or hook Task of the current turn, with a
  # monitor: at most one for each live Task of the turn. A Task of a turn
  # that is no longer current gets none: its call does not run, so it
  # cannot ask. Then the Task runs: the session sends its go after it
  # handled the record. A Task of a call that the transcript answered
  # already, a request that names an answered call (#369), gets none either.
  def asker(
        %State{phase: %{turn: %Turn{id: turn_id} = turn}} = state,
        turn_id,
        pid,
        {_, call_id} = kind
      ) do
    if Transcript.answered?(state.transcript, turn.partial, call_id) do
      go(state, pid)
    else
      askers = Map.put(turn.askers, pid, {Process.monitor(pid), kind})
      go(put_turn(state, askers: askers), pid)
    end
  end

  def asker(state, _turn_id, pid, _kind), do: go(state, pid)

  defp go(state, pid) do
    send(pid, :helyx_go)
    state
  end

  # A call Task `pid` that went on in the background is no call of the
  # turn: its record goes, as the hands take it out of the turn's cancel
  # (a revoke still reaches it). Then the run
  # goes on: it waits in `Helyx.Tool.started/1` for this go, so an ask of
  # the run comes after the drop.
  def started(%State{phase: %{turn: %Turn{}}} = state, call_id, pid),
    do: go(drop_askers(state, fn {_pid, {_ref, kind}} -> kind == {:tool, call_id} end), pid)

  def started(state, _call_id, pid), do: go(state, pid)

  # Whether `pid` is a Task of the turn whose record has `kind`, for a call
  # that runs, or for a hook Task whose approval chain runs: the caller
  # check of an ask, and of a UI block of a call
  # (`Helyx.Session.Server.UIBlocks`, which asks for `{:tool, call_id}`).
  defguard caller?(turn, pid, kind)
           when (is_map_key(turn.tool_queue.running, elem(kind, 1)) or
                   (elem(kind, 0) == :hook and
                      is_map_key(turn.approval_chains.running, elem(kind, 1)))) and
                  elem(:erlang.map_get(pid, turn.askers), 1) == kind

  # An ask of a Task whose record has the kind, for a call that runs in
  # the tool queue of the current turn, or for a hook Task, a call whose
  # approval chain runs in its set of approval chains, when a subscriber
  # can answer. The reply waits for the answer.
  def ask(
        %State{phase: %{turn: %Turn{} = turn}} = state,
        {pid, _tag} = from,
        {_kind_name, call_id} = kind,
        tool,
        request
      )
      when caller?(turn, pid, kind) do
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
  def down(%State{phase: %{turn: %Turn{askers: %{} = askers}}} = state, monitor, pid)
      when :erlang.map_get(pid, askers) |> elem(0) == monitor,
      do: {:ok, ended(state, pid)}

  def down(_state, _monitor, _pid), do: :error

  # The Task `pid` ended: at its `:DOWN`, or for a hook Task at its answer
  # from the hands, which comes before the record of the next hook of the
  # chain. Its record and its monitor go, and its open ask ends. A Task
  # with no record changes nothing.
  def ended(%State{phase: %{turn: %Turn{askers: askers}}} = state, pid)
      when is_map_key(askers, pid) do
    {{monitor, _kind}, askers} = Map.pop!(askers, pid)
    Process.demonitor(monitor, [:flush])
    state = put_turn(state, askers: askers)
    {ended, rest} = Enum.split_with(asks(state), &(elem(&1, 3) == pid))
    state |> put_asks(rest) |> end_asks(ended)
  end

  def ended(state, _pid), do: state

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

  # The result of the call joined the transcript: the records of its call
  # and hook Tasks end with their monitors, and each open ask of the call
  # ends; its caller, a Task that can still run, as after an `aborted`
  # result, gets `{:error, :not_running}`.
  def result_joined(%State{phase: %{turn: %Turn{}}} = state, call_id) do
    for {_id, from, %{call_id: ^call_id}, _pid} <- asks(state),
        do: GenServer.reply(from, {:error, :not_running})

    state |> drop_askers(&of_call?(&1, call_id)) |> call_end(call_id)
  end

  def result_joined(state, _call_id), do: state

  defp of_call?({_pid, {_ref, {_kind, id}}}, call_id), do: id == call_id

  # The records that `drop?` picks go, with their monitors.
  defp drop_askers(%State{phase: %{turn: %Turn{askers: askers}}} = state, drop?) do
    {gone, kept} = Map.split_with(askers, drop?)
    Enum.each(gone, fn {_pid, {monitor, _kind}} -> Process.demonitor(monitor, [:flush]) end)
    put_turn(state, askers: kept)
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
  defp asks(%State{phase: %{turn: %Turn{asks: asks}}}), do: asks
  defp asks(_state), do: []

  defp askers(%State{phase: %{turn: %Turn{askers: askers}}}), do: askers
  defp askers(_state), do: %{}

  defp put_asks(state, asks), do: put_turn(state, asks: asks)

  defp put_turn(%State{phase: %{turn: %Turn{} = turn} = phase} = state, fields),
    do: %{state | phase: %{phase | turn: struct!(turn, fields)}}
end
