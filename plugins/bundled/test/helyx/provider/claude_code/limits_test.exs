defmodule Helyx.Provider.ClaudeCode.LimitsTest do
  # The bounds: a tool result, the replay cap, the line cap, the error
  # text, and a shutdown behind queued output.
  use ExUnit.Case, async: true

  import Helyx.Test.ClaudeCodeFake
  import Helyx.Test.HarnessDriver
  import Helyx.Test.OSHelpers

  alias Helyx.Message
  alias Helyx.Provider.ClaudeCode

  @moduletag :tmp_dir

  setup {Helyx.Test.ClaudeCodeFake, :setup_fake}

  test "a tool result over the limits arrives cut, with the notice", %{bin: bin, work: work} do
    big = String.duplicate("x\n", 3_000)

    turn(
      bin,
      1,
      1,
      begin() ++
        [
          tool_use("toolu_01", %{"command" => "seq"}),
          tool_result("toolu_01", big),
          result("Done.", 2)
        ]
    )

    assert [text] =
             for({:tool_result, "toolu_01", {:ok, t}} <- events_of(run_direct([], work)), do: t)

    assert text == Helyx.Text.truncate(big, :tail)
    assert text =~ "[truncated: showing lines 1001-3000 of 3000]"
  end

  describe "the replay cap" do
    test "keeps the newest messages within 400,000 bytes and never starts at a result",
         %{bin: bin, work: work} do
      turn(bin, 1, 1, reply("ok"))
      big = String.duplicate("x", 150_000)
      call = %Message.ToolCall{id: "c1", name: "bash", arguments: %{}}

      messages = [
        Message.user(big),
        %Message{role: :assistant, content: [%Message.Text{text: big}]},
        Message.user("run it"),
        %Message{role: :assistant, content: [call]},
        Message.tool_result(call, {:ok, big}),
        %Message{role: :assistant, content: [%Message.Text{text: big}]},
        Message.user("next")
      ]

      assert [{:harness_session, _id, 2} | _] = events_of(run_direct(messages, work))

      assert [
               %{"message" => %{"content" => [%{"text" => "run it"}]}},
               %{"type" => "assistant"},
               %{"message" => %{"content" => [%{"type" => "tool_result"}]}},
               %{"type" => "assistant"},
               %{"message" => %{"content" => [%{"text" => "next"}]}}
             ] = stdin(bin, 1)
    end

    @tag :slow
    test "history lines of exactly 400,000 bytes all go; one byte more cuts",
         %{bin: bin, work: work} do
      # The line sizes come from the same shapes the provider encodes.
      size = fn map -> byte_size(j(map)) + 1 end
      user = String.duplicate("é", 1_000)

      user_line =
        size.(%{
          type: "user",
          shouldQuery: false,
          message: %{role: "user", content: [%{type: "text", text: user}]}
        })

      assistant = fn text ->
        size.(%{
          type: "assistant",
          message: %{role: "assistant", content: [%{type: "text", text: text}]}
        })
      end

      fill = 400_000 - user_line - (assistant.("x") - 1)

      turn(bin, 1, 1, reply("ok"))

      # Each case is program 1 of the fake again.
      for {extra, cut} <- [{-1, 0}, {0, 0}, {1, 1}] do
        File.rm(Path.join(bin, "count"))
        text = String.duplicate("x", fill + extra)
        assert assistant.(text) + user_line == 400_000 + extra

        messages = [
          Message.user(user),
          %Message{role: :assistant, content: [%Message.Text{text: text}]},
          Message.user("next")
        ]

        assert [{:harness_session, _id, ^cut} | _] = events_of(run_direct(messages, work))
        assert length(stdin(bin, 1)) == 3 - cut
      end
    end

    test "a cut that lands after a tool call drops its result too", %{bin: bin, work: work} do
      turn(bin, 1, 1, reply("ok"))

      call = %Message.ToolCall{
        id: "c1",
        name: "bash",
        arguments: %{"x" => String.duplicate("z", 100_000)}
      }

      messages = [
        Message.user("go"),
        %Message{role: :assistant, content: [call]},
        Message.tool_result(call, {:ok, String.duplicate("y", 100_000)}),
        %Message{
          role: :assistant,
          content: [%Message.Text{text: String.duplicate("w", 250_000)}]
        },
        Message.user("next")
      ]

      assert [{:harness_session, _id, 3} | _] = events_of(run_direct(messages, work))

      assert [%{"type" => "assistant"}, %{"message" => %{"content" => [%{"text" => "next"}]}}] =
               stdin(bin, 1)
    end
  end

  @tag :slow
  test "lines of 16 MiB and one byte under are read", %{bin: bin, work: work} do
    turn(bin, 1, 1, reply("ok"))

    for bytes <- [16_777_215, 16_777_216] do
      File.rm(Path.join(bin, "count"))

      File.write!(
        Path.join(bin, "turn.1.1"),
        ~s(head -c #{bytes} /dev/zero | tr '\\0' 'x'; echo; out out.turn.1.1\n)
      )

      assert [{:harness_session, _id, 0}, {:text_delta, "ok"}, {:done, _}] =
               events_of(run_direct([Message.user("hi")], work))
    end
  end

  test "a line one byte over 16 MiB with its newline in one write stops the provider",
       %{bin: bin, work: work} do
    File.write!(Path.join(bin, "line"), [String.duplicate("x", 16_777_217), "\n"])
    File.write!(Path.join(bin, "turn.1.1"), ~s(cat "$d/line"\n))

    assert {:stop, {:line_over_limit, 16_777_216}} =
             List.last(run_direct([Message.user("hi")], work))
  end

  @tag :slow
  test "a line over 16 MiB stops the provider", %{bin: bin, work: work} do
    File.write!(Path.join(bin, "turn.1.1"), ~s(head -c 16777217 /dev/zero | tr '\\0' 'x'\n))

    assert {:stop, {:line_over_limit, 16_777_216}} =
             List.last(run_direct([Message.user("hi")], work))
  end

  test "the program's error text and subtype are cut at 2,000 bytes, not in a character",
       %{bin: bin, work: work} do
    long = "a" <> String.duplicate("é", 1_000)

    # {text of the errors and of the subtype, bytes kept of each}
    for {text, want} <- [
          {String.duplicate("a", 1_999), 1_999},
          {String.duplicate("a", 2_000), 2_000},
          {String.duplicate("a", 2_001), 2_000},
          {long, 1_999}
        ] do
      File.rm(Path.join(bin, "count"))

      error =
        j(%{
          type: "result",
          subtype: text,
          is_error: true,
          num_turns: 1,
          queued_turn_count: 0,
          errors: [text]
        })

      turn(bin, 1, 1, begin() ++ [error])

      assert [_, {:error, {:claude_code, subtype, text}}] =
               events_of(run_direct([Message.user("hi")], work))

      assert {byte_size(text), byte_size(subtype)} == {want, want}
      assert String.valid?(text) and String.valid?(subtype)
    end
  end

  # The line cap bounds each line, not the number of lines in the mailbox
  # (#167). The program writes 1,000 JSON lines of 64 KB while the harness
  # process is suspended, so they are all queued before the shutdown. Their
  # decode, 1.5 ms a line, takes longer than the 1,000 ms wait for the
  # `:DOWN` (the test fails on code that traps exits), and load only makes
  # it longer. The right code ends at once, so the 1,000 ms are the margin
  # for load.
  @load_down_ms 1_000

  test "a shutdown behind queued stdout ends the harness process at once",
       %{bin: bin, work: work, tmp_dir: tmp} do
    line = j(%{type: "other", pad: List.duplicate(1, 32_768)})
    File.write!(Path.join(bin, "lines"), List.duplicate([line, "\n"], 1_000))
    ready = Path.join(tmp, "ready")
    go = Path.join(tmp, "go")
    written = Path.join(tmp, "written")

    File.write!(
      Path.join(bin, "turn.1.1"),
      ~s(echo $$ > "#{ready}"\nwhile [ ! -e "#{go}" ]; do sleep 0.05; done\n) <>
        ~s(cat "$d/lines"\necho $$ > "#{written}"\nsleep 30\n)
    )

    test = self()

    {pid, ref} =
      spawn_monitor(fn ->
        Process.put(:helyx_hands, test)

        {_from, actions, state} =
          request(harness(work), {:turn, "t1", %Helyx.Context{messages: [Message.user("hi")]}})

        pump(ClaudeCode, state, actions, fn _ -> false end)
      end)

    for _hold <- 1..2 do
      assert_receive {:"$gen_call", from, {:hold, _handle}}
      GenServer.reply(from, :ok)
    end

    program = wait_for_pid(ready)
    :erlang.suspend_process(pid)
    File.write!(go, "")
    wait_for_pid(written)
    Process.exit(pid, :shutdown)
    :erlang.resume_process(pid)

    assert_receive {:DOWN, ^ref, :process, _pid, :shutdown}, @load_down_ms
    # The keeper closes the port, so the watchdog ends the group.
    assert group_gone_within?(program)
  end
end
