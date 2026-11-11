defmodule Helyx.Session.Hands.End do
  @moduledoc false
  # Every end runs the same sequence (`finish/5`): the Tasks that still run are
  # killed, the handles of each go to the `release/3` of its tool with one mode
  # and one deadline, and each entry leaves the state. The outcome of a Task
  # leaves after the release returned, and a handle that the release does not
  # confirm refuses the next start
  # (docs/features/tool-resource-release.md).

  alias Helyx.Session.Background
  alias Helyx.Session.Hands.{Entry, Hooks, Outcome, Release, Sources, State}

  # Each kind ends by its own path, so no path decodes the kind from the shape
  # of a message.
  def deliver(ref, result, state) do
    %Entry{kind: kind} = entry = Map.fetch!(state.tasks, ref)

    case kind do
      {:hook, _chain_id, _run} -> Hooks.deliver(state, ref, result)
      {:source, _plugin} -> Sources.deliver(state, ref)
      {:server, _source, _launch} -> Sources.deliver(state, ref)
      _kind -> answered(state, ref, entry, result)
    end
  end

  @doc false
  # The end of the Tasks of `refs`: each one is killed with `:brutal_kill` when
  # `kill?`, which a Task that a delivery ends does not need; the handles of
  # each go to the `release/3` of its tool with `mode`; and each entry leaves
  # the state. Returns the handles that stay held, per tool, and the state.
  def finish(state, refs, mode, ms, kill?) do
    {gone, tasks} = Map.split(state.tasks, refs)

    if kill?,
      do: Enum.each(gone, fn {_ref, entry} -> Task.shutdown(entry.task, :brutal_kill) end)

    # One `release/3` call for each tool that holds any handle; a chain Task
    # holds none.
    by_tool =
      Enum.reduce(gone, %{}, fn {_ref, entry}, acc ->
        Release.add(acc, %{entry.tool => entry.handles})
      end)

    left = Release.run(by_tool, mode, ms, state.core)
    held = state.unconfirmed ++ Enum.concat(Map.values(left))
    {left, %{state | tasks: tasks, unconfirmed: held}}
  end

  # The end of the Tasks whose outcome the session gets: a call, a run, a
  # chain, or the provider process.
  defp answered(state, ref, entry, result) do
    state = orphans(state, entry)
    {left, state} = finish(state, [ref], :deliver, state.release_ms, false)
    send(state.session, Outcome.of(entry, Release.error(left) || result))
    ended(state, entry.kind)
  end

  # The hook Tasks of the chain that the Task ran end with it: each hook is
  # killed and its handles released with `:cancel` before the Task delivers
  # (`Hooks.orphans/3`).
  defp orphans(state, %Entry{} = entry) do
    case State.chain(entry) do
      nil -> state
      chain_id -> Hooks.orphans(state, entry.turn_id, chain_id)
    end
  end

  # The place of a run that gave its start answer waits for a turn to take its
  # end, so it outlives its Task (`Helyx.Session.Background`).
  defp ended(state, {:run, id}),
    do: %{state | background: Background.ended(state.background, {:background, id})}

  defp ended(state, _kind), do: state
end
