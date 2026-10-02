defmodule Helyx.Watchdog.GroupTest do
  # The release of the handles of `Helyx.Watchdog`. A fake kill(1) makes a group that
  # survives KILL testable without an unkillable OS process.
  use ExUnit.Case, async: true

  import Helyx.Test.OSHelpers, only: [group_gone_within?: 2]

  alias Helyx.Watchdog.Group

  defp deadline(ms), do: System.monotonic_time(:millisecond) + ms

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

    assert Group.release([{:command, 4242}], :deliver, until, kill: kill) == [
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

    assert Group.release([{:watchdog, 200}, {:command, 100}], :deliver, deadline(20_000),
             kill: kill
           ) ==
             []

    assert signals() == [{"-KILL", ["-100"]}, {"-KILL", ["-200"]}]
  end

  test "a cancel TERMs the command group before the KILL, and never the watchdog" do
    kill = fake_kill([100, 200], [], %{200 => 100})

    assert Group.release([{:command, 100}, {:watchdog, 200}], :cancel, deadline(2_000),
             kill: kill
           ) ==
             []

    assert signals() == [{"-TERM", ["-100"]}, {"-KILL", ["-100"]}]
  end

  test "a retry KILLs every group and probes once, with no wait" do
    kill = fake_kill([100, 200], [100, 200])
    handles = [{:command, 100}, {:watchdog, 200}]

    assert Group.release(handles, :retry, deadline(1_000), kill: kill) == handles
    # Each wait polls, and a poll would probe a held group again.
    assert Enum.map(runs(), &elem(&1, 0)) == [
             ["-KILL", "--", "-100", "-200"],
             ["-0", "--", "-100"],
             ["-0", "--", "-200"]
           ]
  end

  test "a group below 2 is never signalled, and an unknown handle stays held" do
    kill = fake_kill([])
    handles = [{:command, 1}, {:watchdog, 0}, :other]
    assert Group.release(handles, :cancel, deadline(100), kill: kill) == handles
    assert signals() == []
  end

  test "a probe that fails for another reason than a missing group keeps it held" do
    kill = fn
      ["-0" | _] -> {"kill: -340: Operation not permitted", 1}
      _ -> {"", 0}
    end

    assert Group.release([{:command, 340}], :retry, deadline(100), kill: kill) == [
             {:command, 340}
           ]
  end

  test "no kill run starts after the deadline, and every group stays held" do
    kill = fake_kill([100, 200])
    handles = [{:command, 100}, {:watchdog, 200}]
    assert Group.release(handles, :deliver, deadline(0), kill: kill) == handles
    refute_received {:kill, _, _}
  end

  test "a deadline that passes during the release stops the kill runs" do
    kill = fake_kill([100, 200], [100, 200])
    slow = fn args -> Process.sleep(30) && kill.(args) end
    handles = [{:command, 100}, {:watchdog, 200}]

    assert Group.release(handles, :cancel, deadline(50), kill: slow) == handles
    # Each run takes 30 ms, so a third run would start 60 ms or more after the
    # first, which is after the deadline. Load only makes the count smaller.
    assert length(runs()) <= 2
  end

  test "the TERM grace is 500 ms" do
    kill = fake_kill([100])
    start = System.monotonic_time(:millisecond)
    assert Group.release([{:command, 100}], :cancel, deadline(10_000), kill: kill) == []
    assert System.monotonic_time(:millisecond) - start >= 500
    assert_polls_within(runs(), "-TERM", 500)
  end

  @tag :slow
  test "a longer grace waits up to its limit before the KILL" do
    kill = fake_kill([100])
    start = System.monotonic_time(:millisecond)

    assert Group.release([{:command, 100}], :cancel, deadline(20_000),
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

    assert Group.release([{:command, 4242}], :deliver, deadline(20_000), kill: kill) == [
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
    Group.release([{:command, 4242}], :cancel, until, kill: kill, grace_ms: 10_000)
    assert System.monotonic_time(:millisecond) - until < @load_ms
  end

  test "two real groups are both killed" do
    g1 = spawn_group()
    g2 = spawn_group()
    assert Group.release([{:command, g1}, {:command, g2}], :deliver, deadline(5_000)) == []
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
