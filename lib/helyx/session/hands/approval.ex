defmodule Helyx.Session.Hands.Approval do
  @moduledoc false
  # The `before_tool` chain of an approval request of a provider for a call of
  # its own tools (ADR 0013 §4, docs/features/hooks.md). One chain Task runs it
  # under the turn id, with the id `{:approval, call_id}`; it runs no plugin
  # code, holds nothing, and asks the hands for a hook Task for each hook. Its
  # decision goes to the session as `{:approval_result, turn_id, call_id,
  # :allow | {:deny, reason}}` (`Helyx.Session.Hands.Outcome`).

  alias Helyx.Message.ToolCall
  alias Helyx.Session.Hands
  alias Helyx.Session.Hands.Chain

  @doc false
  # Runs the chain of the provider `provider` for its own call `call`, with the
  # context of a call (`Hands.run/4`). A cast.
  @spec request(pid(), String.t(), ToolCall.t(), map(), String.t()) :: :ok
  def request(hands, turn_id, %ToolCall{} = call, context, provider),
    do: GenServer.cast(hands, {:approve, turn_id, call, context, provider})

  @doc false
  def start(state, {:approve, turn_id, call, context, provider}) do
    cwd = state.cwd
    hooks = Map.get(state.hooks, :before_tool, [])
    extra = %{core: state.core, tools: Map.keys(state.tools), tool: call.name, call_id: call.id}
    context = Map.merge(context, extra)

    {_task, state} =
      Hands.spawn_task(state, {:approval, call.id}, turn_id, nil, fn ->
        Process.put(:helyx_call, context)
        Chain.approve(call, cwd, turn_id, hooks, provider)
      end)

    state
  end
end
