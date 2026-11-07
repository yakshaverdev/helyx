defmodule Helyx.Session.Hands.Settle do
  @moduledoc false
  # The `before_settle` chain of `Helyx.Session.Hands`
  # (docs/features/before-settle.md). One chain Task runs it under the
  # turn id of the ended turn, with the id `{:settle, ref}` of the
  # session's request; it runs no plugin code, and asks the hands for a
  # hook Task for each hook (`Helyx.Session.Hands.Hooks`), as the call Task
  # of a tool call does. Its hook Tasks have the id `{:hook, {:settle,
  # ref}}`. The hands deliver its end as any Task's: its hook Task that
  # still runs is killed and released first (`Hooks.orphans/3`), and the
  # answer goes to the session (`Helyx.Session.Hands.Outcome`). A cancel of
  # the turn kills it with its hook Task.

  alias Helyx.Session.Hands
  alias Helyx.Session.Hands.Chain

  @doc false
  # Asks the hands to run the chain with `input`; the answer goes to the
  # session as `{:settle_answer, ref, :settle | {:continue, module,
  # text}}`. A cast, as `Hands.run/4`. `context` is the one of a call:
  # the hands add the Core and the tool names, with no tool and no call id.
  @spec request(pid(), String.t(), Helyx.Hook.settle(), map()) :: reference()
  def request(hands, turn_id, input, context) do
    ref = make_ref()
    GenServer.cast(hands, {:settle, ref, turn_id, input, context})
    ref
  end

  @doc false
  def start(state, {:settle, ref, turn_id, input, context}) do
    hooks = Map.fetch!(state.hooks, :before_settle)
    extra = %{core: state.core, tools: Map.keys(state.tools), tool: nil, call_id: nil}
    context = Map.merge(context, extra)

    {_task, state} =
      Hands.spawn_task(state, turn_id, {:settle, ref}, nil, fn ->
        Process.put(:helyx_call, context)
        Chain.settle(hooks, input)
      end)

    state
  end
end
