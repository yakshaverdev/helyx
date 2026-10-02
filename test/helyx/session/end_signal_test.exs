defmodule Helyx.Session.EndSignalTest do
  # Calls to a session that is not running (#188), and the end signal (#189).
  use ExUnit.Case, async: true

  import Helyx.Test.Events
  import Helyx.Test.SessionCase

  alias Helyx.{Event, Session}

  setup :start_core

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

    defp assert_not_found(session, core) do
      for {name, op} <- operations() do
        assert {name, {:error, :session_not_found}} == {name, op.(session)}
      end

      assert Registry.keys(Helyx.Core.events_registry(core), self()) == []
    end

    test "every operation on an id that never existed", %{core: core} do
      assert_not_found(%Session{id: "never", core: core}, core)
    end

    test "every operation on a session that ended", %{core: core} do
      {:ok, session} = Session.start(core, model: "test/ok")
      stop_session(session, &GenServer.stop/1)
      assert_not_found(session, core)
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

      assert_not_found(session, core)
      Enum.each(partitions, &:sys.resume/1)
    end

    @tag :capture_log
    test "a session that ends during the snapshot call", %{core: core} do
      {:ok, session} = Session.start(core, model: "test/ok")
      {:ok, _} = Session.subscribe(session)
      pid = Session.pid(session)
      :ok = :sys.suspend(pid)

      # The call is in the mailbox of the suspended session: the caller has
      # registered and waits for the snapshot. The session dies there.
      spawn(fn ->
        await(
          fn -> Process.info(pid, :message_queue_len) == {:message_queue_len, 1} end,
          "the call"
        )

        Process.exit(pid, :kill)
      end)

      assert Session.subscribe(session) == {:error, :session_not_found}
      # The session ended, so the entry of the first subscribe goes too.
      assert Registry.keys(Helyx.Core.events_registry(core), self()) == []
    end

    # A reconnect subscribes again from the same process. The session then
    # sends the events of a turn and stops while the snapshot call waits.
    @tag :capture_log
    test "a second subscribe keeps one entry, and a failed one removes it", %{core: core} do
      {:ok, session} = Session.start(core, model: "test/ok")
      {:ok, _} = Session.subscribe(session)
      {:ok, _} = Session.subscribe(session)
      registry = Helyx.Core.events_registry(core)
      assert [watch] = Registry.values(registry, session.id, self())
      assert is_pid(watch)

      pid = Session.pid(session)
      queued = fn n -> Process.info(pid, :message_queue_len) == {:message_queue_len, n} end
      test = self()

      # Only the process that suspends the session can resume it. The
      # mailbox: the prompt, the stop, then the snapshot call.
      spawn(fn ->
        true = :erlang.suspend_process(pid)
        send(test, :suspended)
        await(fn -> queued.(3) end, "the snapshot call")
        true = :erlang.resume_process(pid)
      end)

      assert_receive :suspended
      Task.start(fn -> Session.prompt(session, "hi") end)
      await(fn -> queued.(1) end, "the prompt")
      Task.start(fn -> GenServer.stop(pid) end)
      await(fn -> queued.(2) end, "the stop")

      assert Session.subscribe(session) == {:error, :session_not_found}
      assert Registry.values(registry, session.id, self()) == []

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

    # When a Core stops, the events Registry stops its partitions before it
    # stops itself. For a moment it has no partition, and a register raises
    # `ErlangError`.
    test "a subscribe while the Core stops", %{core: core} do
      {:ok, session} = Session.start(core, model: "test/ok")
      stop_session(session, &GenServer.stop/1)
      registry = Helyx.Core.events_registry(core)

      for {id, _, _, _} <- Supervisor.which_children(registry),
          do: :ok = Supervisor.terminate_child(registry, id)

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

    # An earlier entry of the caller goes too: a timeout is not a snapshot.
    @tag :slow
    test "a subscribe that times out leaves no entry", %{core: core} do
      {:ok, session} = Session.start(core, model: "test/ok")
      {:ok, _} = Session.subscribe(session)
      pid = Session.pid(session)
      true = :erlang.suspend_process(pid)

      exit = catch_exit(Session.subscribe(session))
      true = :erlang.resume_process(pid)
      assert {:timeout, _} = exit
      assert Registry.values(Helyx.Core.events_registry(core), session.id, self()) == []
    end

    test "input errors win over session_not_found", %{core: core} do
      session = %Session{id: "never", core: core}
      assert Session.steer(session, <<0xFF>>) == {:error, :invalid_utf8}
      assert Session.set_model(session, "bad") == {:error, {:invalid_model_ref, "bad"}}
    end
  end

  describe "the end signal (#189)" do
    defp watches(core, id),
      do: Registry.lookup(Helyx.Core.events_registry(core), {Helyx.Session.Watch, id})

    # Waits for the signal, then checks that no event follows it and that no
    # second signal follows.
    defp assert_end(id, reason) do
      await(fn -> Enum.any?(mailbox(), &match?({:helyx_session_end, _, _}, &1)) end, "the signal")
      after_signal = Enum.drop_while(mailbox(), &(not match?({:helyx_session_end, _, _}, &1)))
      assert [{:helyx_session_end, ^id, ^reason} | rest] = after_signal
      refute Enum.any?(rest, &match?({:helyx_event, _}, &1))
      assert_receive {:helyx_session_end, ^id, ^reason}
      refute_receive {:helyx_session_end, ^id, _}, 50
    end

    test "a normal stop gives :stopped, after the last event", %{core: core} do
      {:ok, session} = Session.start(core, model: "test/ok")
      {:ok, _} = Session.subscribe(session)
      :ok = Session.prompt(session, "hi")
      assert_receive {:helyx_event, %Event{type: :message_start}}
      :ok = GenServer.stop(Session.pid(session))

      assert_end(session.id, :stopped)
      await(fn -> watches(core, session.id) == [] end, "the watch to leave")
    end

    @tag :capture_log
    test "a kill and a raise give :crashed", %{core: core} do
      {:ok, killed} = Session.start(core, model: "test/ok")
      {:ok, _} = Session.subscribe(killed)
      :ok = Session.prompt(killed, "hi")
      assert_receive {:helyx_event, %Event{type: :message_start}}
      Process.exit(Session.pid(killed), :kill)
      assert_end(killed.id, :crashed)

      # No clause takes this message, so the session raises.
      {:ok, raised} = Session.start(core, model: "test/ok")
      {:ok, _} = Session.subscribe(raised)
      :ok = Session.prompt(raised, "hi")
      assert_receive {:helyx_event, %Event{type: :message_start}}
      send(Session.pid(raised), :unexpected)
      assert_end(raised.id, :crashed)
    end

    test "a Core that stops gives :stopped", %{core: core} do
      {:ok, session} = Session.start(core, model: "test/ok")
      {:ok, _} = Session.subscribe(session)
      # The link of the events Registry would end the test process.
      Process.flag(:trap_exit, true)
      :ok = Supervisor.stop(core)
      assert_end(session.id, :stopped)
    end

    @tag :capture_log
    test "a subscribe that gets a snapshot gets the end signal after it", %{core: core} do
      {:ok, session} = Session.start(core, model: "test/ok")
      pid = Session.pid(session)
      :ok = :sys.suspend(pid)
      queued = fn n -> Process.info(pid, :message_queue_len) == {:message_queue_len, n} end

      # The session traps exits, so the exit signal is a message behind the
      # snapshot call: the session answers the call, then stops.
      spawn(fn ->
        await(fn -> queued.(1) end, "the call")
        Process.exit(pid, :shutdown)
        await(fn -> queued.(2) end, "the exit")
        :ok = :sys.resume(pid)
      end)

      assert {:ok, _snapshot} = Session.subscribe(session)
      assert_end(session.id, :stopped)
    end

    @tag :capture_log
    test "a subscribe that fails as the session ends leaves no signal and no watch", %{
      core: core
    } do
      {:ok, session} = Session.start(core, model: "test/ok")
      {:ok, _} = Session.subscribe(session)
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
      refute_received {:helyx_session_end, _, _}
      await(fn -> watches(core, session.id) == [] end, "the watch to leave")
    end

    test "a subscribe to a session that never ran starts no watch", %{core: core} do
      assert Session.subscribe(%Session{id: "never", core: core}) ==
               {:error, :session_not_found}

      assert watches(core, "never") == []
    end

    # The lost signal waits until the supervisor that restarts the Registry
    # has handled the exit: the test holds that supervisor suspended. A
    # crash of the partition: the Registry supervisor restarts it. A crash
    # of the Registry supervisor: the Core restarts it.
    for name <- [:partition, :registry] do
      @tag :capture_log
      @tag :slow
      test "a restart of the events Registry (#{name}) gives a lost signal, and the session runs",
           %{core: core} do
        Process.flag(:trap_exit, true)
        {:ok, session} = Session.start(core, model: "test/ok")
        pid = Session.pid(session)
        {:ok, _} = Session.subscribe(session)
        registry = Helyx.Core.events_registry(core)
        [{_, partition, _, _}] = Supervisor.which_children(registry)

        {restarter, target} =
          case unquote(name) do
            :partition -> {Process.whereis(registry), partition}
            :registry -> {Process.whereis(core), Process.whereis(registry)}
          end

        :ok = :sys.suspend(restarter)
        Process.exit(target, :kill)
        id = session.id
        # Longer than the 5 s timeout the barrier once had: no timeout ends it.
        refute_receive {:helyx_subscription_lost, ^id}, 5_500
        assert Process.alive?(pid)
        :ok = :sys.resume(restarter)
        assert_receive {:helyx_subscription_lost, ^id}
        refute_receive {:helyx_subscription_lost, _}, 50
        refute_received {:helyx_session_end, _, _}

        assert {:ok, _snapshot} = Session.subscribe(session)
        assert Session.pid(session) == pid
        :ok = Session.prompt(session, "hi")
        seqs = Enum.map(collect_until(:agent_end), & &1.seq)
        assert seqs == Enum.uniq(seqs)
        refute_received {:helyx_event, _}

        :ok = GenServer.stop(pid)
        assert_end(id, :stopped)
      end
    end

    # The old entry is gone from the new Registry, but its watch still waits
    # to send a lost signal. A subscribe in that window stops it, so the
    # signal does not reach the new subscription.
    @tag :capture_log
    test "a subscribe after a restart stops the old watch that has not signalled",
         %{core: core} do
      Process.flag(:trap_exit, true)
      {:ok, session} = Session.start(core, model: "test/ok")
      {:ok, _} = Session.subscribe(session)
      [{old, nil}] = watches(core, session.id)
      registry = Helyx.Core.events_registry(core)
      supervisor = Process.whereis(registry)
      [{_, partition, _, _}] = Supervisor.which_children(registry)
      # `:messages` also counts the signals that a suspended process has not
      # fetched; `:message_queue_len` does not.
      queued = fn pid, n -> length(elem(Process.info(pid, :messages), 1)) == n end

      # The old watch calls the suspended supervisor behind the exit. The BIF
      # suspend holds it inside that call after the Registry is back.
      :ok = :sys.suspend(supervisor)
      Process.exit(partition, :kill)
      await(fn -> queued.(supervisor, 2) end, "the exit and the call")
      true = :erlang.suspend_process(old)
      :ok = :sys.resume(supervisor)
      await(fn -> queued.(old, 1) end, "the reply")

      assert {:ok, _snapshot} = Session.subscribe(session)
      refute Process.alive?(old)
      id = session.id
      refute_receive {:helyx_subscription_lost, ^id}, 100
      assert [{new, nil}] = watches(core, id)
      assert new != old

      :ok = GenServer.stop(Session.pid(session))
      assert_end(id, :stopped)
    end

    # Signals from two processes have no order, so the exit of the partition
    # can reach the watch before the Registry supervisor. The test makes that
    # order: it sends the exit to the watch while the partition still runs.
    # The watch must not send the lost signal while the supervisor has the
    # old partition, whatever the supervisor answers.
    @tag :capture_log
    test "the lost signal waits for a new partition, not for an answer of the supervisor",
         %{core: core} do
      Process.flag(:trap_exit, true)
      {:ok, session} = Session.start(core, model: "test/ok")
      {:ok, _} = Session.subscribe(session)
      [{watch, nil}] = watches(core, session.id)
      registry = Helyx.Core.events_registry(core)
      supervisor = Process.whereis(registry)
      [{_, partition, _, _}] = Supervisor.which_children(registry)

      :erlang.trace(supervisor, true, [:receive])
      send(watch, {:EXIT, partition, :killed})

      # Two checks of the supervisor, the second after the answer to the
      # first, and no lost signal.
      for _check <- 1..2 do
        assert_receive {:trace, ^supervisor, :receive, {:"$gen_call", {^watch, _}, _request}}
      end

      :erlang.trace(supervisor, false, [:receive])
      id = session.id
      refute_received {:helyx_subscription_lost, ^id}

      Process.exit(partition, :kill)
      assert_receive {:helyx_subscription_lost, ^id}
      assert {:ok, _snapshot} = Session.subscribe(session)

      :ok = GenServer.stop(Session.pid(session))
      assert_end(id, :stopped)
    end

    # A Registry that the product stops does not come back, so the watch
    # signals at once and does not wait for it.
    @tag :capture_log
    test "a stopped events Registry gives the lost signal at once", %{core: core} do
      Process.flag(:trap_exit, true)
      {:ok, session} = Session.start(core, model: "test/ok")
      {:ok, _} = Session.subscribe(session)
      [{watch, nil}] = watches(core, session.id)
      ref = Process.monitor(watch)

      :ok = Supervisor.terminate_child(core, Helyx.Core.events_registry(core))
      id = session.id
      assert_receive {:helyx_subscription_lost, ^id}
      assert_receive {:DOWN, ^ref, :process, ^watch, :normal}
    end

    # Each subscribe gets a live watch of its session, also when the watch
    # of the last one is gone (a lost signal that raced the register).
    test "a second subscribe replaces the watch", %{core: core} do
      {:ok, session} = Session.start(core, model: "test/ok")
      {:ok, _} = Session.subscribe(session)
      [{first, nil}] = watches(core, session.id)
      ref = Process.monitor(first)
      Process.exit(first, :kill)
      assert_receive {:DOWN, ^ref, :process, ^first, :killed}

      {:ok, _} = Session.subscribe(session)
      registry = Helyx.Core.events_registry(core)
      assert [second] = Registry.values(registry, session.id, self())
      assert second != first
      # The Registry drops the entry of the dead first watch when its
      # partition handles the exit, which the :DOWN above does not order.
      live = Enum.filter(watches(core, session.id), fn {pid, _} -> Process.alive?(pid) end)
      assert [{^second, nil}] = live

      :ok = GenServer.stop(Session.pid(session))
      assert_end(session.id, :stopped)
    end

    test "a subscribe removes the entries of dead watches and keeps their signals",
         %{core: core} do
      {:ok, ended} = Session.start(core, model: "test/ok")
      {:ok, _} = Session.subscribe(ended)
      :ok = GenServer.stop(Session.pid(ended))
      id = ended.id
      assert_receive {:helyx_session_end, ^id, :stopped} = signal
      send(self(), signal)

      {:ok, other} = Session.start(core, model: "test/ok")
      {:ok, _} = Session.subscribe(other)
      assert Process.get({Helyx.Session.Watch, core, ended.id}) == nil
      assert is_pid(Process.get({Helyx.Session.Watch, core, other.id}))
      assert_received {:helyx_session_end, ^id, :stopped}
    end

    test "a subscriber that exits stops its watch", %{core: core} do
      {:ok, session} = Session.start(core, model: "test/ok")
      test = self()

      subscriber =
        spawn(fn ->
          {:ok, _} = Session.subscribe(session)
          send(test, :subscribed)
          Process.sleep(:infinity)
        end)

      assert_receive :subscribed
      [{watch, nil}] = watches(core, session.id)
      ref = Process.monitor(watch)
      Process.exit(subscriber, :kill)
      assert_receive {:DOWN, ^ref, :process, ^watch, :normal}
    end
  end
end
