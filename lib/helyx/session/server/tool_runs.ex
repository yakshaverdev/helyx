defmodule Helyx.Session.Server.ToolRuns do
  @moduledoc false
  # Runs the effects of the tool queue of the turn (`Helyx.Session.ToolQueue`,
  # in `Turn.tool_queue`) on the hands and the provider process. No answer is
  # awaited: a late reply is dropped by its ref, and a kill that fires in
  # the next turn fails that turn.

  import Helyx.Session.Server.State, only: [ask: 4]

  alias Helyx.Message.ToolCall
  alias Helyx.Session
  alias Helyx.Session.{Hands, Turn}
  alias Helyx.Session.Server.{Asks, State}
  alias Helyx.Session.Server.Flow.Up
  alias Helyx.Session.ToolQueue

  # A request of the current turn, of `bytes` encoded call bytes. An open
  # call id stops the provider process: `{:stop, reason}`.
  def request(
        %State{phase: %{turn: %Turn{} = turn}} = state,
        %ToolCall{} = call,
        bytes,
        rejection
      ) do
    # A call of an unknown tool runs alone; the hands answer it with an error.
    concurrent? = match?({_tool, true}, state.tools[call.name])

    case ToolQueue.request(turn.tool_queue, call, bytes, rejection, concurrent?) do
      {:ok, step} -> {:ok, apply_step(state, step)}
      :open -> {:stop, {:bad_action, {:event, turn.id, {:tool_request, call}}}}
    end
  end

  # A request of a turn that is not current: ended, dropped, or a turn
  # that the provider started and the session did not open. The provider
  # process `pid` that sent it gets `aborted`, after the interrupt or the
  # next turn when it came late.
  def late(state, pid, turn_id, id),
    do: send_result(state, pid, turn_id, id, Session.aborted_result())

  # The turn ended: each open request gets `aborted` now, before an
  # interrupt. No request goes to a provider process that is dying, and a
  # connecting one has none. The hands kill the running calls.
  def end_turn(%State{phase: %{provider: %Up{}}} = state, %Turn{} = turn),
    do: Enum.reduce(ToolQueue.end_turn(turn.tool_queue), state, &effect(&2, turn.id, &1))

  def end_turn(state, _turn), do: state

  # The hands' result of the running call `id`; an ask of the call ends
  # with it.
  def result(%State{phase: %{turn: %Turn{tool_queue: queue}}} = state, id, result),
    do: state |> Asks.call_end(id) |> apply_step(ToolQueue.result(queue, id, result))

  defp apply_step(%State{phase: %{turn: turn} = phase} = state, {queue, effects}) do
    state = %{state | phase: %{phase | turn: %{turn | tool_queue: queue}}}
    Enum.reduce(effects, state, &effect(&2, turn.id, &1))
  end

  # The context of the call (`Helyx.Tool.context/0`) has the model of the
  # turn, not of a later switch.
  defp effect(%State{phase: %{turn: %Turn{model: model}}} = state, turn_id, {:run, call}) do
    context = %{
      session_id: state.id,
      model: Helyx.ModelRef.to_string(model),
      provider_opts: state.init.provider_opts,
      model_context: state.plugins.model_context
    }

    :ok = Hands.run(state.hands, turn_id, call, context)
    state
  end

  defp effect(%State{phase: %{provider: %{pid: pid}}} = state, turn_id, {:result, id, result}),
    do: send_result(state, pid, turn_id, id, result)

  defp send_result(state, pid, turn_id, id, result) do
    ask(state, pid, {:tool_result, turn_id, id, result}, :reply)
    state
  end
end
