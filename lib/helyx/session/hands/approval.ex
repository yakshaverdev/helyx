defmodule Helyx.Session.Hands.Approval do
  @moduledoc false
  # The `before_tool` chain of an approval request of a provider for a
  # call of its own tools (ADR 0013 §4, docs/features/hooks.md, "Harness
  # approvals"), in `Helyx.Session.Hands`. One chain Task runs it under the
  # turn id, with the id `{:approval, call_id}`; it runs no plugin code,
  # holds nothing, has no ask record, and asks the hands for a hook Task
  # for each hook (`Helyx.Session.Hands.Hooks`), as the call Task of a tool
  # call does. Its hook Tasks have the id `{:hook, call_id}`. The hands
  # deliver its end as any Task's: its hook Task that still runs is killed
  # and released first (`Hooks.orphans/3`), and the decision goes to the
  # session as `{:approval_result, turn_id, call_id, :allow | {:deny,
  # reason}}` (`Helyx.Session.Hands.Outcome`). A cancel of the turn kills
  # it with its hook Task.

  alias Helyx.Message.ToolCall
  alias Helyx.Session.Hands
  alias Helyx.Session.Hands.Chain

  @doc false
  # Asks the hands to run the chain of the provider `provider` for its own
  # call `call`, with the context of a call (`Hands.run/4`). A cast.
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
      Hands.spawn_task(state, turn_id, {:approval, call.id}, nil, fn ->
        Process.put(:helyx_call, context)
        Chain.approve(call, cwd, turn_id, hooks, provider)
      end)

    state
  end
end
