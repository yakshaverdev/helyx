defmodule Helyx.Provider.ClaudeCode.PromptTest do
  # The prompt of the program and the resume check
  # (docs/features/provider-parity.md).
  use ExUnit.Case, async: true

  import Helyx.Test.ClaudeCodeFake
  import Helyx.Test.HarnessDriver

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
    response = %{subtype: "error", request_id: "initialize", error: "bad"}

    File.write!(Path.join(bin, "out.init"), [
      j(%{type: "control_response", response: response}),
      "\n"
    ])

    File.write!(Path.join(bin, "init.1"), "out out.init\n")

    {_from, actions, state} = request(harness(work), {:turn, "t1", context("A", ["x"])})
    {actions, _state} = pump(ClaudeCode, state, actions, &ended?/1)
    assert {:stop, {:initialize, "bad"}} = List.last(actions)
  end

  test "a compaction of a stored session starts its program with the empty prompt",
       %{bin: bin, work: work} do
    state = harness(work, resume_id: stored(sid()))
    {_from, _actions, state} = request(state, {:compact, "t1", ""})
    # The close waits for the exit, so the program wrote its files.
    closed(state)
    assert ("--resume=" <> sid()) in args(bin, 1)
    assert initialize(bin, 1) == ""
  end
end
