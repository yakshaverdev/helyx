defmodule Helyx.Session.EndSignalTest do
  # Calls to a session that is not running (#188), the end signal (#189),
  # and the subscriber map of the session (#297).
  use ExUnit.Case, async: true

  import Helyx.Test.Events
  import Helyx.Test.SessionCase

  alias Helyx.{Event, Session}

  setup :start_core

  # The monitors of a process, as `{:process, pid}` entries.
  defp monitors(pid \\ self()), do: elem(Process.info(pid, :monitors), 1)

  defp subscribers(session), do: :sys.get_state(Session.pid(session)).subscribers

  describe "a session that is not running (#188)" do
    defp operations do
      [
        subscribe: &Session.subscribe/1,
        prompt: &Session.prompt(&1, "hi"),
        steer: &Session.steer(&1, "hi"),
        follow_up: &Session.follow_up(&1, "hi"),
        abort: &Session.abort/1,
        set_model: &Session.set_model(&1, "test/ok")
      ]
    end

    defp assert_not_found(session) do
      before = monitors()

      for {name, op} <- operations() do
        assert {name, {:error, :session_not_found}} == {name, op.(session)}
      end

      assert monitors() == before
    end

    test "every operation on an id that never existed", %{core: core} do
      assert_not_found(%Session{id: "never", core: core})
    end

    test "every operation on a session that ended", %{core: core} do
      {:ok, session} = Session.start(core, model: "test/ok")
      stop_session(session, &GenServer.stop/1)
      assert_not_found(session)
    end

    @tag :capture_log
    test "every operation on a dead session that is still registered", %{core: core} do
      {:ok, session} = Session.start(core, model: "test/ok")
      pid = Session.pid(session)
      # Holding the Registry keeps the dead name in its table.
      registry = Helyx.Core.sessions_registry(core)
      partitions = for {_, p, _, _} <- Supervisor.which_children(registry), do: p
      Enum.each(partitions, &:sys.suspend/1)
      ref = Process.monitor(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}

      assert_not_found(session)
      Enum.each(partitions, &:sys.resume/1)
    end

    # A reconnect subscribes again from the same process. The session then
    # sends the events of a turn and stops while the snapshot call waits.
    @tag :capture_log
    test "a second subscribe keeps one entry, and a failed one removes it", %{core: core} do
      {:ok, session} = Session.start(core, model: "test/ok")
      {:ok, _, first} = Session.subscribe(session)
      {:ok, _, ref} = Session.subscribe(session)
      Process.demonitor(first, [:flush])
      assert Map.keys(subscribers(session)) == [self()]

      pid = Session.pid(session)
      queued = fn n -> Process.info(pid, :message_queue_len) == {:message_queue_len, n} end
      test = self()

      # Only the process that suspends the session can resume it. The
      # mailbox: the prompt, the stop, then the subscribe call.
      spawn(fn ->
        true = :erlang.suspend_process(pid)
        send(test, :suspended)
        await(fn -> queued.(3) end, "the subscribe call")
        true = :erlang.resume_process(pid)
      end)

      assert_receive :suspended
      Task.start(fn -> Session.prompt(session, "hi") end)
      await(fn -> queued.(1) end, "the prompt")
      Task.start(fn -> GenServer.stop(pid) end)
      await(fn -> queued.(2) end, "the stop")

      assert Session.subscribe(session) == {:error, :session_not_found}
      # The ref of the earlier subscribe is the caller's: it gets its signal.
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}

      # The accepted hole: the events sent before the stop stay, each once.
      seqs =
        for {:helyx_event, %Event{seq: seq}} <- mailbox(),
            do: seq

      assert seqs != []
      assert seqs == Enum.uniq(seqs)
    end

    test "every operation after the Core stopped", %{core: core} do
      {:ok, session} = Session.start(core, model: "test/ok")
      :ok = Supervisor.stop(core)

      for {name, op} <- operations() do
        assert {name, {:error, :session_not_found}} == {name, op.(session)}
      end
    end

    # When a Core stops, it stops its sessions Registry, and a lookup of the
    # session pid raises `ArgumentError` until the Core is gone.
    test "a subscribe while the Core stops", %{core: core} do
      {:ok, session} = Session.start(core, model: "test/ok")
      stop_session(session, &GenServer.stop/1)
      :ok = Supervisor.terminate_child(core, Helyx.Core.sessions_registry(core))

      assert Session.subscribe(session) == {:error, :session_not_found}
    end

    # A session can stop with the reason `:timeout`, and the call then exits
    # like a call that timed out. The session traps exits, so the exit signal
    # is a message before the call, and the session stops on it before it
    # answers.
    @tag :capture_log
    test "a session that stops with the reason :timeout during a call", %{core: core} do
      {:ok, session} = Session.start(core, model: "test/ok")
      pid = Session.pid(session)
      true = :erlang.suspend_process(pid)
      Process.exit(pid, :timeout)
      task = Task.async(fn -> Session.prompt(session, "hi") end)

      await(
        fn -> Process.info(pid, :message_queue_len) == {:message_queue_len, 2} end,
        "the call"
      )

      ref = Process.monitor(pid)
      true = :erlang.resume_process(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, :timeout}
      assert Task.await(task, wait_ms()) == {:error, :session_not_found}
    end

    # A prompt waits in the mailbox of the session between the late
    # subscribe and the unsubscribe, so its first events reach the caller.
    @tag :slow
    @tag :capture_log
    test "a subscribe that times out leaves no subscription and no monitor", %{core: core} do
      {:ok, session} = Session.start(core, model: "test/ok")
      pid = Session.pid(session)
      true = :erlang.suspend_process(pid)
      queued = fn n -> Process.info(pid, :message_queue_len) == {:message_queue_len, n} end

      spawn(fn ->
        await(fn -> queued.(1) end, "the subscribe call")
        Task.start(fn -> Session.prompt(session, "hi") end)
      end)

      exit = catch_exit(Session.subscribe(session))
      assert {:timeout, _} = exit
      refute {:process, pid} in monitors()
      true = :erlang.resume_process(pid)

      assert subscribers(session) == %{}
      refute {:process, self()} in monitors(pid)
      late = for {:helyx_event, %Event{seq: seq}} <- mailbox(), do: seq
      assert late != []

      # A later subscribe has a snapshot after those events: the client
      # drops them by `seq`.
      assert {:ok, snapshot, _} = Session.subscribe(session)
      assert Enum.all?(late, &(&1 <= snapshot.seq))
    end

    test "input errors win over session_not_found", %{core: core} do
      session = %Session{id: "never", core: core}
      assert Session.steer(session, <<0xFF>>) == {:error, :invalid_utf8}
      assert Session.set_model(session, "bad") == {:error, {:invalid_model_ref, "bad"}}
    end
  end

  describe "the end signal (#189)" do
    defp end_signal?(message, ref), do: match?({:DOWN, ^ref, :process, _pid, _reason}, message)

    # Waits for the signal, then checks that no event follows it and that no
    # second signal follows.
    defp assert_end(ref, reason) do
      await(fn -> Enum.any?(mailbox(), &end_signal?(&1, ref)) end, "the signal")
      after_signal = Enum.drop_while(mailbox(), &(not end_signal?(&1, ref)))
      assert [{:DOWN, ^ref, :process, _, exit} | rest] = after_signal
      assert Session.end_reason(exit) == reason
      refute Enum.any?(rest, &match?({:helyx_event, _}, &1))
      assert_receive {:DOWN, ^ref, :process, _, _}
      refute_receive {:DOWN, ^ref, :process, _, _}, 50
    end

    test "a normal stop gives :stopped, after the last event", %{core: core} do
      {:ok, session} = Session.start(core, model: "test/ok")
      {:ok, _, ref} = Session.subscribe(session)
      :ok = Session.prompt(session, "hi")
      assert_receive {:helyx_event, %Event{type: :message_start}}
      :ok = GenServer.stop(Session.pid(session))

      assert_end(ref, :stopped)
    end

    @tag :capture_log
    test "a kill and a raise give :crashed", %{core: core} do
      {:ok, killed} = Session.start(core, model: "test/ok")
      {:ok, _, ref} = Session.subscribe(killed)
      :ok = Session.prompt(killed, "hi")
      assert_receive {:helyx_event, %Event{type: :message_start}}
      Process.exit(Session.pid(killed), :kill)
      assert_end(ref, :crashed)

      # No clause takes this message, so the session raises.
      {:ok, raised} = Session.start(core, model: "test/ok")
      {:ok, _, ref} = Session.subscribe(raised)
      :ok = Session.prompt(raised, "hi")
      assert_receive {:helyx_event, %Event{type: :message_start}}
      send(Session.pid(raised), :unexpected)
      assert_end(ref, :crashed)
    end

    # The test process does not trap exits: no link ends a subscriber.
    test "a Core that stops gives :stopped", %{core: core} do
      {:ok, session} = Session.start(core, model: "test/ok")
      {:ok, _, ref} = Session.subscribe(session)
      :ok = Supervisor.stop(core)
      assert_end(ref, :stopped)
    end

    @tag :capture_log
    test "a subscribe that gets a snapshot gets the end signal after it", %{core: core} do
      {:ok, session} = Session.start(core, model: "test/ok")
      pid = Session.pid(session)
      :ok = :sys.suspend(pid)
      queued = fn n -> Process.info(pid, :message_queue_len) == {:message_queue_len, n} end

      # The session traps exits, so the exit signal is a message behind the
      # subscribe call: the session answers the call, then stops.
      spawn(fn ->
        await(fn -> queued.(1) end, "the call")
        Process.exit(pid, :shutdown)
        await(fn -> queued.(2) end, "the exit")
        :ok = :sys.resume(pid)
      end)

      assert {:ok, _snapshot, ref} = Session.subscribe(session)
      assert_end(ref, :stopped)
    end

    @tag :capture_log
    test "a subscribe that fails as the session ends leaves no signal and no monitor", %{
      core: core
    } do
      {:ok, session} = Session.start(core, model: "test/ok")
      pid = Session.pid(session)
      :ok = :sys.suspend(pid)

      spawn(fn ->
        await(
          fn -> Process.info(pid, :message_queue_len) == {:message_queue_len, 1} end,
          "the call"
        )

        Process.exit(pid, :kill)
      end)

      assert Session.subscribe(session) == {:error, :session_not_found}
      refute Enum.any?(mailbox(), &match?({:DOWN, _, :process, ^pid, _}, &1))
      refute {:process, pid} in monitors()
    end

    test "a second subscribe gives each event once and one end signal", %{core: core} do
      {:ok, session} = Session.start(core, model: "test/ok")
      {:ok, _, first} = Session.subscribe(session)
      {:ok, _, ref} = Session.subscribe(session)
      # The client pairs the second subscribe with a demonitor of the first.
      Process.demonitor(first, [:flush])
      pid = Session.pid(session)
      assert Enum.count(monitors(), &(&1 == {:process, pid})) == 1

      :ok = Session.prompt(session, "hi")
      seqs = Enum.map(collect_until(:turn_end), & &1.seq)
      assert seqs == Enum.uniq(seqs)
      refute_received {:helyx_event, _}

      :ok = GenServer.stop(pid)
      assert_end(ref, :stopped)
    end

    test "repeated subscribes and unsubscribes leave at most one monitor in the session",
         %{core: core} do
      {:ok, session} = Session.start(core, model: "test/ok")
      pid = Session.pid(session)
      mine = fn -> Enum.count(monitors(pid), &(&1 == {:process, self()})) end

      for _round <- 1..3 do
        {:ok, _, first} = Session.subscribe(session)
        {:ok, _, second} = Session.subscribe(session)
        Process.demonitor(first, [:flush])
        Process.demonitor(second, [:flush])
        assert mine.() == 1
        assert Map.keys(subscribers(session)) == [self()]
        send(pid, {:unsubscribe, self()})
        assert subscribers(session) == %{}
        assert mine.() == 0
        # An unsubscribe of a pid with no entry changes nothing.
        send(pid, {:unsubscribe, self()})
        assert subscribers(session) == %{}
      end
    end

    test "a subscriber that dies is removed from the map", %{core: core} do
      {:ok, session} = Session.start(core, model: "test/ok")
      test = self()

      subscriber =
        spawn(fn ->
          {:ok, _, _} = Session.subscribe(session)
          send(test, :subscribed)
          Process.sleep(:infinity)
        end)

      assert_receive :subscribed
      assert Map.keys(subscribers(session)) == [subscriber]
      Process.exit(subscriber, :kill)
      await(fn -> subscribers(session) == %{} end, "the entry to go")
      refute {:process, subscriber} in monitors(Session.pid(session))
    end

    # Ten clients subscribe while ten turns run. Each gets every event after
    # its snapshot exactly once, in order, up to the end signal.
    test "subscribe and events in one step: no event is lost or doubled", %{core: core} do
      {:ok, session} = Session.start(core, model: "test/ok")
      pid = Session.pid(session)
      test = self()

      clients =
        for _ <- 1..10 do
          spawn_link(fn ->
            receive do: (:go -> :ok)
            {:ok, snapshot, ref} = Session.subscribe(session)
            send(test, {:subscribed, self()})
            send(test, {:seqs, self(), snapshot.seq, client_seqs(ref, [])})
          end)
        end

      {:ok, _, _} = Session.subscribe(session)

      for client <- clients do
        send(client, :go)
        :ok = Session.follow_up(session, "hi")
      end

      # Each client subscribed before the stop, under load too.
      for client <- clients, do: assert_receive({:subscribed, ^client})
      await_idle(pid)
      final = GenServer.call(pid, :snapshot).seq
      :ok = GenServer.stop(pid)

      for client <- clients do
        assert_receive {:seqs, ^client, from, seqs}
        assert seqs == Enum.to_list((from + 1)..final//1)
      end
    end
  end

  defp client_seqs(ref, acc) do
    receive do
      {:helyx_event, %Event{seq: seq}} -> client_seqs(ref, [seq | acc])
      {:DOWN, ^ref, :process, _pid, _reason} -> Enum.reverse(acc)
    end
  end

  defp await_idle(pid) do
    collect_until(:turn_end)

    case GenServer.call(pid, :snapshot) do
      %{turn: nil, queue: %{steers: 0, follow_ups: 0}} -> :ok
      _busy -> await_idle(pid)
    end
  end
end
