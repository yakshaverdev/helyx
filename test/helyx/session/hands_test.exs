defmodule Helyx.Session.HandsTest do
  # The hands' handle bookkeeping, driven directly with the test process as
  # the session. The hold test tools release, keep, or fail on the handles
  # they get, so no OS resource is needed.
  use ExUnit.Case, async: true

  import Helyx.Test.Events, only: [wait_ms: 0]

  alias Helyx.Message.ToolCall
  alias Helyx.Test.Gate

  # Room for scheduler load in a check of a wait that must not happen: far
  # above the delays that load makes, far below the release of 60,000 ms
  # that the check rules out.
  @load_ms 5_000

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
    assert_receive {:tool_result, "t1", ^id, result}
    result
  end

  test "an unconfirmed handle gives an error result and blocks calls until a retry releases it",
       %{core: core} do
    {:ok, agent} = Agent.start_link(fn -> true end)
    hands = start_hands(core)
    handles = [{:keep, agent}, {:report, self()}]

    :ok = Helyx.Session.Hands.run(hands, "t1", call("c1", "hold", %{"handles" => handles}))
    assert_receive {:tool_result, "t1", "c1", {:error, text}}
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

  test "cancel releases with :cancel and reports an unconfirmed handle", %{core: core} do
    hands = start_hands(core)
    handles = [:keep, {:report, self()}]

    :ok =
      Helyx.Session.Hands.run(
        hands,
        "t1",
        call("c1", "hold", %{"handles" => handles, "ms" => 60_000})
      )

    # The tool holds its two handles in two calls; a cancel between them
    # releases only the first.
    await_held(hands, 2)

    assert {:error, text} = cancel(hands, "t1")
    assert text =~ "could not be released"
    assert text =~ ":keep"
    assert_received {:release, :cancel, _handles}

    assert {:error, text} = upcase(hands, "c2")
    assert text =~ "earlier call"
  end

  # The release ends 1,750 ms before its deadline: room for load.
  test "a release before the deadline confirms its handles", %{core: core} do
    hands = start_hands(core, release_ms: 2_000)
    :ok = Helyx.Session.Hands.run(hands, "t1", call("c1", "hold", %{"handles" => [{:slow, 250}]}))
    assert_receive {:tool_result, "t1", "c1", {:ok, "held"}}
    assert upcase(hands, "c2") == {:ok, "HI"}
  end

  @tag :capture_log
  test "a release past the deadline is killed and confirms nothing", %{core: core} do
    hands = start_hands(core, release_ms: 300)

    :ok =
      Helyx.Session.Hands.run(hands, "t1", call("c1", "hold", %{"handles" => [{:slow, 60_000}]}))

    # A kill after the end of the release would confirm the handle, so the
    # error shows that the kill came first. No bound on the time is needed.
    assert_receive {:tool_result, "t1", "c1", {:error, text}}
    assert text =~ "could not be released"

    # The release Task is gone; only the ending tool Task can be left, and
    # it ends.
    for pid <- Task.Supervisor.children(Helyx.Core.task_supervisor(core)) do
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}
    end
  end

  @tag :capture_log
  @tag :slow
  test "a retry has a deadline of one second", %{core: core} do
    # The first release times out, so both handles go to the retry.
    hands = start_hands(core, release_ms: 100)

    :ok =
      Helyx.Session.Hands.run(hands, "t1", call("c1", "hold", %{"handles" => [{:slow, 60_000}]}))

    # The release takes longer than any wait of the test, so the error comes
    # from the timeout of the release.
    assert_receive {:tool_result, "t1", "c1", {:error, _text}}

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
      assert_receive {:tool_result, "t1", "c1", {:error, text}}
      assert text =~ inspect(handle)
      assert {:error, text} = upcase(hands, "c2")
      assert text =~ "earlier call"
    end
  end

  test "an abort releases the handles of each tool in parallel", %{core: core} do
    hands = start_hands(core)
    arguments = %{"handles" => [%{"gate" => Gate.open()}], "ms" => 60_000}
    :ok = Helyx.Session.Hands.run(hands, "t1", call("c1", "hold", arguments))
    :ok = Helyx.Session.Hands.run(hands, "t1", call("c2", "hold_two", arguments))
    await_held(hands, 2)

    # One after the other, the second release would start only after the
    # first got :go.
    cancel = Task.async(fn -> cancel(hands, "t1") end)
    assert_receive {:waiting, first}
    assert_receive {:waiting, second}
    send(first, :go)
    send(second, :go)
    assert Task.await(cancel, wait_ms()) == :ok
    assert upcase(hands, "c3") == {:ok, "HI"}
  end

  test "a tool without release/3 cannot hold a handle", %{core: core} do
    hands = start_hands(core)
    :ok = Helyx.Session.Hands.run(hands, "t1", call("c1", "hold_bare", %{}))
    assert_receive {:tool_result, "t1", "c1", {:error, text}}
    assert text =~ "release/3"
    assert upcase(hands, "c2") == {:ok, "HI"}
  end

  # Waits until the hands got `n` hold calls, then until they handled them,
  # and asserts that they hold the handles, so cancel finds them.
  defp await_held(hands, n) do
    for _ <- 1..n do
      assert_receive {:trace, ^hands, :receive, {:"$gen_call", {_task, _}, {:hold, _}}}
    end

    :erlang.trace(hands, false, [:receive])
    assert :sys.get_state(hands).held |> Map.values() |> List.flatten() |> length() >= n
  end
end
