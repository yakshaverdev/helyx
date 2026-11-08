defmodule Helyx.Session.Hands.State do
  @moduledoc false

  alias Helyx.Session.Background

  # `tools` is the tool module by name. `tasks` holds each running Task,
  # its turn, its call id, its tool module, and its place, by monitor
  # ref: a background Task has no turn and `{:background, id}` for its
  # call id. The place is the id of the run from `background/0` to the end
  # of the Task, else nil. `background` holds the ends that no turn took
  # (`Helyx.Session.Background`); `background_dir` is the background
  # folder. `held` holds the handles per Task pid. `unconfirmed` holds
  # each handle that a release left unconfirmed; the log got it then.
  # `release_ms` is the release deadline of a delivery or a cancel, and
  # `connect_ms` the armed kill of a provider process: seams for tests.
  # `hooks` holds the hook modules and their limits of each point, and
  # `hook_runs` each running hook by the ref of its Task
  # (`Helyx.Session.Hands.Hooks`).
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
    hook_runs: %{},
    background: %Background{},
    held: %{},
    unconfirmed: [],
    release_ms: @release_ms,
    connect_ms: 30_000
  ]

  # The entry of the turn Task `pid` of a tool call, or nil: a hook Task
  # is no tool call.
  def tool_call(state, pid), do: find(state, pid, &is_binary/1)

  # The turn Task `pid` that runs a chain, with the id that its hook Tasks
  # stand under (`chain_id/1`), or nil: a tool call Task, the chain Task of
  # an approval request (`Helyx.Session.Hands.Approval`), or a
  # `before_settle` chain Task (`Helyx.Session.Hands.Settle`).
  def chain_call(state, pid) do
    with {_ref, {_task, turn_id, id, _module, _place}} <- find(state, pid, &chain_id?/1),
         do: {turn_id, chain_id(id)}
  end

  # The id that the hook Tasks of a chain Task stand under: the call id of
  # a tool call Task or an approval chain Task, and its own id
  # `{:settle, ref}` for a `before_settle` chain Task.
  def chain_id({:approval, call_id}), do: call_id
  def chain_id(id), do: id

  defp chain_id?(id), do: is_binary(id) or match?({kind, _} when kind in [:approval, :settle], id)

  defp find(state, pid, id?) do
    Enum.find(state.tasks, fn {_ref, {task, turn_id, id, _module, _place}} ->
      task.pid == pid and turn_id != nil and id?.(id)
    end)
  end
end
