defmodule Helyx.Session.Server.Tools do
  @moduledoc false
  # The Helyx tool requests of the turn, whose only owner is the session
  # (`docs/features/one-provider-path.md`, "Helyx tools inside the
  # program"). One runs on the hands (`Turn.tool`), at most @max_waiting
  # wait (`Turn.waiting`), and each gets exactly one `{:tool_result, ...}`
  # request: the result of its run, or an error from here. The turn end
  # answers the open ones (`end_turn/2`). No answer is awaited: a late
  # reply is dropped by its ref, and a kill that fires in the next turn
  # fails that turn.

  import Helyx.Session.Server.State, only: [ask: 4]

  alias Helyx.Message.ToolCall
  alias Helyx.Session.{Hands, Stream, Turn}
  alias Helyx.Session.Server.{ProviderConn, State}

  # Bounds the fan-out of a model: one runs and these wait.
  @max_waiting 16
  @too_many "too many Helyx tool calls: one runs and #{@max_waiting} wait"

  # A request of the current turn. A call id that is open in the turn (it
  # runs or waits) is outside the contract: `{:stop, reason}`, and the
  # provider process stops. An answered id is not checked: no real provider
  # reuses an id (#369).
  def request(%State{activity: %Turn{} = turn} = state, %ToolCall{id: id} = call, rejection) do
    if turn.tool == id or Enum.any?(turn.waiting, &(&1.id == id)),
      do: {:stop, {:bad_action, {:event, turn.id, {:tool_request, call}}}},
      else: {:ok, admit(state, call, rejection)}
  end

  defp admit(%State{activity: turn} = state, %ToolCall{id: id} = call, rejection) do
    cond do
      # An integer over the digit limit, or arguments that are not a JSON object.
      rejection -> answer(state, id, {:error, Stream.not_run(rejection)})
      turn.tool == nil -> run(state, call)
      length(turn.waiting) >= @max_waiting -> answer(state, id, {:error, @too_many})
      true -> put_in(state.activity.waiting, turn.waiting ++ [call])
    end
  end

  # A request of a turn that is not current: ended, dropped, or a turn
  # that the provider started and the session did not open. The provider process `pid` that
  # sent it gets `aborted`, after the interrupt or the next turn when it
  # came late.
  def late(state, pid, turn_id, id), do: send_result(state, pid, turn_id, id, {:error, "aborted"})

  # The turn ended: each open request gets `aborted` now, before an
  # interrupt, while the provider process lives. The hands kill the
  # running call.
  def end_turn(%State{conn: %ProviderConn{pid: pid}} = state, %Turn{} = turn) do
    ids = List.wrap(turn.tool) ++ Enum.map(turn.waiting, & &1.id)
    Enum.reduce(ids, state, &send_result(&2, pid, turn.id, &1, {:error, "aborted"}))
  end

  def end_turn(state, _turn), do: state

  # The hands' result of the running call: a killed call gets `aborted`.
  # Then the next waiting call runs.
  def result(%State{activity: %Turn{tool: id} = turn} = state, result) do
    result = if turn.killed?, do: {:error, "aborted"}, else: result
    state = answer(%{state | activity: %{turn | tool: nil, killed?: false}}, id, result)

    case state.activity.waiting do
      [] -> state
      [call | waiting] -> run(put_in(state.activity.waiting, waiting), call)
    end
  end

  # The provider withdrew a request (#198): the running call is killed and
  # gets `aborted` at the hands' result; a waiting one gets `aborted` now.
  # Any other id has nothing open.
  def cancel(%State{activity: %Turn{tool: id} = turn} = state, id) do
    Hands.kill(state.hands, turn.id, id)
    put_in(state.activity.killed?, true)
  end

  def cancel(%State{activity: %Turn{waiting: waiting}} = state, id) do
    case Enum.split_with(waiting, &(&1.id == id)) do
      {[], _} -> state
      {_, waiting} -> answer(put_in(state.activity.waiting, waiting), id, {:error, "aborted"})
    end
  end

  defp run(%State{activity: turn} = state, call) do
    :ok = Hands.run(state.hands, turn.id, call)
    put_in(state.activity.tool, call.id)
  end

  defp answer(%State{activity: turn, conn: %{pid: pid}} = state, id, result),
    do: send_result(state, pid, turn.id, id, result)

  defp send_result(state, pid, turn_id, id, result) do
    ask(state, pid, {:tool_result, turn_id, id, result}, :tool_result)
    state
  end
end
