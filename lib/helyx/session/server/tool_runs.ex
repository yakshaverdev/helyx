defmodule Helyx.Session.Server.ToolRuns do
  @moduledoc false
  # Runs the effects of the tool queue of the turn (`Helyx.Session.ToolQueue`,
  # in `Turn.tool_queue`) on the hands and the provider process. No answer is
  # awaited: a late reply is dropped by its ref, and a kill that fires in
  # the next turn fails that turn.

  import Helyx.Session.Server.State, only: [ask: 4, tool_context: 2]

  alias Helyx.Message.ToolCall
  alias Helyx.Session
  alias Helyx.Session.{ApprovalChains, Hands, ToolQueue, Turn}
  alias Helyx.Session.Server.{Approvals, Asks, ProviderConn, State, UIBlocks}

  # A request of the current turn, of `bytes` encoded call bytes. An open
  # call id stops the provider process: `{:stop, reason}`; so does the id
  # of an open call that an approval request named as a call that the
  # provider runs itself, pending or answered (`docs/features/hooks.md`,
  # "The owner of a call id"), so one call id never has two chains in the
  # hands, and no open call is both, apart from the accepted hole of that
  # section; so does the id of a call with UI blocks of the provider
  # (`UIBlocks.request/2`).
  def request(%State{activity: %Turn{} = turn} = state, %ToolCall{} = call, bytes, rejection) do
    # A call of an unknown tool runs alone; the hands answer it with an error.
    concurrent? = match?({_tool, true}, state.tools[call.name])

    with false <- ApprovalChains.pending_call?(turn.approval_chains, call.id),
         false <- turn.owners[call.id] == :approval,
         {:ok, state} <- UIBlocks.request(state, call.id),
         {:ok, step} <- ToolQueue.request(turn.tool_queue, call, bytes, rejection, concurrent?) do
      {:ok, state |> Approvals.own(call.id, :tool) |> apply_step(step)}
    else
      stop when stop in [true, :shown, :open] ->
        {:stop, {:bad_action, {:event, turn.id, {:tool_request, call}}}}
    end
  end

  # A request of a turn that is not current: ended, dropped, or a turn
  # that the provider started and the session did not open. The provider
  # process `pid` that sent it gets `aborted`, after the interrupt or the
  # next turn when it came late.
  def late(state, pid, turn_id, id),
    do: send_result(state, pid, turn_id, id, Session.aborted_result())

  # The turn ended: each open request gets `aborted` now, before an
  # interrupt. No request goes to a process that is `:ending`, and a
  # `:starting` one has none. The hands kill the running calls.
  def end_turn(%State{conn: %ProviderConn{status: :ready}} = state, %Turn{} = turn),
    do: Enum.reduce(ToolQueue.end_turn(turn.tool_queue), state, &effect(&2, turn.id, &1))

  def end_turn(state, _turn), do: state

  # The hands' result of the running call `id`; an ask of the call ends
  # with it. A call that opened after its request gets its owner now. Its
  # UI blocks wait for the provider's result event (`UIBlocks.result/3`):
  # the provider gets the text alone.
  def result(%State{activity: %Turn{tool_queue: queue}} = state, id, result) do
    {result, blocks} = text_and_blocks(result)

    state
    |> UIBlocks.result(id, blocks)
    |> Asks.call_end(id)
    |> Approvals.own(id, :tool)
    |> apply_step(ToolQueue.result(queue, id, result))
  end

  defp text_and_blocks({status, text, blocks}), do: {{status, text}, blocks}
  defp text_and_blocks(result), do: {result, []}

  defp apply_step(%State{activity: turn} = state, {queue, effects}) do
    state = %{state | activity: %{turn | tool_queue: queue}}
    Enum.reduce(effects, state, &effect(&2, turn.id, &1))
  end

  defp effect(%State{activity: %Turn{model: model}} = state, turn_id, {:run, call}) do
    :ok = Hands.run(state.hands, turn_id, call, tool_context(state, model))
    state
  end

  defp effect(%State{conn: %ProviderConn{pid: pid}} = state, turn_id, {:result, id, result}),
    do: send_result(state, pid, turn_id, id, result)

  defp send_result(state, pid, turn_id, id, result) do
    ask(state, pid, {:tool_result, turn_id, id, result}, :reply)
    state
  end
end
