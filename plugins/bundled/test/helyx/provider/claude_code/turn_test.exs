defmodule Helyx.Provider.ClaudeCode.TurnTest do
  # Turns in a session: the start, the transcript, the stored id, a resume,
  # a lost session, a switch of model, an abort, and an error result.
  use ExUnit.Case, async: true

  import Helyx.Test.ClaudeCodeFake
  import Helyx.Test.Events
  import Helyx.Test.OSHelpers

  alias Helyx.{HarnessIO, Message, Session}
  alias Helyx.Provider.{ClaudeCode, Fake}

  @moduletag :tmp_dir

  setup {Helyx.Test.ClaudeCodeFake, :setup_fake}

  defp resume(ctx) do
    {:ok, session} = Session.resume(ctx.core, sessions_dir: ctx.sessions, cwd: ctx.work)
    {:ok, _, _} = Session.subscribe(session)
    session
  end

  defp resume_flag?(bin, n), do: Enum.any?(args(bin, n), &String.starts_with?(&1, "--resume"))

  # Waits for the `message_update` of a tool call.
  defp until_tool_call do
    case List.last(collect_until(:message_update)) do
      %{data: %{tool_call: _}} -> :ok
      _ -> until_tool_call()
    end
  end

  test "a program that does not start fails the start with its text cut at 2,000 bytes",
       %{work: work} do
    # A path of 3,200 bytes: the watchdog's text repeats it, so the text is
    # over the cut.
    missing = Path.join([work | List.duplicate(String.duplicate("d", 200), 16)])

    assert {:error, {:not_started, text}} = ClaudeCode.init("m", [], cwd: missing)
    assert byte_size(text) == 2_000
  end

  test "a turn: text, tool calls, and tool results join the transcript, and the id is stored",
       %{bin: bin} = ctx do
    approval = %{subtype: "can_use_tool", tool_name: "Bash", input: %{command: "ls"}}
    ask = j(%{type: "control_request", request_id: "p1", request: approval})
    other = j(%{type: "control_request", request_id: "p2", request: %{subtype: "elicitation"}})

    turn(bin, 1, 1, [
      ask,
      other
      | begin() ++
          [
            delta("I will list."),
            assistant(%{type: "text", text: "I will list."}),
            tool_use("toolu_01", %{"command" => "ls"}),
            tool_result("toolu_01", "a.txt"),
            delta("One file."),
            assistant(%{type: "text", text: "One file."}),
            result("One file.", 2)
          ]
    ])

    session = start(ctx)
    events = prompt(session, "list the files")

    assert [%{provider: "claude-code", resume_id: id, lost: false, cut: 0}] =
             of_type(events, :provider_session)

    assert "--session-id=#{id}" in args(bin, 1)
    assert "--permission-mode" in args(bin, 1)
    assert "bypassPermissions" in args(bin, 1)
    assert "--model=haiku" in args(bin, 1)
    refute "-p" in args(bin, 1)
    refute resume_flag?(bin, 1)

    # The close waits for the exit, so the program read every line.
    GenServer.stop(Session.pid(session))

    assert [
             %{
               "type" => "user",
               "uuid" => uuid,
               "message" => %{"content" => [%{"text" => "list the files"}]}
             },
             %{
               "type" => "control_response",
               "response" => %{
                 "subtype" => "success",
                 "request_id" => "p1",
                 "response" => %{"behavior" => "allow", "updatedInput" => %{"command" => "ls"}}
               }
             },
             %{
               "type" => "control_response",
               "response" => %{"subtype" => "error", "request_id" => "p2"}
             }
           ] = stdin(bin, 1)

    assert uuid =~ ~r/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/

    call = %Message.ToolCall{id: "toolu_01", name: "Bash", arguments: %{"command" => "ls"}}

    assert [
             %Message{role: :user},
             %Message{role: :assistant, stop_reason: :tool_use, model: "claude-code/haiku"} =
               first,
             %Message{role: :assistant, stop_reason: :end_turn} = last
           ] = messages(events)

    assert first.content == [%Message.Text{text: "I will list."}, call]
    assert last.content == [%Message.Text{text: "One file."}]

    assert [%{message: %Message{role: :tool_result, tool_call_id: "toolu_01", is_error: false}}] =
             of_type(events, :tool_execution_end)

    assert [%{outcome: :done}] = of_type(events, :turn_end)

    assert {:ok, %{resume_ids: %{"claude-code" => {^id, 1}}}} =
             Session.File.resume(ctx.sessions, ctx.work)
  end

  test "two turns run in one program; the session end closes it with end of input; a resumed session passes the id",
       %{bin: bin} = ctx do
    turn(bin, 1, 1, reply("Hi."))
    turn(bin, 1, 2, reply("Again."))
    File.write!(Path.join(bin, "eof.1"), ~s(echo eof > "$d/eof"\n))
    turn(bin, 2, 1, reply("Back."))

    session = start(ctx)
    [%{resume_id: id}] = of_type(prompt(session, "hello"), :provider_session)
    events = prompt(session, "again")

    assert programs(bin) == "1"
    assert [_first, %{"message" => %{"content" => [%{"text" => "again"}]}}] = stdin(bin, 1)
    assert of_type(events, :provider_session) == []
    assert Message.text(List.last(messages(events))) == "Again."

    GenServer.stop(Session.pid(session))
    assert File.read!(Path.join(bin, "eof")) == "eof\n"

    session = resume(ctx)
    prompt(session, "back")

    assert "--resume=#{id}" in args(bin, 2)
    assert [%{"message" => %{"content" => [%{"text" => "back"}]}}] = stdin(bin, 2)
  end

  test "a lost harness session starts a fresh program with the transcript replayed",
       %{bin: bin} = ctx do
    turn(bin, 1, 1, reply("Hi."))
    script(bin, "start.2", [lost(sid())], "exit 1\n")
    turn(bin, 3, 1, [init(), replayed() | reply("Fresh.")])

    session = start(ctx)
    [%{resume_id: old}] = of_type(prompt(session, "hello"), :provider_session)
    GenServer.stop(Session.pid(session))

    events = prompt(resume(ctx), "again")

    assert "--resume=#{old}" in args(bin, 2)
    refute resume_flag?(bin, 3)

    assert [
             %{
               "type" => "user",
               "shouldQuery" => false,
               "message" => %{"content" => [%{"text" => "hello"}]}
             },
             %{
               "type" => "assistant",
               "message" => %{"content" => [%{"type" => "text", "text" => "Hi."}]}
             },
             %{"type" => "user", "message" => %{"content" => [%{"text" => "again"}]}} =
               prompt_line
           ] = stdin(bin, 3)

    refute Map.has_key?(prompt_line, "shouldQuery")

    assert [%{resume_id: fresh, lost: true, cut: 0}] = of_type(events, :provider_session)
    assert fresh != old
    assert "--session-id=#{fresh}" in args(bin, 3)

    assert [%Message{role: :user}, %Message{content: [%Message.Text{text: "Fresh."}]}] =
             messages(events)

    assert {:ok, %{resume_ids: %{"claude-code" => {^fresh, 3}}}} =
             Session.File.resume(ctx.sessions, ctx.work)
  end

  test "a fresh session aborted before its first message is not resumed after a restart",
       %{bin: bin} = ctx do
    turn(bin, 1, 1, begin() ++ [delta("so far")])
    script(bin, "ctl.1", [interrupted(), aborted()])
    turn(bin, 2, 1, reply("Fresh."))

    session = start(ctx)
    :ok = Session.prompt(session, "hello")
    collect_until(:message_update)
    :ok = Session.abort(session)
    collect_until(:turn_end)
    GenServer.stop(Session.pid(session))

    prompt(resume(ctx), "last")

    assert programs(bin) == "2"
    refute resume_flag?(bin, 2)
    assert %{"message" => %{"content" => [%{"text" => "hello"} | _]}} = hd(stdin(bin, 2))
  end

  test "a switch to a claude-code model replays the history, tool calls too", %{bin: bin} = ctx do
    call = %Message.ToolCall{id: "call:1", name: "read", arguments: %{"path" => "a"}}
    :ok = Fake.script(ctx.core, "m", [[call], ["Read it."]])
    turn(bin, 1, 1, reply("Done."))

    session = start(ctx, "fake/m")
    prompt(session, "read a")
    :ok = Session.set_model(session, "claude-code/haiku")
    events = prompt(session, "and now?")

    refute resume_flag?(bin, 1)

    assert [
             %{"shouldQuery" => false, "message" => %{"content" => [%{"text" => "read a"}]}},
             %{
               "type" => "assistant",
               "message" => %{"content" => [%{"type" => "tool_use"} = use]}
             },
             %{"shouldQuery" => false, "message" => %{"content" => [result]}},
             %{"type" => "assistant", "message" => %{"content" => [%{"text" => "Read it."}]}},
             %{"message" => %{"content" => [%{"text" => "and now?"}]}}
           ] = stdin(bin, 1)

    id = HarnessIO.wire_id("call:1")
    assert "h_" <> _ = id

    assert use == %{
             "type" => "tool_use",
             "id" => id,
             "name" => "read",
             "input" => %{"path" => "a"}
           }

    assert %{"type" => "tool_result", "tool_use_id" => ^id, "is_error" => true} = result
    assert [%{lost: false, cut: 0}] = of_type(events, :provider_session)
  end

  # 4.2 of the simplification review: a replace of each character outside
  # `[a-zA-Z0-9_-]` gave `a.b` and `a:b` the one id `a_b`.
  test "two replayed calls whose ids differ only in other characters keep their own results",
       %{bin: bin} = ctx do
    calls = for id <- ["a.b", "a:b"], do: %Message.ToolCall{id: id, name: "read", arguments: %{}}
    :ok = Fake.script(ctx.core, "m", [calls, ["Read them."]])
    turn(bin, 1, 1, reply("Done."))

    session = start(ctx, "fake/m")
    prompt(session, "read")
    :ok = Session.set_model(session, "claude-code/haiku")
    prompt(session, "and now?")

    [_prompt, %{"message" => %{"content" => uses}}, %{"message" => %{"content" => results}} | _] =
      stdin(bin, 1)

    use_ids = for %{"type" => "tool_use", "id" => id} <- uses, do: id
    result_ids = for %{"type" => "tool_result", "tool_use_id" => id} <- results, do: id
    assert ["h_" <> _, "h_" <> _] = use_ids
    assert Enum.uniq(use_ids) == use_ids
    assert result_ids == use_ids
  end

  describe "an abort" do
    test "interrupts the turn with cancel_queued, and the next turn runs in the same program",
         %{bin: bin} = ctx do
      turn(
        bin,
        1,
        1,
        begin() ++ [delta("so far"), tool_use("toolu_01", %{"command" => "sleep 20"})]
      )

      script(bin, "ctl.1", [interrupted(), tool_result("toolu_01", "interrupted"), aborted()])
      turn(bin, 1, 2, reply("Next."))

      session = start(ctx)
      :ok = Session.prompt(session, "sleep")
      until_tool_call()
      :ok = Session.abort(session)
      assert [%{outcome: :aborted}] = of_type(collect_until(:turn_end), :turn_end)

      # The message with the call and its `aborted` result joined (#385).
      transcript = :sys.get_state(Session.pid(session)).transcript
      assert [:user, :assistant, :tool_result] = Enum.map(transcript, & &1.role)
      assert Helyx.Message.text(List.last(transcript)) == "aborted"

      events = prompt(session, "next")
      assert [%{outcome: :done}] = of_type(events, :turn_end)
      assert programs(bin) == "1"

      assert [
               %{"type" => "user"},
               %{
                 "type" => "control_request",
                 "request_id" => "interrupt_" <> _,
                 "request" => %{"subtype" => "interrupt", "cancel_queued" => true}
               },
               # The abort kept the message with the call and its `aborted`
               # result (#385), so the program gets only the new prompt.
               %{"type" => "user", "message" => %{"content" => [%{"text" => "next"}]}}
             ] = stdin(bin, 1)
    end

    # The program marks the TERM and then ignores it, so only the KILL
    # after the grace ends it. A stop that sent end of input first would
    # end its read loop and run `eof.1`.
    @tag :slow
    test "with work still queued stops the program with TERM after a 5,000 ms grace, and no end of input",
         %{bin: bin} = ctx do
      pidfile = Path.join(bin, "pid")

      File.write!(
        Path.join(bin, "start.1"),
        ~s(echo $$ > "#{pidfile}"\ntrap 'echo term > "$d/term"; while :; do sleep 1; done' TERM\n)
      )

      turn(bin, 1, 1, reply("Hi."))
      turn(bin, 1, 2, begin() ++ [delta("so far")])
      script(bin, "ctl.1", [interrupted(["q1"])])
      File.write!(Path.join(bin, "eof.1"), ~s(echo eof > "$d/eof"\n))
      turn(bin, 2, 1, reply("Next."))

      session = start(ctx)
      prompt(session, "hello")
      :ok = Session.prompt(session, "wait")
      collect_until(:message_update)
      pid = wait_for_pid(pidfile)

      started = System.monotonic_time(:millisecond)
      :ok = Session.abort(session)
      assert System.monotonic_time(:millisecond) - started >= 5_000
      refute os_alive?(pid)
      assert File.read!(Path.join(bin, "term")) == "term\n"
      refute File.exists?(Path.join(bin, "eof"))
      collect_until(:turn_end)

      assert [%{outcome: :done}] = of_type(prompt(session, "next"), :turn_end)
      # The abort cut the text-only partial, so the next turn replays (#432).
      refute Enum.any?(args(bin, 2), &String.starts_with?(&1, "--resume"))
    end
  end

  test "a result of a turn with no model call ends the turn", %{bin: bin, work: work} do
    turn(bin, 1, 1, begin() ++ [result("", 0)])

    assert [{:resume, _id, 0}, {:done, _}] =
             events_of(run_direct([Message.user("hi")], work))
  end

  test "an error result fails the turn, a call with no result gets an aborted one, and the program stays",
       %{bin: bin} = ctx do
    error =
      j(%{
        type: "result",
        subtype: "error_max_turns",
        is_error: true,
        num_turns: 3,
        queued_turn_count: 0,
        errors: ["too many"]
      })

    turn(
      bin,
      1,
      1,
      begin() ++
        [
          tool_use("toolu_a", %{}),
          tool_use("toolu_b", %{}),
          tool_result("toolu_a", "done"),
          error
        ]
    )

    turn(bin, 1, 2, reply("Next."))

    session = start(ctx)
    events = prompt(session, "go")

    assert [%{outcome: :error, error: {:claude_code, "error_max_turns", "too many"}}] =
             of_type(events, :turn_end)

    assert [
             %{message: %Message{tool_call_id: "toolu_a", is_error: false}},
             %{message: %Message{tool_call_id: "toolu_b", is_error: true} = aborted}
           ] = of_type(events, :tool_execution_end)

    assert Message.text(aborted) == "aborted"

    assert [%{outcome: :done}] = of_type(prompt(session, "next"), :turn_end)
    assert programs(bin) == "1"
  end
end
