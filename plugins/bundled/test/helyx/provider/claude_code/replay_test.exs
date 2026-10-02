defmodule Helyx.Provider.ClaudeCode.ReplayTest do
  # The replay of the history to a fresh program, and the checks on the
  # lines that it reads during a replay.
  use ExUnit.Case, async: true

  import Helyx.Test.ClaudeCodeFake
  import Helyx.Test.HarnessDriver

  alias Helyx.Message
  alias Helyx.Provider.ClaudeCode

  @moduletag :tmp_dir

  setup {Helyx.Test.ClaudeCodeFake, :setup_fake}

  test "a result before the start of the turn's line after a replay does not end the turn",
       %{bin: bin, work: work} do
    turn(bin, 1, 1, [init(), replay_failed() | reply("ok")])

    history = replay_history()

    assert [{:resume, _id, 0}, {:text_delta, "ok"} | _] =
             events_of(run_direct(history, work))
  end

  test "a result before the start to a program without msg_lifecycle_v1 stops it",
       %{bin: bin, work: work} do
    caps = ["interrupt_receipt_v1", "interrupt_cancel_queued_v1"]
    turn(bin, 1, 1, [init(caps), delta("program"), result("program")])

    actions = run_direct([Message.user("hi")], work)
    assert {:stop, :no_msg_lifecycle} = List.last(actions)
    assert [{:resume, _id, 0}] = events_of(actions)
  end

  # The program writes an assistant line to its session when it reads it,
  # and a user line when it takes it (research note, "The order of a
  # replay"). At each replayed user line, the fake looks for input that
  # waits already, for 1 s, with perl, and reads none of it.
  @tag :slow
  test "a replay writes the lines after a replayed user line only at its result",
       %{bin: bin, work: work} do
    early = Path.join(bin, "early")

    for q <- [1, 2] do
      File.write!(Path.join(bin, "quiet.1.#{q}"), """
      perl -MIO::Select -e 'exit(IO::Select->new(\\*STDIN)->can_read(1) ? 0 : 1)' && : > "#{early}"
      out out.quiet
      """)
    end

    turn(bin, 1, 1, reply("ok"))
    answer = &%Message{role: :assistant, content: [%Message.Text{text: &1}]}
    history = [Message.user("a"), answer.("b"), Message.user("c"), answer.("d"), answer.("e")]

    assert [{:resume, _id, 0} | _] =
             events_of(run_direct(history ++ [Message.user("x")], work))

    refute File.exists?(early)

    assert ["a", "b", "c", "d", "e", "x"] =
             for(%{"message" => %{"content" => [%{"text" => t}]}} <- stdin(bin, 1), do: t)

    assert [false, nil, false, nil, nil, nil] = Enum.map(stdin(bin, 1), & &1["shouldQuery"])
  end

  # Only the result of a replayed line writes the next chunk. After the
  # program turn's result, the fake looks for input that waits already, for
  # 1 s, with perl, and reads none of it.
  @tag :slow
  test "a program turn's result during a held replay writes no chunk",
       %{bin: bin, work: work} do
    early = Path.join(bin, "early")
    # `num_turns` 0, so only the `origin` keeps it from writing a chunk.
    program = program_result("program") |> JSON.decode!() |> Map.put("num_turns", 0) |> j()
    File.write!(Path.join(bin, "out.program"), [init(), "\n", program, "\n"])

    File.write!(Path.join(bin, "quiet.1.1"), """
    out out.program
    perl -MIO::Select -e 'exit(IO::Select->new(\\*STDIN)->can_read(1) ? 0 : 1)' && : > "#{early}"
    out out.quiet
    """)

    turn(bin, 1, 1, reply("ok"))

    assert [{:resume, _id, 0}, {:text_delta, "ok"} | _] =
             events_of(run_direct(replay_history(), work))

    refute File.exists?(early)

    assert ["a", "b", "x"] =
             for(%{"message" => %{"content" => [%{"text" => t}]}} <- stdin(bin, 1), do: t)
  end

  test "a failed replay line writes the next chunk too", %{bin: bin, work: work} do
    script(bin, "quiet.1.1", [init(), replay_failed()])
    turn(bin, 1, 1, reply("ok"))

    assert [{:resume, _id, 0}, {:text_delta, "ok"} | _] =
             events_of(run_direct(replay_history(), work))

    assert ["a", "b", "x"] =
             for(%{"message" => %{"content" => [%{"text" => t}]}} <- stdin(bin, 1), do: t)
  end

  # A program turn's error result and a failed replay result come before
  # `started` of the turn's line, so neither is the held error of #241:
  # the steer's start gives no notice.
  test "a steer during a held replay goes out after the turn's line", %{bin: bin, work: work} do
    origin = %{kind: "task-notification", producer: "session-task"}
    program = replay_failed() |> JSON.decode!() |> Map.put("origin", origin) |> j()
    script(bin, "quiet.1.1", [init(), program, replay_failed()])
    turn(bin, 1, 1, begin() ++ [delta("ok")])
    turn(bin, 1, 2, [lifecycle("started"), result("ok")])

    # The test process takes no message between the two requests, so the
    # rest of the replay is still held at the steer.
    {_from, actions, state} =
      request(harness(work), {:turn, "t1", %Helyx.Context{messages: replay_history()}})

    {_from, more, state} = request(state, {:steer, "t1", "s1", "also"})
    assert [_line] = state.turn.chunks
    {actions, _state} = pump(ClaudeCode, state, actions ++ more, &ended?/1)

    assert {:user_message, "s1", "also"} in events_of(actions)
    refute Enum.any?(events_of(actions), &match?({:notice, _}, &1))

    assert ["a", "b", "x", "also"] =
             for(%{"message" => %{"content" => [%{"text" => t}]}} <- stdin(bin, 1), do: t)
  end

  test "a replay to a program without msg_lifecycle_v1 stops it", %{bin: bin, work: work} do
    caps = ["interrupt_receipt_v1", "interrupt_cancel_queued_v1"]
    turn(bin, 1, 1, [init(caps), replayed(), init(caps), delta("ok")])

    history = replay_history()

    assert {:stop, :no_msg_lifecycle} = List.last(run_direct(history, work))
  end

  # Only an exact 0 ends the turn; a positive count keeps it open.
  for {name, count} <- [
        {"a missing", :missing},
        {"a null", nil},
        {"a string", "0"},
        {"a float", 0.0}
      ] do
    test "a result with #{name} queued_turn_count stops the program", %{bin: bin, work: work} do
      line = JSON.decode!(result("ok"))

      line =
        if unquote(count) == :missing,
          do: Map.delete(line, "queued_turn_count"),
          else: Map.put(line, "queued_turn_count", unquote(count))

      turn(bin, 1, 1, begin() ++ [j(line)])

      assert {:stop, :no_queued_turn_count} = List.last(run_direct([Message.user("hi")], work))
    end
  end

  test "a pending interrupt does not answer :ok on a result with queued work",
       %{bin: bin, work: work} do
    # No `init`: the interrupt waits, and is not written.
    queued = result("ok") |> JSON.decode!() |> Map.put("queued_turn_count", 2) |> j()
    go = Path.join(bin, "go")
    File.write!(Path.join(bin, "out.rest"), [queued, "\n", delta("more"), "\n"])
    gate = ~s(while [ ! -e "#{go}" ]; do sleep 0.05; done; out out.rest\n)
    turn(bin, 1, 1, [lifecycle("started")], gate)

    state = running(work, &(&1.turn.messages == nil))
    assert {_from, [], state} = request(state, {:interrupt, "t1"})

    # The delta after the result shows that the turn is still open.
    File.write!(go, "")
    state = settle(ClaudeCode, state, &(&1.turn != nil and &1.turn.open?))
    assert %{request_id: nil, result?: false} = state.turn.interrupt
  end

  test "a replay to a program with no init line stops it", %{bin: bin, work: work} do
    script(bin, "quiet.1.1", [replayed()])
    turn(bin, 1, 1, [lifecycle("queued"), delta("ok"), result("ok")])

    assert {:stop, :no_msg_lifecycle} = List.last(run_direct(replay_history(), work))
  end

  test "a close while a resumed program reports its session lost starts no program",
       %{bin: bin, work: work} do
    # The program reports the lost session only after the close.
    go = Path.join(bin, "go")
    gate = ~s(while [ ! -e "#{go}" ]; do sleep 0.05; done\n)
    script(bin, "start.1", [lost(sid())], "exit 1\n")
    File.write!(Path.join(bin, "start.1"), gate <> File.read!(Path.join(bin, "start.1")))

    state = harness(work, resume_id: sid())
    from = make_ref()
    assert {:ok, [], state} = ClaudeCode.request(:close, from, state)
    File.write!(go, "")
    assert {[{:reply, ^from, :ok}], _state} = pump(ClaudeCode, state, [], replied?(from))
    assert programs(bin) == "1"
  end
end
