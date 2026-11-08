defmodule Helyx.Session.Server.Approvals do
  @moduledoc false
  # The approval requests of the provider for calls of its own tools
  # (ADR 0013 §4, `docs/features/hooks.md`, "Harness approvals"): the only
  # writer of `approval_chains` and `owners` in `Helyx.Session.Turn`. A
  # request names an open call of the turn that the provider runs itself;
  # the `before_tool` chain of that call decides it, in a Task of the hands,
  # and the session answers the provider with `{:approval, turn_id,
  # approval_id, decision}`.
  # Every request of a provider process that the session did not stop gets
  # exactly one answer: the provider waits for it.
  #
  # The owner of a call id (`docs/features/hooks.md`, "The owner of a call
  # id"): a call that runs or waits in the tool queue is a Helyx call, and
  # one whose approval chain runs or waits is the provider's own. Once Core
  # answered its request the session forgets both, so `owners` in
  # `Helyx.Session.Turn` keeps the owner of each open call that a request
  # named (`own/3`), and `drop/2` drops it at the call's result.

  import Helyx.Session.Server.State, only: [ask: 4, tool_context: 2]

  alias Helyx.Message
  alias Helyx.Session.{ApprovalChains, Hands, ToolQueue, Transcript, Turn}
  alias Helyx.Session.Server.{ProviderConn, State}

  @no_hook "no before_tool hook decides a call of the provider's own tools"
  @no_call "the approval request names no open call of the provider's own tools in the turn"
  @ended "the turn ended before the approval was decided"

  # A request of the current turn. A pending approval id stops the
  # provider process: `{:stop, reason}`. A request with no open call that
  # the provider runs itself, or with no `before_tool` hook, is denied at
  # once, with no entry (ADR 0013 §6).
  def request(%State{activity: %Turn{} = turn} = state, approval_id, call_id) do
    chains = turn.approval_chains
    call = open_call(state, call_id)

    cond do
      ApprovalChains.pending?(chains, approval_id) ->
        {:stop, {:bad_action, {:event, turn.id, {:approval, approval_id, call_id}}}}

      call == nil or ToolQueue.open?(turn.tool_queue, call_id) or turn.owners[call_id] == :tool ->
        {:ok, answer(state, turn.id, approval_id, {:deny, @no_call})}

      Map.get(Helyx.Core.hooks(state.core), :before_tool, []) == [] ->
        state = put_owner(state, call_id, :approval)
        {:ok, answer(state, turn.id, approval_id, {:deny, @no_hook})}

      true ->
        state = put_owner(state, call_id, :approval)
        {:ok, apply_step(state, ApprovalChains.request(chains, approval_id, call))}
    end
  end

  # The owner of the call `call_id` when it is an open call of the turn:
  # `:tool` for a Helyx tool request, `:approval` for an approval request.
  # The first owner stays: a request that names a call of the other owner
  # is denied or stops the provider before it gets here.
  def own(%State{activity: %Turn{owners: owners}} = state, call_id, owner) do
    if is_map_key(owners, call_id) or open_call(state, call_id) == nil,
      do: state,
      else: put_owner(state, call_id, owner)
  end

  # A result of a call `call_id` joined the transcript (`Records`). Its
  # owner goes when no open call keeps the id: two calls of one message
  # can share an id, and a result answers the first open one.
  def drop(%State{activity: %Turn{owners: owners} = turn} = state, call_id)
      when is_map_key(owners, call_id) do
    if open_call(state, call_id),
      do: state,
      else: %{state | activity: %{turn | owners: Map.delete(owners, call_id)}}
  end

  def drop(state, _call_id), do: state

  # A request of a turn that is not current, from the provider process
  # `pid`: denied, as a late tool request gets `aborted`.
  def late(state, pid, turn_id, approval_id) do
    ask(state, pid, {:approval, turn_id, approval_id, {:deny, @ended}}, :reply)
    state
  end

  # The decision of the running chain of `call_id`.
  def result(%State{activity: %Turn{approval_chains: chains}} = state, call_id, decision),
    do: apply_step(state, ApprovalChains.result(chains, call_id, decision))

  # The turn ended: each pending request is denied now, before an
  # interrupt. No request goes to a process that is `:ending`. The hands
  # kill the running chains.
  def end_turn(%State{conn: %ProviderConn{status: :ready}} = state, %Turn{} = turn) do
    Enum.reduce(ApprovalChains.pending(turn.approval_chains), state, fn approval_id, state ->
      answer(state, turn.id, approval_id, {:deny, @ended})
    end)
  end

  def end_turn(state, _turn), do: state

  # An open call of the turn: a call of the open assistant message, or of
  # the last closed message with no result yet (`Transcript.open_calls/1`).
  # The transcript is read only when the open message has no such call.
  defp open_call(%State{activity: %Turn{partial: partial}} = state, call_id) do
    Enum.find(partial || [], &match?(%Message.ToolCall{id: ^call_id}, &1)) ||
      Enum.find(Transcript.open_calls(state.transcript), &(&1.id == call_id))
  end

  # The caller found the open call `call_id`, and no other owner holds it.
  defp put_owner(%State{activity: %Turn{owners: owners} = turn} = state, call_id, owner),
    do: %{state | activity: %{turn | owners: Map.put(owners, call_id, owner)}}

  defp apply_step(%State{activity: turn} = state, {chains, effects}) do
    turn = %{turn | approval_chains: chains}
    Enum.reduce(effects, %{state | activity: turn}, &effect(&2, turn, &1))
  end

  defp effect(state, %Turn{model: model} = turn, {:run, _approval_id, call}) do
    context = tool_context(state, model)
    :ok = Hands.Approval.request(state.hands, turn.id, call, context, model.provider)
    state
  end

  defp effect(state, %Turn{id: turn_id}, {:answer, approval_id, decision}),
    do: answer(state, turn_id, approval_id, decision)

  defp answer(%State{conn: %ProviderConn{pid: pid}} = state, turn_id, approval_id, decision) do
    ask(state, pid, {:approval, turn_id, approval_id, decision}, :reply)
    state
  end
end
