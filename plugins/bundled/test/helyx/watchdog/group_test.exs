defmodule Helyx.Watchdog.GroupTest do
  # The release of the handles of `Helyx.Watchdog`. A fake kill(1) makes a group that
  # survives KILL testable without an unkillable OS process.
  use ExUnit.Case, async: true

  import Helyx.Test.OSHelpers, only: [group_gone_within?: 2]

  alias Helyx.Watchdog.Group

  defp deadline(ms), do: System.monotonic_time(:millisecond) + ms

  # `Group.release/4` of handles given as `{kind, group}`, each with a new
  # record, and the handles still held in the same shape.
  defp release(groups, mode, deadline, opts \\ []) do
    groups
    |> Enum.map(fn {kind, group} -> {kind, group, Group.record()} end)
    |> Group.release(mode, deadline, opts)
    |> Enum.map(fn {kind, group, _record} -> {kind, group} end)
  end

  # A kill(1) fake over a set of live groups: KILL removes a group unless it
  # is in `unkillable`, a probe checks the set. A watchdog in `reaps`, a map
  # of watchdog to command group, exits by itself once its command group is
  # gone. Every run is echoed to the test process with the monotonic time of
  # its start.
  defp fake_kill(live, unkillable \\ [], reaps \\ %{}) do
    {:ok, agent} = Agent.start_link(fn -> MapSet.new(live) end)
    test = self()

    fn args ->
      send(test, {:kill, args, System.monotonic_time(:millisecond)})

      case args do
        ["-0", "--", target] ->
          probe(Agent.get(agent, & &1), reaps, target)

        ["-KILL", "--" | targets] ->
          killed =
            MapSet.new(targets, &(-String.to_integer(&1)))
            |> MapSet.difference(MapSet.new(unkillable))

          Agent.update(agent, &MapSet.difference(&1, killed))
          {"", 0}

        ["-TERM", "--" | _targets] ->
          {"", 0}
      end
    end
  end

  defp probe(live, reaps, target) do
    group = -String.to_integer(target)
    reaped? = Map.has_key?(reaps, group) and not MapSet.member?(live, reaps[group])

    if MapSet.member?(live, group) and not reaped?,
      do: {"", 0},
      else: {"kill: #{target}: No such process", 1}
  end

  # The kill runs so far, as `{args, started_at}`.
  defp runs(acc \\ []) do
    receive do
      {:kill, args, at} -> runs([{args, at} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp signals(runs \\ runs()) do
    for {[signal, "--" | targets], _at} <- runs, signal != "-0", do: {signal, targets}
  end

  # The wait after `signal` ends `ms` after a time that is before its first
  # probe, and it stops at the first probe at or after its end. So every probe
  # of the wait but the last starts before `ms` after the first. Load only
  # delays the probes, so it cannot fail this.
  defp assert_polls_within(runs, signal, ms) do
    assert [_signal | rest] = Enum.drop_while(runs, fn {[name | _], _} -> name != signal end)
    assert [{_, first} | _] = probes = Enum.take_while(rest, &match?({["-0" | _], _}, &1))
    assert Enum.all?(Enum.drop(probes, -1), fn {_, at} -> at < first + ms end)
  end

  # Room for scheduler load in a check of a wait that must not happen: above
  # the 524 ms that a parallel precommit run added (#295), below the KILL
  # wait of 5,000 ms that the checks rule out.
  @load_ms 2_000

  # The deadline of 1,000 ms leaves room for load before the first KILL
  # (#271). The KILL wait is 5,000 ms, so a wait that the deadline does not
  # bound ends about 4,000 ms after it, above `@load_ms`.
  @tag :slow
  test "a group that survives KILL is still held, and the deadline bounds the wait" do
    kill = fake_kill([4242], [4242])
    until = deadline(1_000)

    assert release([{:command, 4242}], :deliver, until, kill: kill) == [
             {:command, 4242}
           ]

    assert System.monotonic_time(:millisecond) - until < @load_ms
    assert signals() == [{"-KILL", ["-4242"]}]
  end

  # A watchdog that does not exit by itself gets its KILL after one wait of
  # 5,000 ms, only after the command group is gone.
  @tag :slow
  test "the watchdog is KILLed only after the command group is gone" do
    kill = fake_kill([100, 200])

    assert release([{:watchdog, 200}, {:command, 100}], :deliver, deadline(20_000), kill: kill) ==
             []

    assert signals() == [{"-KILL", ["-100"]}, {"-KILL", ["-200"]}]
  end

  test "a cancel TERMs the command group before the KILL, and never the watchdog" do
    kill = fake_kill([100, 200], [], %{200 => 100})

    assert release([{:command, 100}, {:watchdog, 200}], :cancel, deadline(2_000), kill: kill) ==
             []

    assert signals() == [{"-TERM", ["-100"]}, {"-KILL", ["-100"]}]
  end

  test "a group that stays to the deadline does not keep the handles of gone groups" do
    handles = [command: 7, watchdog: 6, command: 9, watchdog: 8, command: 11, watchdog: 10]
    assert [command: 7] = release_probed(handles, 300)
  end

  # A release whose first probes all ran before the deadline. A test
  # process that is late past the deadline skips them, and a skipped probe
  # keeps its group held: that run proves nothing, so it runs again with
  # twice the room, up to `@load_ms`.
  defp release_probed(handles, ms) do
    held = release(handles, :cancel, deadline(ms), grace_ms: 5_000, kill: fake_kill([7]))
    probed = for {["-0", "--", target], _at} <- runs(), uniq: true, do: target

    cond do
      length(probed) == length(handles) -> held
      ms < @load_ms -> release_probed(handles, ms * 2)
      true -> flunk("the first probes did not run within #{ms} ms")
    end
  end

  test "a group below 2 is never signalled" do
    kill = fake_kill([])
    handles = [{:command, 1}, {:watchdog, 0}, {:command, -1}]
    assert release(handles, :cancel, deadline(100), kill: kill) == []
    assert signals() == []
  end

  test "a probe that fails for another reason than a missing group keeps it held" do
    kill = fn
      ["-0" | _] -> {"kill: -340: Operation not permitted", 1}
      _ -> {"", 0}
    end

    assert release([{:command, 340}], :deliver, deadline(100), kill: kill) == [
             {:command, 340}
           ]
  end

  test "no kill run starts after the deadline, and every group stays held" do
    kill = fake_kill([100, 200])
    handles = [{:command, 100}, {:watchdog, 200}]
    assert release(handles, :deliver, deadline(0), kill: kill) == handles
    refute_received {:kill, _, _}
  end

  test "a deadline that passes during the release stops the kill runs" do
    kill = fake_kill([100, 200], [100, 200])
    slow = fn args -> Process.sleep(30) && kill.(args) end
    handles = [{:command, 100}, {:watchdog, 200}]

    assert release(handles, :cancel, deadline(50), kill: slow) == handles
    # Each run takes 30 ms, so a third run would start 60 ms or more after the
    # first, which is after the deadline. Load only makes the count smaller.
    assert length(runs()) <= 2
  end

  test "the TERM grace is 500 ms" do
    kill = fake_kill([100])
    start = System.monotonic_time(:millisecond)
    assert release([{:command, 100}], :cancel, deadline(10_000), kill: kill) == []
    assert System.monotonic_time(:millisecond) - start >= 500
    assert_polls_within(runs(), "-TERM", 500)
  end

  @tag :slow
  test "a longer grace waits up to its limit before the KILL" do
    kill = fake_kill([100])
    start = System.monotonic_time(:millisecond)

    assert release([{:command, 100}], :cancel, deadline(20_000),
             kill: kill,
             grace_ms: 1_000
           ) ==
             []

    assert System.monotonic_time(:millisecond) - start >= 1_000
    runs = runs()
    assert_polls_within(runs, "-TERM", 1_000)
    assert signals(runs) == [{"-TERM", ["-100"]}, {"-KILL", ["-100"]}]
  end

  @tag :slow
  test "a KILL wait ends after 5,000 ms" do
    kill = fake_kill([4242], [4242])
    start = System.monotonic_time(:millisecond)

    assert release([{:command, 4242}], :deliver, deadline(20_000), kill: kill) == [
             {:command, 4242}
           ]

    assert System.monotonic_time(:millisecond) - start >= 5_000
    assert_polls_within(runs(), "-KILL", 5_000)
  end

  # A TERM grace that does not stop at the deadline ends 10 s after it, far
  # above `@load_ms`.
  test "no wait passes the deadline" do
    kill = fake_kill([4242], [4242])
    until = deadline(50)
    release([{:command, 4242}], :cancel, until, kill: kill, grace_ms: 10_000)
    assert System.monotonic_time(:millisecond) - until < @load_ms
  end

  describe "the release record (docs/features/tool-resource-release.md)" do
    # A handle with a new record.
    defp handle(kind, group), do: {kind, group, Group.record()}

    # The fake kill(1) of `fake_kill/3`, and a function that gives `group`
    # to a new group of the OS, as a reuse of its number does.
    defp reusable(live) do
      {:ok, agent} = Agent.start_link(fn -> MapSet.new(live) end)
      test = self()

      kill = fn args ->
        send(test, {:kill, args, System.monotonic_time(:millisecond)})

        case args do
          ["-0", "--", target] ->
            if MapSet.member?(Agent.get(agent, & &1), -String.to_integer(target)),
              do: {"", 0},
              else: {"kill: #{target}: No such process", 1}

          [_signal, "--" | targets] ->
            Agent.update(
              agent,
              &MapSet.difference(&1, MapSet.new(targets, fn t -> -String.to_integer(t) end))
            )

            {"", 0}
        end
      end

      {kill, fn group -> Agent.update(agent, &MapSet.put(&1, group)) end}
    end

    test "a second release of a confirmed handle never signals the number of a new group" do
      {kill, reuse} = reusable([100])
      command = handle(:command, 100)
      # The bash timeout, then the delivery.
      assert Group.release([command], :cancel, deadline(5_000), kill: kill, grace_ms: 0) == []
      assert [{"-TERM", ["-100"]}] = signals()
      reuse.(100)
      assert Group.release([command], :deliver, deadline(5_000), kill: kill) == []
      assert runs() == []
    end

    test "two handles with one record in one release take it once and get one outcome" do
      {kill, _reuse} = reusable([100])
      command = handle(:command, 100)
      # The stop of the session releases a call Task and its server Task.
      assert Group.release([command, command], :deliver, deadline(5_000), kill: kill) == []
      assert [{"-KILL", ["-100"]}] = signals()

      stuck = handle(:command, 4242)
      kill = fake_kill([4242], [4242])
      held = Group.release([stuck, stuck], :deliver, deadline(100), kill: kill)
      assert held == [stuck, stuck]
    end

    test "the abort of a call handle, then the release of the server Task's handles, signals once" do
      # The watchdog reaped the command and is gone at the first probe.
      {kill, reuse} = reusable([100])
      server = [handle(:command, 100), handle(:watchdog, 200)]
      # The call Task holds copies of the server's handles.
      call = server
      assert Group.release(call, :cancel, deadline(5_000), kill: kill, grace_ms: 0) == []
      _ = runs()
      reuse.(100)
      reuse.(200)
      assert Group.release(server, :cancel, deadline(5_000), kill: kill) == []
      assert runs() == []
    end

    test "a handle that a killed Task kept after its own confirmed release gets no signal" do
      # The watchdog of a failed start read to its exit: gone at the probe.
      {kill, reuse} = reusable([])
      watchdog = handle(:watchdog, 200)
      # The cleanup of a failed start releases, and its Task is killed
      # before its unhold/1: the hands still hold the handle.
      task =
        Task.async(fn -> Group.release([watchdog], :deliver, deadline(5_000), kill: kill) end)

      assert Task.await(task) == []
      _ = runs()
      reuse.(200)
      assert Group.release([watchdog], :cancel, deadline(5_000), kill: kill) == []
      assert runs() == []
    end

    test "a release killed after it took the record holds it until its deadline, then the next takes over" do
      test = self()
      command = handle(:command, 100)

      stalled = fn args ->
        send(test, {:stalled, args})
        Process.sleep(:infinity)
      end

      # Its lease ends 300 ms from now.
      pid = spawn(fn -> Group.release([command], :deliver, deadline(300), kill: stalled) end)
      assert_receive {:stalled, ["-0" | _]}
      ref = Process.monitor(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}

      {kill, _reuse} = reusable([100])
      # A release whose own deadline comes first gets no turn, and no signal.
      assert Group.release([command], :deliver, deadline(50), kill: kill) == [command]
      assert runs() == []
      # One with a later deadline waits for the lease, then releases.
      assert Group.release([command], :deliver, deadline(5_000), kill: kill) == []
      assert {"-KILL", ["-100"]} in signals()
    end

    test "a release that raises leaves the record not confirmed, and the next tries again" do
      command = handle(:command, 100)
      raising = fn _args -> raise ErlangError, original: :emfile end

      assert_raise ErlangError, fn ->
        Group.release([command], :deliver, deadline(5_000), kill: raising)
      end

      {kill, _reuse} = reusable([100])
      assert Group.release([command], :deliver, deadline(5_000), kill: kill) == []
      assert {"-KILL", ["-100"]} in signals()
    end

    test "a release that finds the record taken waits for that release's outcome and sends no signal" do
      test = self()
      command = handle(:command, 100)
      {kill, _reuse} = reusable([100])
      slow = fn args -> send(test, {:first, args}) && Process.sleep(30) && kill.(args) end

      first =
        Task.async(fn -> Group.release([command], :deliver, deadline(5_000), kill: slow) end)

      assert_receive {:first, ["-0" | _]}

      second = fn _args -> send(test, :second_ran) && {"", 0} end
      assert Group.release([command], :deliver, deadline(5_000), kill: second) == []
      assert Task.await(first) == []
      refute_received :second_ran
    end

    test "a record of a group not confirmed gone lets the next release try again" do
      command = handle(:command, 4242)
      kill = fake_kill([4242], [4242])
      assert Group.release([command], :deliver, deadline(100), kill: kill) == [command]
      _ = runs()

      {kill, _reuse} = reusable([4242])
      assert Group.release([command], :deliver, deadline(5_000), kill: kill) == []
      assert {"-KILL", ["-4242"]} in signals()
    end

    test "a handle of another shape is dropped with no signal" do
      kill = fake_kill([100])
      handles = [{:command, 100}, {:command, 100, :not_a_record}, {:other, 100, Group.record()}]
      assert Group.release(handles, :deliver, deadline(100), kill: kill) == []
      assert runs() == []
    end
  end

  test "two real groups are both killed" do
    g1 = spawn_group()
    g2 = spawn_group()
    assert release([{:command, g1}, {:command, g2}], :deliver, deadline(5_000)) == []
    assert group_gone_within?(g1, 0)
    assert group_gone_within?(g2, 0)
  end

  # A real OS process group: perl makes itself a group leader, reports its
  # pid, and sleeps.
  defp spawn_group do
    perl = System.find_executable("perl")

    port =
      Port.open({:spawn_executable, perl}, [
        :binary,
        {:args, ["-e", ~S|setpgrp(0, 0); syswrite(STDOUT, "$$\n"); exec "sleep", "60"|]}
      ])

    receive do
      {^port, {:data, line}} -> String.to_integer(String.trim(line))
    after
      Helyx.Test.Events.wait_ms() -> flunk("no group pid")
    end
  end
end
