defmodule Helyx.Hub.Wake do
  @moduledoc false
  # The wake-ups of a Hub (`docs/features/hub.md`, decision 12), in the
  # state of the Hub process: the poll of the due rows, the delivery Tasks
  # (`Helyx.Hub.Delivery`), and the writes that a Task asks for in its Hub
  # calls.
  #
  # `tasks`: the monitor ref of a Task => its entry, at most 4, one for each
  # session. `subscription` is nil for a schedule and the subscription id for
  # the delivery of a webhook. The kill of a Task past its 120,000 ms keeps
  # its entry to its `:DOWN`: a Hub call that the Task sent before the kill
  # comes before its `:DOWN`, so it is taken while the entry still holds the
  # session, and no second Task of the session starts first.

  alias Helyx.Hub.{Delivery, Live, Rules, Schedules}

  # The poll (Bounds): each 1,000 ms, at most 64 rows each read.
  @poll_ms 1_000
  @poll_rows 64
  @max_tasks 4
  # The life of a wake-up from its due time, in seconds.
  @life_s 3_600
  # A Task is killed 120,000 ms after its start; its row comes due again at
  # the start plus 150,000 ms, so a Hub call that the Task sent before its
  # kill (4,000 ms at most) is taken or dropped before a new Task can start.
  @task_ms 120_000
  @hold_s 150
  # The wait before the next try of a wake-up that the session or the cap
  # put off.
  @retry_s 30

  def init(state) do
    {:ok, sup} = Task.Supervisor.start_link()
    Map.put(state, :wake, %{sup: sup, tasks: %{}, poll: nil})
  end

  # The rows whose next try has come; the next poll in 1,000 ms. A poll out
  # of turn replaces the timer, so at most one poll timer runs.
  def poll(state) do
    if state.wake.poll, do: Process.cancel_timer(state.wake.poll)
    now = System.os_time(:second)

    state =
      case state.store.due(state.db, now, @poll_rows) do
        {:ok, rows} -> Enum.reduce(rows, state, &due(&1, now, &2))
        {:error, _} -> state
      end

    put_in(state.wake.poll, next_poll())
  end

  # The app env `:hub_poll_timer` of `helyx_plugins`, false for tests only,
  # arms no timer: the test sends each poll.
  defp next_poll do
    if Application.get_env(:helyx_plugins, :hub_poll_timer) != false,
      do: Process.send_after(self(), :wake_poll, @poll_ms)
  end

  defp due(row, now, state) do
    cond do
      past_life?(row, now) ->
        at = now()

        case write(state, row, outcome(row, "missed", at), :infinity) do
          :ok -> _ = settle(state, row, "missed", at, :infinity)
          _stale -> :ok
        end

        state

      busy?(state.wake.tasks, row.session_id) ->
        state

      true ->
        start(state, row, now)
    end
  end

  defp busy?(tasks, session_id),
    do:
      map_size(tasks) >= @max_tasks or Enum.any?(tasks, fn {_, t} -> t.session == session_id end)

  # The write of the start comes first: a Task that dies before its send
  # leaves a row that comes due again by itself.
  defp start(state, row, now) do
    case write(state, row, %{next_try_at: now + @hold_s}, :infinity) do
      :ok ->
        row = %{row | next_try_at: now + @hold_s}
        task = Task.Supervisor.async(state.wake.sup, Delivery, :run, [self(), state.core, row])
        timer = Process.send_after(self(), {:wake_kill, task.ref}, @task_ms)

        entry = %{
          task: task,
          schedule: row.id,
          session: row.session_id,
          owner: row.owner,
          subscription: row.subscription_id
        }

        put_in(state.wake.tasks[task.ref], Map.put(entry, :timer, timer))

      {:error, _} ->
        state
    end
  end

  # The outcome of the run of `row` and the next pending wake-up: the next
  # time after now, a whole number of periods after `at`, or none for a
  # schedule of one run (decision 11).
  def outcome(row, outcome, now) do
    last = %{run: row.run + 1, last_at: now, last_outcome: outcome}

    case row.every do
      nil ->
        Map.merge(last, %{delivery_id: nil, due_at: nil, next_try_at: nil})

      every ->
        at = row.at + every * max(div(now - row.at, every) + 1, 1)
        Map.merge(last, %{at: at, delivery_id: Schedules.new_id(), due_at: at, next_try_at: at})
    end
  end

  # A refused run ends its schedule: its row keeps the outcome with no
  # pending wake-up (decisions 8 and 11).
  defp refused(row, now),
    do: %{
      run: row.run + 1,
      last_at: now,
      last_outcome: "refused",
      delivery_id: nil,
      due_at: nil,
      next_try_at: nil
    }

  # A write on the row as the start of its Task left it. The delivery state
  # of the subscription of a webhook moves only with a final outcome, in
  # `settle/5` (decision 17); the decide marker does not move it.
  defp write(state, row, changes, deadline) do
    state.store.update_schedule(
      state.db,
      row.id,
      Map.take(row, [:run, :next_try_at]),
      changes,
      deadline
    )
  end

  # Only a final outcome moves the subscription: a put-back changes
  # nothing, and the store keeps a `refused` (decision 17).
  defp settle(state, %{subscription_id: sub}, outcome, at, deadline)
       when is_binary(sub) do
    state.store.subscription_sent(state.db, sub, at, outcome, deadline)
  end

  defp settle(_state, _row, _outcome, _at, _deadline), do: :ok

  # The Hub calls of a delivery Task; `row` is the row as the start of the
  # Task wrote it, and the caller is the Task.
  def serve({:wake_place, row}, caller, deadline, state) do
    with :ok <- holds(state, row),
         :ok <- alive(state, row, deadline),
         :ok <- writable(state, row),
         {:ok, state} <- Live.reserve(state, row.owner, caller, false) do
      {:ok, state}
    else
      :refused -> {refuse(state, row, deadline), state}
      {:error, :too_many_sessions} -> {retry(state, row, deadline), state}
      error -> {error, state}
    end
  end

  def serve({:wake_resumed, row, pid}, caller, _deadline, state),
    do: {:ok, Live.started(state, caller, row.session_id, pid, row.owner)}

  def serve({:wake_retry, row}, caller, deadline, state),
    do: {retry(state, row, deadline), Live.release(state, caller)}

  def serve({:wake_refused, row}, caller, deadline, state),
    do: {refuse(state, row, deadline), Live.release(state, caller)}

  # Step 2: the send is decided. The outcome `unconfirmed` and the next
  # pending wake-up, only while the row holds what the start of this Task
  # wrote; the Task sends only after `:ok`.
  def serve({:wake_decide, row}, _caller, deadline, state) do
    with :ok <- alive(state, row, deadline),
         :ok <- writable(state, row) do
      {write(state, row, outcome(row, "unconfirmed", now()), deadline), state}
    else
      :refused -> {refuse(state, row, deadline), state}
      error -> {error, state}
    end
  end

  # Step 3: the answer of the prompt, on the row as step 2 left it.
  def serve({:wake_outcome, row, answer}, _caller, deadline, state) do
    sent = %{run: row.run + 1, last_outcome: "unconfirmed"}
    {answered(state, row, sent, answer, deadline), state}
  end

  # `delivered` also moves the record of the session, as a text that Hub
  # authorized (Store schema); `head` is the prompt cut to 1,024 bytes.
  defp answered(state, row, sent, {:delivered, head}, deadline) do
    %{store: mod, db: db} = state
    changes = %{last_outcome: "delivered"}
    at = now()

    with :ok <- mod.update_schedule(db, row.id, sent, changes, deadline),
         :ok <- settle(state, row, "delivered", at, deadline),
         do: mod.touch_record(db, row.session_id, at, head, deadline)
  end

  # The session took nothing: the row as it was before step 2, tried again
  # later. A put-back changes nothing on the subscription (decision 17).
  defp answered(state, row, sent, :back, deadline) do
    before = Map.take(row, [:at, :run, :delivery_id, :due_at, :last_at, :last_outcome])
    changes = Map.put(before, :next_try_at, now() + @retry_s)
    state.store.update_schedule(state.db, row.id, sent, changes, deadline)
  end

  # The session took nothing and the wake-up ends refused after the decide:
  # the row of a refusal before the send, on the row as the decide left it
  # (decisions 8 and 11, and `Helyx.Hub.Delivery.abandoned/3`).
  defp answered(state, row, sent, :refused, deadline) do
    at = now()

    case state.store.update_schedule(state.db, row.id, sent, refused(row, at), deadline) do
      :ok -> settle(state, row, "refused", at, deadline)
      other -> other
    end
  end

  # The prompt call went out with no answer that proves the session took
  # nothing: the row keeps `unconfirmed`, and that final outcome moves the
  # subscription.
  defp answered(state, row, _sent, :unconfirmed, deadline),
    do: settle(state, row, "unconfirmed", now(), deadline)

  # Whether the row still holds what the start of this Task wrote.
  defp holds(%{store: mod, db: db}, row) do
    case mod.schedule(db, row.id) do
      {:ok, %{run: run, next_try_at: at}} when run == row.run and at == row.next_try_at -> :ok
      {:ok, _} -> {:error, :stale}
      error -> error
    end
  end

  # The owner of the schedule may still write the session (decisions 4 and
  # 11). The Task found the session running or resumes it, so a session
  # with no row counts as one that exists.
  defp writable(state, row) do
    with {:ok, access} <- Rules.access(row.session_id, true, state) do
      case Rules.allowed(:write, access, row.owner) do
        :ok -> :ok
        {:error, _} -> :refused
      end
    end
  end

  # A wake-up past its life ends `missed`, also in a Task that the poll
  # started before the end of its life: the resume can take 30,000 ms.
  defp alive(state, row, deadline) do
    if past_life?(row, now()) do
      at = now()

      case write(state, row, outcome(row, "missed", at), deadline) do
        :ok -> _ = settle(state, row, "missed", at, deadline)
        _stale -> :ok
      end

      {:error, :missed}
    else
      :ok
    end
  end

  defp past_life?(row, now), do: now >= row.due_at + @life_s

  defp retry(state, row, deadline) do
    _ = write(state, row, %{next_try_at: now() + @retry_s}, deadline)
    {:error, :retry}
  end

  # Every refusal answers `{:error, :refused}`, so the Task sends nothing.
  defp refuse(state, row, deadline) do
    at = now()

    case write(state, row, refused(row, at), deadline) do
      :ok -> _ = settle(state, row, "refused", at, deadline)
      _stale -> :ok
    end

    {:error, :refused}
  end

  defp now, do: System.os_time(:second)

  # The kill of the Tasks whose rows a delete removed, before the reply of
  # the delete: no send of such a Task begins after it. A Hub call that the
  # Task sent before its kill finds no row to write.
  def kill(state, which?) do
    Enum.reduce(state.wake.tasks, state, fn {ref, task}, state ->
      if which?.(task) do
        Task.shutdown(task.task, :brutal_kill)
        ended(state, ref)
      else
        state
      end
    end)
  end

  # The kill of a Task 120,000 ms after its start.
  def expired(state, ref) do
    case state.wake.tasks do
      %{^ref => task} -> Process.exit(task.task.pid, :kill)
      _ -> :ok
    end

    state
  end

  # The reply or the `:DOWN` of a Task; another ref changes nothing.
  def ended(state, ref) do
    case Map.pop(state.wake.tasks, ref) do
      {nil, _tasks} ->
        state

      {task, tasks} ->
        Process.demonitor(ref, [:flush])
        Process.cancel_timer(task.timer)
        put_in(state.wake.tasks, tasks)
    end
  end

  # The stop of Hub kills its Tasks (decision 16).
  def stop(state), do: kill(state, fn _task -> true end)
end
