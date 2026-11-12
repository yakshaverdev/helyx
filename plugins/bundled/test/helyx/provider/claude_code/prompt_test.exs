defmodule Helyx.Provider.ClaudeCode.PromptTest do
  # The prompt of the program and the resume check
  # (docs/features/provider-parity.md).
  use ExUnit.Case, async: true

  import Helyx.Test.ClaudeCodeFake
  import Helyx.Test.HarnessDriver
  import Helyx.Test.OSHelpers

  alias Helyx.Message
  alias Helyx.Provider.ClaudeCode

  @moduletag :tmp_dir

  setup {Helyx.Test.ClaudeCodeFake, :setup_fake}

  defp context(system, texts),
    do: %Helyx.Context{system: system, messages: Enum.map(texts, &Message.user/1)}

  defp run(state, system, texts) do
    {_from, actions, state} = request(state, {:turn, "t1", context(system, texts)})
    {_actions, state} = pump(ClaudeCode, state, actions, &ended?/1)
    state
  end

  test "a new prompt resumes the harness session in a new program with it; the same prompt keeps the program",
       %{bin: bin, work: work} do
    turn(bin, 1, 1, reply("one"))
    turn(bin, 2, 1, reply("two"))
    turn(bin, 2, 2, reply("three"))

    state = run(harness(work), "A", ["x"])
    id = state.session_id
    state = run(state, "B", ["y"])
    assert programs(bin) == "2"
    assert ("--resume=" <> id) in args(bin, 2)
    assert initialize(bin, 2) == "B"

    state = run(state, "B", ["z"])
    assert programs(bin) == "2"
    closed(state)
  end

  test "the new program starts only after the old one exited", %{bin: bin, work: work} do
    turn(bin, 1, 1, reply("one"))
    turn(bin, 2, 1, reply("two"))
    File.write!(Path.join(bin, "eof.1"), ~s(sleep 0.3; : > "$d/ended.1"\n))
    File.write!(Path.join(bin, "start.2"), ~s([ -f "$d/ended.1" ] && : > "$d/after.2"\n))

    state = run(run(harness(work), "A", ["x"]), "B", ["y"])
    closed(state)
    assert File.exists?(Path.join(bin, "after.2"))
  end

  test "the hands hold the handles of one program across relaunches", %{bin: bin, work: work} do
    for n <- 1..3, do: turn(bin, n, 1, reply("ok"))

    state = Enum.reduce(["A", "B"], harness(work), &run(&2, &1, ["x"]))
    started = System.monotonic_time(:millisecond)
    state = run(state, "C", ["x"])
    Helyx.Test.Hands.assert_one_program(state.stream.handles, started)
    assert programs(bin) == "3"
    closed(state)
  end

  # Each launch releases the groups of the program before with 500 ms
  # (`HarnessIO.let_go_ms/0`), and that release starts no kill(1) run at or
  # after its deadline. A release that passes its deadline before its probes
  # keeps the handles of the program that ended, and the next release drops
  # them (`watchdog/group_test.exs`, "a group that stays to the deadline
  # does not keep the handles of gone groups"), so the held set right after
  # a launch depends on load. The test reads what the launches cannot leave
  # behind: no group of a program that ended still runs, and a release with
  # room confirms every group, the one that ignores TERM too, and keeps no
  # handle.
  @tag :slow
  test "a group that ignores TERM does not keep the handles of the later programs",
       %{bin: bin, work: work} do
    for n <- 1..4, do: turn(bin, n, 1, reply("ok"))
    stuck = Path.join(bin, "stuck.pid")

    on_exit(fn ->
      with {:ok, pid} <- File.read(stuck),
           do: System.cmd("kill", ["-KILL", String.trim(pid)], stderr_to_stdout: true)
    end)

    File.write!(Path.join(bin, "eof.1"), """
    (trap '' TERM; exec sleep 60) </dev/null >/dev/null 2>&1 &
    echo $! > "$d/stuck.pid"
    """)

    state = Enum.reduce(["A", "B", "C", "D"], harness(work), &run(&2, &1, ["x"]))
    assert programs(bin) == "4"
    assert File.exists?(stuck)

    # The hands hold the handles of the provider state, the ones of the
    # programs that ended that a release could not confirm included.
    assert Enum.sort(Helyx.Test.Hands.held()) == Enum.sort(state.stream.handles)

    # The stuck child and the program of the last turn are the groups that
    # still run: no launch kept a group of an earlier program alive.
    live = for {_, group, _} = handle <- state.stream.handles, os_alive?("-#{group}"), do: handle
    assert [{:command, _, _}, {:command, _, _}, {:watchdog, _, _}] = Enum.sort(live)

    # A release with the deadline of the hands confirms every group, the one
    # that ignores TERM too, and keeps no handle.
    until = System.monotonic_time(:millisecond) + Helyx.Session.Hands.State.release_ms()
    assert ClaudeCode.release(state.stream.handles, :deliver, until) == []

    closed(state)
  end

  # The wait for the exit is 1,000 ms (`HarnessIO.finish/1`).
  @tag :slow
  test "an old program that does not exit fails the turn", %{bin: bin, work: work} do
    turn(bin, 1, 1, reply("one"))
    File.write!(Path.join(bin, "eof.1"), "sleep 3\n")

    state = run(harness(work), "A", ["x"])

    assert {_from, [{:reply, _, {:error, :program_not_ended}}], _state} =
             request(state, {:turn, "t1", context("B", ["y"])})

    assert programs(bin) == "1"
  end

  test "the usage of a stored session that is not resumed is no cost mark", %{work: work} do
    usage = %Helyx.Usage{cost: 0.1}
    assert harness(work, resume_id: sid(), resume_usage: usage).meter == harness(work).meter
    assert harness(work, resume_id: stored(sid()), resume_usage: usage).meter.mark == 0.1
  end

  test "a stored id with another digest, or with none, starts a fresh harness session",
       %{work: work} do
    stored = stored(sid())
    assert harness(work, resume_id: stored).resume == sid()

    for other <- [sid(), sid() <> "#0000000000000000"],
        do: assert(harness(work, resume_id: other).resume == nil)
  end

  test "an error answer to initialize stops the provider with its text", %{bin: bin, work: work} do
    assert {:stop, %Helyx.ProviderError{kind: :initialize} = reason} =
             initialize_stop(bin, work, %{error: "bad"})

    # The provider process stops with it, and the user reads its text.
    assert Helyx.Reason.text({:provider_stop, reason}) == "claude-code: bad"
  end

  test "an error answer to initialize with no text stops the provider with its term",
       %{bin: bin, work: work} do
    assert {:stop, {:initialize, ""}} = initialize_stop(bin, work, %{})
  end

  defp initialize_stop(bin, work, error) do
    response = Map.merge(%{subtype: "error", request_id: "initialize"}, error)

    File.write!(Path.join(bin, "out.init"), [
      j(%{type: "control_response", response: response}),
      "\n"
    ])

    File.write!(Path.join(bin, "init.1"), "out out.init\n")

    {_from, actions, state} = request(harness(work), {:turn, "t1", context("A", ["x"])})
    {actions, _state} = pump(ClaudeCode, state, actions, &ended?/1)
    List.last(actions)
  end

  test "a compaction of a stored session starts its program with the empty prompt",
       %{bin: bin, work: work} do
    state = harness(work, resume_id: stored(sid()))
    {_from, _actions, state} = request(state, {:compact, "t1", ""})
    # The close waits for the exit, so the program wrote its files.
    closed(state)
    assert ("--resume=" <> sid()) in args(bin, 1)
    refute "--disable-slash-commands" in args(bin, 1)
    assert initialize(bin, 1) == ""
  end
end
