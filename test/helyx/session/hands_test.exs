defmodule Helyx.Session.HandsTest do
  # The hands' handle bookkeeping, driven directly with the test process as
  # the session. The hold test tools release, keep, or fail on the handles
  # they get, so no OS resource is needed.
  use ExUnit.Case, async: true

  alias Helyx.Message.ToolCall

  # Room for scheduler load in a check of a wait that must not happen: far
  # above the delays that load makes, far below the waits that the checks
  # rule out.
  @load_ms 1_000

  setup do
    core = :"core_#{System.unique_integer([:positive])}"

    plugins = [
      Helyx.Test.Provider,
      Helyx.Test.Tool.Hold,
      Helyx.Test.Tool.HoldTwo,
      Helyx.Test.Tool.HoldBare,
      Helyx.Test.Tool.Upcase
    ]

    start_supervised!({Helyx.Core, name: core, plugins: plugins})
    %{core: core}
  end

  defp start_hands(core, opts \\ []) do
    {:ok, tools} = Helyx.Tool.specs(core)

    opts =
      [
        core: core,
        cwd: File.cwd!(),
        session: self(),
        tools: Map.new(tools, fn {tool, spec} -> {spec.name, tool} end)
      ] ++ opts

    {:ok, hands} = Helyx.Session.Hands.start_link(opts)
    # `await_held/2` waits for the hold calls that the trace shows.
    :erlang.trace(hands, true, [:receive])
    hands
  end

  defp call(id, name, arguments), do: %ToolCall{id: id, name: name, arguments: arguments}

  defp cancel(hands, turn_id) do
    request = Helyx.Session.Hands.request_cancel(hands, turn_id)
    {:reply, result} = :gen_server.receive_response(request, :infinity)
    result
  end

  defp upcase(hands, id) do
    :ok = Helyx.Session.Hands.run(hands, "t1", call(id, "upcase", %{"text" => "hi"}))
    assert_receive {:tool_result, "t1", ^id, result}, 2_000
    result
  end

  test "an unconfirmed handle gives an error result and blocks calls until a retry releases it",
       %{core: core} do
    {:ok, agent} = Agent.start_link(fn -> true end)
    hands = start_hands(core)
    handles = [{:keep, agent}, {:report, self()}]

    :ok = Helyx.Session.Hands.run(hands, "t1", call("c1", "hold", %{"handles" => handles}))
    assert_receive {:tool_result, "t1", "c1", {:error, text}}, 2_000
    assert text =~ "could not be released"
    assert text =~ inspect({:keep, agent})
    assert_received {:release, :deliver, _handles}

    # The next call is refused, and the kept handle gets a retry first.
    assert {:error, text} = upcase(hands, "c2")
    assert text =~ "earlier call"

    # Once the retry releases it, calls run again.
    Agent.update(agent, fn _ -> false end)
    assert upcase(hands, "c3") == {:ok, "HI"}
  end

  describe "a harness stream (#10)" do
    # The Hold tool stands in for a provider module: the hands need only its
    # `release/3`.
    defp stream(hands, fun),
      do: :ok = Helyx.Session.Hands.stream(hands, "t1", Helyx.Test.Tool.Hold, fun)

    test "its handles are released before its terminal goes to the session", %{core: core} do
      hands = start_hands(core)
      test = self()

      stream(hands, fn ->
        Helyx.Tool.hold({:report, test})
        {:done, %{stop_reason: :end_turn, usage: %{}}}
      end)

      assert_receive {:release, :deliver, [{:report, _}]}, 2_000
      assert_receive {:stream_end, "t1", {:done, %{stop_reason: :end_turn}}}, 2_000
    end

    @tag :capture_log
    test "a crash is a task exit, and an unconfirmed handle refuses the next stream",
         %{core: core} do
      hands = start_hands(core)
      stream(hands, fn -> exit(:boom) end)
      assert_receive {:stream_end, "t1", {:error, {:task_exit, :boom}}}, 2_000

      stream(hands, fn -> Helyx.Tool.hold(:keep) end)
      assert_receive {:stream_end, "t1", {:error, text}}, 2_000
      assert text =~ "could not be released"

      stream(hands, fn -> flunk("the stream ran") end)
      assert_receive {:stream_end, "t1", {:error, text}}, 2_000
      assert text =~ "earlier call"
    end

    test "cancel kills it and releases its handles with :cancel", %{core: core} do
      hands = start_hands(core)
      test = self()

      stream(hands, fn ->
        Helyx.Tool.hold({:report, test})
        Process.sleep(60_000)
      end)

      await_held(hands, 1)
      assert cancel(hands, "t1") == :ok
      assert_received {:release, :cancel, [{:report, _}]}
      refute_receive {:stream_end, _, _}, 100
    end

    # A trapping stream Task gets the shutdown first (#11); the release
    # still comes after it is gone.
    test "cancel lets a trapping stream end by itself, then releases", %{core: core} do
      hands = start_hands(core)
      test = self()

      stream(hands, fn ->
        Process.flag(:trap_exit, true)
        Helyx.Tool.hold({:report, test})

        receive do
          {:EXIT, _from, :shutdown} -> send(test, :stopping)
        end
      end)

      await_held(hands, 1)
      assert cancel(hands, "t1") == :ok
      assert_received :stopping
      assert_received {:release, :cancel, [{:report, _}]}
    end

    test "cancel kills a trapping stream that does not end within the grace", %{core: core} do
      hands = start_hands(core)
      test = self()

      stream(hands, fn ->
        Process.flag(:trap_exit, true)
        Helyx.Tool.hold({:report, test})
        Process.sleep(60_000)
      end)

      await_held(hands, 1)
      {elapsed, :ok} = :timer.tc(fn -> cancel(hands, "t1") end, :millisecond)
      assert elapsed >= 2_000
      assert elapsed < 2_000 + @load_ms
      assert_received {:release, :cancel, [{:report, _}]}
    end
  end

  test "cancel releases with :cancel and reports an unconfirmed handle", %{core: core} do
    hands = start_hands(core)
    handles = [:keep, {:report, self()}]

    :ok =
      Helyx.Session.Hands.run(
        hands,
        "t1",
        call("c1", "hold", %{"handles" => handles, "ms" => 60_000})
      )

    await_held(hands, 1)

    assert {:error, text} = cancel(hands, "t1")
    assert text =~ "could not be released"
    assert text =~ ":keep"
    assert_received {:release, :cancel, _handles}

    assert {:error, text} = upcase(hands, "c2")
    assert text =~ "earlier call"
  end

  test "a release just under the deadline confirms its handles", %{core: core} do
    hands = start_hands(core, release_ms: 300)
    :ok = Helyx.Session.Hands.run(hands, "t1", call("c1", "hold", %{"handles" => [{:slow, 250}]}))
    assert_receive {:tool_result, "t1", "c1", {:ok, "held"}}, 2_000
    assert upcase(hands, "c2") == {:ok, "HI"}
  end

  @tag :capture_log
  test "a release just past the deadline is killed and confirms nothing", %{core: core} do
    hands = start_hands(core, release_ms: 300)
    :ok = Helyx.Session.Hands.run(hands, "t1", call("c1", "hold", %{"handles" => [{:slow, 350}]}))
    # A kill after the end of the release would confirm the handle, so the
    # error shows that the kill came first. No bound on the time is needed.
    assert_receive {:tool_result, "t1", "c1", {:error, text}}, 2_000
    assert text =~ "could not be released"

    # The release Task is gone; only the ending tool Task can be left, and
    # it ends.
    for pid <- Task.Supervisor.children(Helyx.Core.task_supervisor(core)) do
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}
    end
  end

  @tag :capture_log
  test "a retry has a deadline of one second", %{core: core} do
    # The first release times out, so both handles go to the retry.
    hands = start_hands(core, release_ms: 100)

    :ok =
      Helyx.Session.Hands.run(hands, "t1", call("c1", "hold", %{"handles" => [{:slow, 5_000}]}))

    assert_receive {:tool_result, "t1", "c1", {:error, _text}}, 3_000

    # The retry is killed at its deadline, and the call is refused.
    start = System.monotonic_time(:millisecond)
    assert {:error, text} = upcase(hands, "c2")
    assert text =~ "earlier call"
    elapsed = System.monotonic_time(:millisecond) - start
    assert elapsed >= 1_000
    assert elapsed < 1_000 + @load_ms
  end

  @tag :capture_log
  test "a release that raises, exits, or returns a bad value confirms nothing", %{core: core} do
    for handle <- [:raise, :exit, :bad, :improper] do
      hands = start_hands(core)
      :ok = Helyx.Session.Hands.run(hands, "t1", call("c1", "hold", %{"handles" => [handle]}))
      assert_receive {:tool_result, "t1", "c1", {:error, text}}, 2_000
      assert text =~ inspect(handle)
      assert {:error, text} = upcase(hands, "c2")
      assert text =~ "earlier call"
    end
  end

  test "an abort releases the handles of each tool in parallel, with one deadline",
       %{core: core} do
    hands = start_hands(core, release_ms: 1_500)
    arguments = %{"handles" => [{:slow, 1_000}], "ms" => 60_000}
    :ok = Helyx.Session.Hands.run(hands, "t1", call("c1", "hold", arguments))
    :ok = Helyx.Session.Hands.run(hands, "t1", call("c2", "hold_two", arguments))
    await_held(hands, 2)

    # One after the other, the two releases would pass the deadline.
    assert cancel(hands, "t1") == :ok
    assert upcase(hands, "c3") == {:ok, "HI"}
  end

  test "a tool without release/3 cannot hold a handle", %{core: core} do
    hands = start_hands(core)
    :ok = Helyx.Session.Hands.run(hands, "t1", call("c1", "hold_bare", %{}))
    assert_receive {:tool_result, "t1", "c1", {:error, text}}, 2_000
    assert text =~ "release/3"
    assert upcase(hands, "c2") == {:ok, "HI"}
  end

  # Waits until the hands got `n` hold calls, then until they handled them,
  # so cancel finds the handles held.
  defp await_held(hands, n) do
    for _ <- 1..n do
      assert_receive {:trace, ^hands, :receive, {:"$gen_call", {_task, _}, {:hold, _}}}
    end

    :erlang.trace(hands, false, [:receive])
    :sys.get_state(hands)
  end
end
