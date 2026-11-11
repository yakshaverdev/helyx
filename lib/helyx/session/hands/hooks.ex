defmodule Helyx.Session.Hands.Hooks do
  @moduledoc false
  # The hook Tasks of `Helyx.Session.Hands` (docs/features/hooks.md): the start
  # of a hook for the call Task that runs its chain, its limit, its release, the
  # answer to the call Task, and the record to the session. The run of a hook is
  # in the kind of its entry in the state (`Helyx.Session.Hands.Entry`). The
  # answer of a hook is `{:answer, answer}` or `{:failed, how}`.

  alias Helyx.Session.Hands
  alias Helyx.Session.Hands.{End, Entry, Outcome, Release, Run, State}

  # Once a handle is unconfirmed, a hook start is refused: a failed hook. A
  # request of a Task that a cancel killed after it sent it finds no Task and
  # gets no answer.
  def start(state, from, pid, request) do
    case State.chain_call(state, pid) do
      nil -> state
      {turn_id, call_id} -> start(state, from, request, turn_id, call_id)
    end
  end

  defp start(state, from, request, turn_id, call_id) do
    run = Map.merge(request, %{from: from, turn_id: turn_id, call_id: call_id})

    if state.unconfirmed != [] do
      answer(state, run, {:failed, Outcome.unreleased()})
    else
      {task, state} =
        Hands.spawn_task(state, {:hook, call_id, run}, turn_id, request.module, fn ->
          # The kill is armed at the OTP timer server as the Task's first act,
          # so the limit holds while the hands are busy with a release; a reply
          # that came before the kill counts.
          {:ok, _tref} = :timer.kill_after(request.ms)
          Helyx.Session.Ask.await_go()
          Process.put(:helyx_call, request.context)
          Run.hook(request.module, request.point, request.input)
        end)

      run = Map.put(run, :started_ms, System.monotonic_time(:millisecond))
      entry = Map.fetch!(state.tasks, task.ref)
      State.put(state, task.ref, %{entry | kind: {:hook, call_id, run}})
    end
  end

  # The end of a hook Task, however it ended: its handles are released first,
  # so the chain goes on only after the release.
  def deliver(state, ref, result) do
    %Entry{task: task, kind: {:hook, _call_id, run}} = Map.fetch!(state.tasks, ref)
    result = limit(result, run)
    mode = if result == :limit, do: :cancel, else: :deliver
    {left, state} = End.finish(state, [ref], mode, state.release_ms, false)
    outcome = if Release.error(left), do: unreleased(), else: outcome(result, run)
    run = Map.put(run, :pid, task.pid)
    answer(state, run, outcome)
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

  # The record goes to the session before the call Task gets the answer, and so
  # before the record of the next hook: the session ends an ask of the ended
  # hook Task `pid` there. A refused start has no Task.
  defp answer(state, run, outcome) do
    if recorded?(run.point, outcome) do
      record = %{
        point: run.point,
        call_id: call_id(run.call_id),
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

  # A `before_settle` hook has no call, and its entry no call id.
  defp call_id({:settle, _ref}), do: nil
  defp call_id(call_id), do: call_id

  # Every answer of a `before_tool` hook; a keep and a settle change nothing
  # (ADR 0013 §6).
  defp recorded?(:after_tool, {:answer, :keep}), do: false
  defp recorded?(:before_settle, {:answer, :settle}), do: false
  defp recorded?(_point, _outcome), do: true

  # The call Task of `call_id` ended while its hook ran: the hook is killed and
  # its handles released with `:cancel` before the call delivers. Its caller is
  # gone: no answer.
  def orphans(state, turn_id, call_id) do
    refs =
      for {ref, %Entry{turn_id: ^turn_id, kind: {:hook, ^call_id, _run}}} <- state.tasks, do: ref

    {_left, state} = End.finish(state, refs, :cancel, state.release_ms, true)
    state
  end
end
