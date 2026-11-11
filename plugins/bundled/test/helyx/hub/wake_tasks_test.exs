defmodule Helyx.Hub.WakeTasksTest do
  use ExUnit.Case, async: true

  import Helyx.Test.HubWake

  alias Helyx.Hub
  alias Helyx.Hub.Wake
  alias Helyx.Test.Events
  alias Helyx.Test.WireClient, as: Client

  @moduletag :tmp_dir

  # Runs a poll in the Hub process and suspends each Task that it starts
  # before the Hub takes its first Hub call; gives the Tasks.
  defp poll_suspended(hub) do
    in_hub_replace(hub, fn state ->
      state = Wake.poll(state)
      tasks = for t <- Map.values(state.wake.tasks), do: Map.put(t, :pid, t.task.pid)
      Enum.each(tasks, &:erlang.suspend_process(&1.pid))
      {tasks, state}
    end)
  end

  defp in_hub_replace(hub, fun) do
    test = self()

    :sys.replace_state(hub, fn state ->
      {answer, state} = fun.(state)
      send(test, {:replaced, answer})
      state
    end)

    assert_received {:replaced, answer}
    answer
  end

  defp started(context) do
    {:ok, session} = Helyx.Sessions.start(context.core, cwd: File.cwd!(), model: "fake/echo")
    session.id
  end

  test "at most 4 Tasks, one for each session", context do
    context = serve(context)
    sessions = for _ <- 1..5, do: started(context)
    ids = for session <- sessions, do: due(context, context.owner, session)
    _second = due(context, context.owner, hd(sessions))

    tasks = poll_suspended(context.hub)
    assert length(tasks) == 4
    assert tasks |> Enum.map(& &1.session) |> Enum.uniq() |> length() == 4
    # A suspend holds for the process that made it: the Hub.
    in_hub(context.hub, fn _ -> Enum.each(tasks, &:erlang.resume_process(&1.pid)) end)

    # The others wait in the store and go at a later poll.
    Events.wait_until(fn ->
      poll(context.hub)
      Enum.all?(ids, &(row(context.hub, &1).last_outcome == "delivered"))
    end)
  end

  test "a delete kills the Task of its schedule", context do
    context = serve(context)
    {ann, socket} = user(context, "ann")
    session = start(socket)
    id = due(context, ann, session)
    [task] = poll_suspended(context.hub)
    ref = Process.monitor(task.pid)

    assert %{"ok" => true} =
             Client.request(socket, "r", "hub.schedules.delete", %{"schedule" => id})

    # The Task is gone before the reply: no send of it begins after.
    refute Process.alive?(task.pid)
    assert_receive {:DOWN, ^ref, :process, _, :killed}
    assert row(context.hub, id) == nil
    Events.wait_until(fn -> idle?(context.hub) end)
  end

  test "a Task killed before its send leaves the row due at its next try", context do
    context = serve(context)
    {ann, socket} = user(context, "ann")
    session = start(socket)
    %{"ok" => true} = Client.request(socket, "r", "stop", %{"session" => session})
    id = due(context, ann, session)
    [task] = poll_suspended(context.hub)
    ref = Process.monitor(task.pid)
    started_row = row(context.hub, id)

    send(context.hub, {:wake_kill, task_ref(context.hub, task.pid)})
    assert_receive {:DOWN, ^ref, :process, _, :killed}
    Events.wait_until(fn -> idle?(context.hub) end)

    assert row(context.hub, id) == started_row
    assert started_row.next_try_at in (now() + 140)..(now() + 150)
    assert Helyx.Session.pid(%Helyx.Session{id: session, core: context.core}) == nil
    # The place of the killed Task goes back with its `:DOWN`.
    assert in_hub(context.hub, &(&1.reserved == %{}))
  end

  test "the stop of Hub kills its Tasks", context do
    context = serve(context)
    id = due(context, context.owner, started(context))
    [task] = poll_suspended(context.hub)
    ref = Process.monitor(task.pid)
    :ok = stop_supervised(Helyx.Transport.WebSocket)
    :ok = stop_supervised(:hub)
    assert_receive {:DOWN, ^ref, :process, _, _reason}
    assert is_binary(id)
  end

  test "a wake-up at the cap of live sessions of the owner tries again later", context do
    context = serve(context, max_live_sessions: 1)
    {ann, socket} = user(context, "ann")
    stopped = start(socket)
    %{"ok" => true} = Client.request(socket, "r", "stop", %{"session" => stopped})
    _running = start(socket)
    id = due(context, ann, stopped)
    poll(context.hub)

    row = wait_row(context.hub, id, &(&1.next_try_at in (now() + 20)..(now() + 31)))
    assert %{run: 0, last_outcome: nil} = row
    assert Helyx.Session.pid(%Helyx.Session{id: stopped, core: context.core}) == nil
  end

  test "a pending wake-up outlives a stop of Hub and goes at the next start", context do
    context = serve(context)
    session = started(context)
    params = %{"session" => session, "at" => now() + 600, "prompt" => "after the restart"}
    {:ok, %{id: id}} = Hub.schedule(context.hub, context.owner, params)
    :ok = stop_supervised(Helyx.Transport.WebSocket)
    :ok = stop_supervised(:hub)

    {:ok, db} = Exqlite.Sqlite3.open(context.hub_opts[:path])
    past = now() - 1
    sql = "UPDATE schedules SET at = #{past}, due_at = #{past}, next_try_at = #{past}"
    :ok = Exqlite.Sqlite3.execute(db, sql <> " WHERE id = '#{id}'")
    :ok = Exqlite.Sqlite3.close(db)

    hub = start_supervised!(Supervisor.child_spec({Hub, context.hub_opts}, id: :hub))
    wait_row(hub, id, &(&1.last_outcome == "delivered"))
    assert [{"after the restart", _}] = woken(context.core, session)
  end

  defp task_ref(hub, pid) do
    in_hub(hub, fn state ->
      [ref] = for {ref, %{task: %{pid: ^pid}}} <- state.wake.tasks, do: ref
      ref
    end)
  end
end
