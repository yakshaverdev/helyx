defmodule Helyx.Session.Hands.Settle do
  @moduledoc false
  # The `before_settle` chain of `Helyx.Session.Hands`
  # (docs/features/before-settle.md). One chain Task runs it under the turn id
  # of the ended turn, with the id `{:settle, ref}` of the session's request; it
  # runs no plugin code, and asks the hands for a hook Task for each hook. Its
  # hook Tasks have the id `{:hook, {:settle, ref}}`. A cancel of the turn kills
  # it with its hook Task.

  alias Helyx.Session.Hands
  alias Helyx.Session.Hands.Chain

  @doc false
  # Runs the chain with `input`; the answer goes to the session as
  # `{:settle_answer, ref, :settle | {:continue, module, text}}`. A cast, as
  # `Hands.run/4`. `context` is the one of a call; the hands add the Core and
  # the tool names, with no tool and no call id.
  @spec request(pid(), String.t(), Helyx.Hook.settle(), map()) :: reference()
  def request(hands, turn_id, input, context) do
    ref = make_ref()
    GenServer.cast(hands, {:settle, ref, turn_id, input, context})
    ref
  end

  @doc false
  def start(state, {:settle, ref, turn_id, input, context}) do
    hooks = Map.fetch!(state.hooks, :before_settle)

    extra = %{
      core: state.core,
      tools: Hands.Sources.names(state),
      tool: nil,
      call_id: nil,
      source: nil
    }

    context = Map.merge(context, extra)

    {_task, state} =
      Hands.spawn_task(state, {:settle, ref}, turn_id, nil, fn ->
        Process.put(:helyx_call, context)
        Chain.settle(hooks, input)
      end)

    state
  end
end
