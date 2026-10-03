defmodule Helyx.Session.Server.Tools do
  @moduledoc false
  # The Helyx tool requests of the turn, whose only owner is the session
  # (`docs/features/one-provider-path.md`, "Helyx tools inside the
  # program"). One runs on the hands (`Turn.tool`), at most @max_waiting
  # wait (`Turn.waiting`), and each gets exactly one `{:tool_result, ...}`
  # request: the result of its run, or an error from here. The turn end
  # answers the open ones (`Helyx.Session.Wait`).

  import Helyx.Session.Server.State, only: [ask: 4]

  alias Helyx.Message.ToolCall
  alias Helyx.Session.{Hands, Stream, Turn}
  alias Helyx.Session.Server.State

  # Bounds the fan-out of a model: one runs and these wait.
  @max_waiting 16
  @too_many "too many Helyx tool calls: one runs and #{@max_waiting} wait"

  # A request of the current turn. A call id that the turn used before is
  # outside the contract: `{:stop, reason}`, and the provider process stops.
  def request(%State{activity: %Turn{} = turn} = state, %ToolCall{id: id} = call, rejection) do
    if MapSet.member?(turn.ids, id),
      do: {:stop, {:bad_action, {:event, turn.id, {:tool_request, call}}}},
      else: {:ok, admit(put_in(state.activity.ids, MapSet.put(turn.ids, id)), call, rejection)}
  end

  defp admit(%State{activity: turn} = state, %ToolCall{id: id} = call, rejection) do
    cond do
      # An integer over the digit limit.
      rejection -> answer(state, id, {:error, Stream.not_run(rejection)})
      turn.tool == nil -> run(state, call)
      length(turn.waiting) >= @max_waiting -> answer(state, id, {:error, @too_many})
      true -> put_in(state.activity.waiting, turn.waiting ++ [call])
    end
  end

  # A request of a turn that is not current: ended, dropped, or a program
  # turn that the session did not open. The provider process `pid` that
  # sent it gets `aborted`, after the interrupt or the next turn when it
  # came late.
  def late(state, pid, turn_id, id) do
    ask(state, pid, {:tool_result, turn_id, id, {:error, "aborted"}}, :tool_result)
    state
  end

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

  # The answer is awaited, as a steer's is, so no turn starts while its kill
  # is armed. The late answer of `late/4` is the one exception: it is not
  # awaited, and its kill can fire during the next turn.
  defp answer(%State{activity: turn, conn: %{pid: pid}} = state, id, result) do
    from = ask(state, pid, {:tool_result, turn.id, id, result}, :tool_result)
    put_in(state.activity.results, [from | turn.results])
  end
end
