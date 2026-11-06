defmodule Helyx.Session.Hands.Hooks do
  @moduledoc false
  # The hook Tasks of `Helyx.Session.Hands` (docs/features/hooks.md): the
  # start of a hook for the call Task that runs its chain, its limit, its
  # release, the answer to the call Task, and the record to the session.
  # `state.hook_runs` holds each running hook by the monitor ref of its
  # Task: the caller to answer, the start of its run, and the request
  # (`Helyx.Session.Hands.Chain`). The answer of a hook is `{:answer,
  # answer}` or `{:failed, how}`.

  alias Helyx.Session.Hands
  alias Helyx.Session.Hands.{Outcome, Release, Run}

  # A hook of a call Task of a turn. Once a handle is unconfirmed, a hook
  # start is refused: a failed hook. A request of a Task that a cancel
  # killed after it sent it finds no call Task and gets no answer.
  def start(state, from, pid, request) do
    case Hands.tool_call(state, pid) do
      nil ->
        state

      {_ref, {_task, turn_id, call_id, _tool, _place}} ->
        start(state, from, request, turn_id, call_id)
    end
  end

  defp start(state, from, request, turn_id, call_id) do
    run = Map.merge(request, %{from: from, turn_id: turn_id, call_id: call_id})

    if state.unconfirmed != [] do
      answer(state, run, {:failed, Outcome.unreleased()})
    else
      {task, state} =
        Hands.spawn_task(state, turn_id, {:hook, call_id}, request.module, fn ->
          # The kill is armed at the OTP timer server as the Task's first
          # act, so the limit holds while the hands are busy with a
          # release; a reply that came before the kill counts.
          {:ok, _tref} = :timer.kill_after(request.ms)
          Helyx.Session.Ask.await_go()
          Process.put(:helyx_call, request.context)
          Run.hook(request.module, request.point, request.input)
        end)

      run = Map.put(run, :started_ms, System.monotonic_time(:millisecond))
      %{state | hook_runs: Map.put(state.hook_runs, task.ref, run)}
    end
  end

  # The end of a hook Task, however it ended: its handles are released
  # first, so the chain goes on only after the release. A kill at the limit
  # releases with `:cancel`.
  def deliver(state, ref, result) do
    {{task, _turn_id, _id, module, _place}, tasks} = Map.pop!(state.tasks, ref)
    {run, runs} = Map.pop!(state.hook_runs, ref)
    result = limit(result, run)
    mode = if result == :limit, do: :cancel, else: :deliver
    {handles, held} = Map.pop(state.held, task.pid, [])
    left = Release.run(%{module => handles}, mode, state.release_ms, state.core)
    outcome = if Release.error(left), do: unreleased(), else: outcome(result, run)
    run = Map.put(run, :pid, task.pid)
    state = answer(%{state | tasks: tasks, held: held, hook_runs: runs}, run, outcome)
    Hands.keep_unconfirmed(state, left)
  end

  # A kill at or after the limit is the armed kill.
  defp limit({:exit, :killed} = result, run) do
    if System.monotonic_time(:millisecond) - run.started_ms >= run.ms, do: :limit, else: result
  end

  defp limit(result, _run), do: result

  defp outcome({:exit, reason}, _run) do
    Helyx.Reason.log("hook crashed", reason)
    {:failed, "it crashed: " <> Helyx.Reason.text(reason)}
  end

  defp outcome(:limit, run), do: {:failed, "it ran past its limit of #{run.ms} ms"}
  defp outcome(answer, _run), do: answer

  defp unreleased, do: {:failed, "a resource of the hook could not be released"}

  # The record goes to the session before the call Task gets the answer,
  # and so before the record of the next hook: the session ends an ask of
  # the ended hook Task `pid` there, by the order of the hands alone. A
  # refused start has no Task.
  defp answer(state, run, outcome) do
    if recorded?(run.point, outcome) do
      record = %{
        point: run.point,
        call_id: run.call_id,
        hook: run.module,
        outcome: outcome,
        call: run.record,
        pid: Map.get(run, :pid)
      }

      send(state.session, {:hook_answer, run.turn_id, record})
    end

    GenServer.reply(run.from, outcome)
    state
  end

  # Every answer of a `before_tool` hook; an `after_tool` keep changes
  # nothing (ADR 0013 §6).
  defp recorded?(:after_tool, {:answer, :keep}), do: false
  defp recorded?(_point, _outcome), do: true

  # The runs of the Tasks that a cancel killed: no answer, their callers
  # were killed with them.
  def drop(state),
    do: %{
      state
      | hook_runs: Map.filter(state.hook_runs, fn {ref, _} -> is_map_key(state.tasks, ref) end)
    }

  # The call Task of `call_id` ended while its hook ran, such as by a
  # linked process: the hook is killed and its handles released with
  # `:cancel` before the call delivers. Its caller is gone: no answer.
  def orphans(state, turn_id, call_id) do
    {gone, kept} =
      Map.split_with(state.tasks, fn {_ref, {_task, turn, id, _module, _place}} ->
        turn == turn_id and id == {:hook, call_id}
      end)

    Enum.each(gone, fn {_ref, {task, _, _, _, _}} -> Task.shutdown(task, :brutal_kill) end)
    {taken, held} = Map.split(state.held, for({_ref, {task, _, _, _, _}} <- gone, do: task.pid))

    by_module =
      Enum.reduce(gone, %{}, fn {_ref, {task, _, _, module, _}}, acc ->
        Release.add(acc, %{module => Map.get(taken, task.pid, [])})
      end)

    left = Release.run(by_module, :cancel, state.release_ms, state.core)
    Hands.keep_unconfirmed(drop(%{state | tasks: kept, held: held}), left)
  end
end
