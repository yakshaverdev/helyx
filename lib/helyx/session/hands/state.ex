defmodule Helyx.Session.Hands.State do
  @moduledoc false

  alias Helyx.Session.Background
  alias Helyx.Session.Hands.Entry

  # `tools` is the tool module by name. `tasks` holds each running Task as
  # a `Helyx.Session.Hands.Entry`, by monitor ref. `background` holds the
  # ends that no turn took (`Helyx.Session.Background`); `background_dir`
  # is the background folder. `unconfirmed` holds each handle that a
  # release left unconfirmed; the log got it then. `release_ms` is the
  # release deadline of a delivery or a cancel, and `connect_ms` the armed
  # kill of a provider process: seams for tests. `hooks` holds the hook
  # modules and their limits of each point.
  @enforce_keys [:core, :cwd, :background_dir, :session, :tools]

  # The default release deadline, the one source (`Helyx.Session.Server.Stop`
  # derives its stop bounds from it).
  @release_ms 20_000
  def release_ms, do: @release_ms

  defstruct [
    :core,
    :cwd,
    :background_dir,
    :session,
    :tools,
    tasks: %{},
    hooks: %{},
    background: %Background{},
    unconfirmed: [],
    release_ms: @release_ms,
    connect_ms: 30_000
  ]

  # The ref and the entry of the Task `pid`, or nil: a Task that no longer
  # runs.
  def task(state, pid), do: find(state, &(&1.task.pid == pid))

  # The ref and the entry of the tool call Task `pid`, or nil: a hook Task
  # and a chain Task are no tool call.
  def tool_call(state, pid), do: find(state, &(&1.task.pid == pid and call?(&1.kind)))

  # The ref and the entry of the Task `pid` that can hold a handle, or nil:
  # a Task that no longer runs, and a chain Task, which runs no plugin code,
  # hold no handle.
  def holding(state, pid) do
    Enum.find(state.tasks, fn {_ref, entry} ->
      entry.task.pid == pid and entry.tool != nil
    end)
  end

  # The live background runs of the state, but the entry of `ref`: a call
  # that took a place under `Helyx.Tool.background/0`, and a run that has
  # one, which is the id of the run (`Helyx.Session.Background`). A second
  # call of the Task keeps its own place, so the limit does not count it.
  def live_runs(state, ref) do
    Enum.count(state.tasks, fn
      {^ref, _entry} -> false
      {_ref, %Entry{kind: {:placed, _call_id, _place}}} -> true
      {_ref, %Entry{kind: {:run, _id}}} -> true
      {_ref, %Entry{}} -> false
    end)
  end

  # `entry` in place of the entry of `ref`.
  def put(state, ref, entry), do: %{state | tasks: Map.put(state.tasks, ref, entry)}

  # The turn Task `pid` that runs a chain, with the id that its hook Tasks
  # stand under, or nil: a hook Task is no chain.
  def chain_call(state, pid) do
    with {_ref, entry} <- find(state, &(&1.task.pid == pid)),
         chain_id when chain_id != nil <- chain(entry),
         do: {entry.turn_id, chain_id}
  end

  # The id that the hook Tasks of a chain Task stand under, or nil: the call
  # id of a tool call Task or an approval chain Task, and its own id
  # `{:settle, ref}` for a `before_settle` chain Task. A hook Task and a
  # Task that no turn owns run no chain.
  def chain(%Entry{kind: {:call, call_id}}), do: call_id
  def chain(%Entry{kind: {:placed, call_id, _place}}), do: call_id
  def chain(%Entry{kind: {:approval, call_id}}), do: call_id
  def chain(%Entry{kind: {:settle, ref}}), do: {:settle, ref}
  def chain(%Entry{}), do: nil

  defp call?({:call, _call_id}), do: true
  defp call?({:placed, _call_id, _place}), do: true
  defp call?(_kind), do: false

  defp find(state, match?) do
    Enum.find(state.tasks, fn {_ref, entry} -> match?.(entry) end)
  end
end
