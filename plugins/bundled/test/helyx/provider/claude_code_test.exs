defmodule Helyx.Provider.ClaudeCodeTest do
  # A fake `claude` on PATH reads stream-json lines, as the long-lived
  # program does, and answers in the shapes that
  # `docs/research/claude-code-stream-json.md` records. Program N saves its
  # arguments to `args.N` and each input line to `stdin.N`. It runs
  # `start.N` first; for the K-th user line that starts a query it runs
  # `turn.N.K`, for a control request `ctl.N`, for a control response
  # `resp.N`, and at the end of input `eof.N`. In their output `@U@` is the `uuid` and `@R@` the
  # `request_id` of the line read. PATH is global, so this module is not
  # async.
  use ExUnit.Case, async: false

  import Helyx.Test.OSHelpers

  alias Helyx.{Event, Message, Session}
  alias Helyx.Provider.{ClaudeCode, Fake}

  @sid "4b3c2d1e-0000-4000-8000-000000000001"

  @fake """
  #!/bin/sh
  d=$(dirname "$0")
  n=$(( $(cat "$d/count" 2>/dev/null || echo 0) + 1 ))
  echo $n > "$d/count"
  for a in "$@"; do printf '%s\\n' "$a"; done > "$d/args.$n"
  : > "$d/stdin.$n"
  out() { sed "s/@U@/$u/g; s/@R@/$r/g" "$d/$1"; }
  u=; r=
  [ -f "$d/start.$n" ] && . "$d/start.$n"
  k=0
  while IFS= read -r line; do
    printf '%s\\n' "$line" >> "$d/stdin.$n"
    v=$(printf '%s\\n' "$line" | sed -n 's/.*"uuid":"\\([^"]*\\)".*/\\1/p')
    [ -n "$v" ] && u=$v
    r=$(printf '%s\\n' "$line" | sed -n 's/.*"request_id":"\\([^"]*\\)".*/\\1/p')
    case "$line" in
      *'"type":"control_response"'*) [ -f "$d/resp.$n" ] && . "$d/resp.$n" ;;
      *'"shouldQuery":false'*|*'"type":"assistant"'*) ;;
      *'"type":"control_request"'*) [ -f "$d/ctl.$n" ] && . "$d/ctl.$n" ;;
      *'"type":"user"'*) k=$((k+1)); [ -f "$d/turn.$n.$k" ] && . "$d/turn.$n.$k" ;;
    esac
  done
  [ -f "$d/eof.$n" ] && . "$d/eof.$n"
  """

  setup %{tmp_dir: tmp} do
    bin = Path.join(tmp, "bin")
    File.mkdir_p!(bin)
    File.write!(Path.join(bin, "claude"), @fake)
    File.chmod!(Path.join(bin, "claude"), 0o755)
    path = System.get_env("PATH")
    System.put_env("PATH", bin <> ":" <> path)
    on_exit(fn -> System.put_env("PATH", path) end)

    core = :"core_#{System.unique_integer([:positive])}"
    start_supervised!({Helyx.Core, name: core, plugins: [ClaudeCode, Fake]})
    work = Path.join(tmp, "work")
    File.mkdir_p!(work)
    %{core: core, bin: bin, work: work, sessions: Path.join(tmp, "sessions")}
  end

  # Stream-json lines

  defp j(map), do: JSON.encode!(map)

  @caps ["interrupt_receipt_v1", "interrupt_cancel_queued_v1", "msg_lifecycle_v1"]

  defp init(caps \\ @caps) do
    j(%{
      type: "system",
      subtype: "init",
      session_id: @sid,
      cwd: "/work",
      model: "claude-haiku-4-5-20251001",
      tools: ["Bash", "Read"],
      capabilities: caps,
      uuid: "u1"
    })
  end

  defp lifecycle(state),
    do: j(%{type: "command_lifecycle", state: state, command_uuid: "@U@", session_id: @sid})

  defp delta(text) do
    j(%{
      type: "stream_event",
      event: %{type: "content_block_delta", index: 0, delta: %{type: "text_delta", text: text}},
      session_id: @sid,
      parent_tool_use_id: nil,
      uuid: "u2"
    })
  end

  defp assistant(block) do
    j(%{
      type: "assistant",
      message: %{
        id: "msg_1",
        type: "message",
        role: "assistant",
        model: "claude-haiku-4-5-20251001",
        content: [block],
        stop_reason: nil,
        usage: %{input_tokens: 12, output_tokens: 7}
      },
      parent_tool_use_id: nil,
      session_id: @sid,
      uuid: "u3"
    })
  end

  defp tool_use(id, input), do: assistant(%{type: "tool_use", id: id, name: "Bash", input: input})

  defp tool_result(id, content) do
    j(%{
      type: "user",
      message: %{
        role: "user",
        content: [%{tool_use_id: id, type: "tool_result", content: content}]
      },
      parent_tool_use_id: nil,
      session_id: @sid,
      uuid: "u4",
      tool_use_result: %{stdout: content}
    })
  end

  defp result(text, num_turns \\ 1) do
    j(%{
      type: "result",
      subtype: "success",
      is_error: false,
      result: text,
      stop_reason: if(num_turns > 0, do: "end_turn"),
      num_turns: num_turns,
      terminal_reason: "completed",
      queued_turn_count: 0,
      usage: %{input_tokens: 12, output_tokens: 7},
      session_id: @sid
    })
  end

  # The result of a replayed line: no model call and no `terminal_reason`.
  defp replayed do
    j(%{
      type: "result",
      subtype: "success",
      is_error: false,
      result: "",
      num_turns: 0,
      session_id: @sid
    })
  end

  defp replay_failed,
    do: j(%{type: "result", subtype: "error_during_execution", is_error: true, num_turns: 0})

  # A history that the first turn of a fresh program replays before "x".
  defp replay_history do
    [
      Message.user("a"),
      %Message{role: :assistant, content: [%Message.Text{text: "b"}]},
      Message.user("x")
    ]
  end

  defp aborted do
    j(%{
      type: "result",
      subtype: "error_during_execution",
      is_error: true,
      num_turns: 2,
      terminal_reason: "aborted_tools",
      queued_turn_count: 0,
      errors: [],
      session_id: @sid
    })
  end

  defp lost(sid) do
    j(%{
      type: "result",
      subtype: "error_during_execution",
      is_error: true,
      num_turns: 0,
      session_id: sid,
      errors: ["No conversation found with session ID: #{sid}"]
    })
  end

  defp interrupted(still_queued \\ [], cancelled \\ []) do
    j(%{
      type: "control_response",
      response: %{
        subtype: "success",
        request_id: "@R@",
        response: %{still_queued: still_queued, cancelled: cancelled}
      }
    })
  end

  # The start of a turn: the program took the line.
  defp begin, do: [lifecycle("queued"), lifecycle("started"), init()]

  # A reply of one text, as the program streams it.
  defp reply(text),
    do: begin() ++ [delta(text), assistant(%{type: "text", text: text}), result(text)]

  # The fake's scripts: output lines, then `tail` as shell code.
  defp script(bin, name, lines, tail \\ "") do
    File.write!(Path.join(bin, "out.#{name}"), Enum.map(lines, &[&1, "\n"]))
    File.write!(Path.join(bin, name), "out out.#{name}\n" <> tail)
  end

  defp turn(bin, n, k, lines, tail \\ ""), do: script(bin, "turn.#{n}.#{k}", lines, tail)

  defp args(bin, n),
    do: bin |> Path.join("args.#{n}") |> File.read!() |> String.split("\n", trim: true)

  defp stdin(bin, n) do
    bin
    |> Path.join("stdin.#{n}")
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&JSON.decode!/1)
  end

  defp programs(bin), do: bin |> Path.join("count") |> File.read!() |> String.trim()

  # The provider without a session: the test process runs the callbacks,
  # as the harness loop does.

  defp harness(work, opts \\ []) do
    {:ok, state} = ClaudeCode.harness_init("haiku", [], [cwd: work] ++ opts)
    state
  end

  defp request(state, request) do
    from = make_ref()
    {:ok, actions, state} = ClaudeCode.harness_request(request, from, state)
    {from, actions, state}
  end

  # Gives each message of the test process to `harness_info/2` until
  # `done?` holds for the actions so far, or the provider stops.
  defp pump(state, actions, done?) do
    if done?.(actions) do
      {actions, state}
    else
      receive do
        message ->
          case ClaudeCode.harness_info(message, state) do
            {:ok, more, state} -> pump(state, actions ++ more, done?)
            {:stop, reason, state} -> {actions ++ [{:stop, reason}], state}
          end
      after
        5_000 -> flunk("no end; got #{inspect(actions)}")
      end
    end
  end

  defp ended?(actions) do
    Enum.any?(actions, fn
      {:event, _turn, {kind, _}} -> kind in [:done, :error]
      {:stop, _reason} -> true
      _ -> false
    end)
  end

  defp replied?(from), do: &Enum.any?(&1, fn action -> match?({:reply, ^from, _}, action) end)

  # One turn of a new program: its actions, with its stop, if any, last.
  defp run_direct(messages, work) do
    {_from, actions, state} =
      request(harness(work), {:turn, "t1", %Helyx.Context{messages: messages}})

    {actions, _state} = pump(state, actions, &ended?/1)
    actions
  end

  defp events_of(actions), do: for({:event, _turn, event} <- actions, do: event)

  # Sessions

  defp collect_until(type, acc \\ []) do
    receive do
      {:helyx_event, %Event{type: ^type} = event} -> Enum.reverse([event | acc])
      {:helyx_event, %Event{} = event} -> collect_until(type, [event | acc])
    after
      5_000 -> flunk("timed out waiting for #{type}; got #{inspect(Enum.reverse(acc))}")
    end
  end

  defp start(ctx, model \\ "claude-code/haiku") do
    {:ok, session} =
      Session.start(ctx.core, model: model, cwd: ctx.work, sessions_dir: ctx.sessions)

    {:ok, _} = Session.subscribe(session)
    session
  end

  defp resume(ctx) do
    {:ok, session} = Session.resume(ctx.core, sessions_dir: ctx.sessions, cwd: ctx.work)
    {:ok, _} = Session.subscribe(session)
    session
  end

  defp prompt(session, text) do
    :ok = Session.prompt(session, text)
    collect_until(:agent_end)
  end

  defp messages(events), do: for(%Event{type: :message_end, data: %{message: m}} <- events, do: m)
  defp of_type(events, type), do: for(%Event{type: ^type, data: data} <- events, do: data)

  # Polls until the session let go of its ended harness process.
  defp wait_for_no_harness(pid, tries \\ 500) do
    cond do
      :sys.get_state(pid).harness == nil -> :ok
      tries == 0 -> flunk("the session still holds its harness process")
      true -> Process.sleep(10) && wait_for_no_harness(pid, tries - 1)
    end
  end

  defp resume_flag?(bin, n), do: Enum.any?(args(bin, n), &String.starts_with?(&1, "--resume"))

  @moduletag :tmp_dir

  # A margin for load on a timer that the test reads.
  @load_ms 2_000

  # The setup restores PATH.
  test "with no perl on PATH, the start returns an error that names perl",
       %{bin: bin, work: work} do
    System.put_env("PATH", bin)

    assert {:error, "perl not found" <> _} = ClaudeCode.harness_init("m", [], cwd: work)
  end

  test "a program that does not start fails the start with its text cut at 2,000 bytes",
       %{work: work} do
    # A path of 3,200 bytes: the watchdog's text repeats it, so the text is
    # over the cut.
    missing = Path.join([work | List.duplicate(String.duplicate("d", 200), 16)])

    assert {:error, {:not_started, text}} = ClaudeCode.harness_init("m", [], cwd: missing)
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

    assert [%{provider: "claude-code", harness_session_id: id, lost: false, cut: 0}] =
             of_type(events, :harness_session)

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
    assert [%{tool_call: ^call}] = of_type(events, :tool_execution_start)

    assert [%{message: %Message{role: :tool_result, tool_call_id: "toolu_01", is_error: false}}] =
             of_type(events, :tool_execution_end)

    assert [%{stop_reason: :end_turn}] = of_type(events, :agent_end)

    assert {:ok, %{harness_sessions: %{"claude-code" => {^id, 1}}}} =
             Session.File.resume(ctx.sessions, ctx.work)
  end

  test "two turns run in one program; the session end closes it with end of input; a resumed session passes the id",
       %{bin: bin} = ctx do
    turn(bin, 1, 1, reply("Hi."))
    turn(bin, 1, 2, reply("Again."))
    File.write!(Path.join(bin, "eof.1"), ~s(echo eof > "$d/eof"\n))
    turn(bin, 2, 1, reply("Back."))

    session = start(ctx)
    [%{harness_session_id: id}] = of_type(prompt(session, "hello"), :harness_session)
    events = prompt(session, "again")

    assert programs(bin) == "1"
    assert [_first, %{"message" => %{"content" => [%{"text" => "again"}]}}] = stdin(bin, 1)
    assert of_type(events, :harness_session) == []
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
    script(bin, "start.2", [lost(@sid)], "exit 1\n")
    turn(bin, 3, 1, [init(), replayed() | reply("Fresh.")])

    session = start(ctx)
    [%{harness_session_id: old}] = of_type(prompt(session, "hello"), :harness_session)
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

    assert [%{harness_session_id: fresh, lost: true, cut: 0}] = of_type(events, :harness_session)
    assert fresh != old
    assert "--session-id=#{fresh}" in args(bin, 3)

    assert [%Message{role: :user}, %Message{content: [%Message.Text{text: "Fresh."}]}] =
             messages(events)

    assert {:ok, %{harness_sessions: %{"claude-code" => {^fresh, 3}}}} =
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
    collect_until(:agent_end)
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

    assert use == %{
             "type" => "tool_use",
             "id" => "call_1",
             "name" => "read",
             "input" => %{"path" => "a"}
           }

    assert %{"type" => "tool_result", "tool_use_id" => "call_1", "is_error" => true} = result
    assert [%{lost: false, cut: 0}] = of_type(events, :harness_session)
  end

  # Gives messages to `harness_info/2` until `done?` holds for the state.
  defp settle(state, done?) do
    if done?.(state) do
      state
    else
      receive do
        message ->
          {:ok, _actions, state} = ClaudeCode.harness_info(message, state)
          settle(state, done?)
      after
        5_000 -> flunk("no such state; got #{inspect(state)}")
      end
    end
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
      collect_until(:message_update)
      :ok = Session.abort(session)
      assert [%{stop_reason: :aborted}] = of_type(collect_until(:agent_end), :agent_end)

      events = prompt(session, "next")
      assert [%{stop_reason: :end_turn}] = of_type(events, :agent_end)
      assert programs(bin) == "1"

      assert [
               %{"type" => "user"},
               %{
                 "type" => "control_request",
                 "request_id" => "interrupt_" <> _,
                 "request" => %{"subtype" => "interrupt", "cancel_queued" => true}
               },
               # The aborted turn left no assistant message, so its prompt
               # is still at the end of the transcript.
               %{
                 "type" => "user",
                 "message" => %{"content" => [%{"text" => "sleep"}, %{"text" => "next"}]}
               }
             ] = stdin(bin, 1)
    end

    # The program marks the TERM and then ignores it, so only the KILL
    # after the grace ends it. A stop that sent end of input first would
    # end its read loop and run `eof.1`.
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
      [%{harness_session_id: id}] = of_type(prompt(session, "hello"), :harness_session)
      :ok = Session.prompt(session, "wait")
      collect_until(:message_update)
      pid = wait_for_pid(pidfile)

      started = System.monotonic_time(:millisecond)
      :ok = Session.abort(session)
      assert System.monotonic_time(:millisecond) - started >= 5_000
      refute os_alive?(pid)
      assert File.read!(Path.join(bin, "term")) == "term\n"
      refute File.exists?(Path.join(bin, "eof"))
      collect_until(:agent_end)

      assert [%{stop_reason: :end_turn}] = of_type(prompt(session, "next"), :agent_end)
      assert "--resume=#{id}" in args(bin, 2)
    end
  end

  describe "an interrupt" do
    # Starts a turn on a new program and gives it the program's output
    # until `ready?` holds for the state.
    defp running(work, ready?) do
      {_from, _actions, state} =
        request(harness(work), {:turn, "t1", %Helyx.Context{messages: [Message.user("x")]}})

      settle(state, ready?)
    end

    defp started?(state), do: state.turn.messages == nil and state.caps != nil

    defp interrupt(state) do
      {from, [], state} = request(state, {:interrupt, "t1"})
      {actions, _state} = pump(state, [], replied?(from))
      {:reply, ^from, answer} = List.last(actions)
      {answer, actions}
    end

    test "answers :ok after the control response and the result", %{bin: bin, work: work} do
      turn(bin, 1, 1, begin())
      script(bin, "ctl.1", [interrupted(), aborted()])

      assert {:ok, actions} = interrupt(running(work, &started?/1))
      refute Enum.any?(actions, &match?({:event, _, {:error, _}}, &1))
    end

    test "waits for the init line after the start of the turn", %{bin: bin, work: work} do
      turn(bin, 1, 1, [lifecycle("started")], "(sleep 0.3; out out.late) &\n")
      File.write!(Path.join(bin, "out.late"), init() <> "\n")
      script(bin, "ctl.1", [interrupted(), aborted()])

      state = running(work, &(&1.turn.messages == nil))
      assert state.caps == nil
      assert {:ok, _actions} = interrupt(state)
    end

    test "of a turn whose result comes before the control response answers :ok",
         %{bin: bin, work: work} do
      turn(bin, 1, 1, begin())
      script(bin, "ctl.1", [result("done"), interrupted()])

      assert {:ok, actions} = interrupt(running(work, &started?/1))
      refute Enum.any?(actions, &match?({:event, _, {:done, _}}, &1))
    end

    test "of a turn that ended answers :ok and writes nothing", %{bin: bin, work: work} do
      turn(bin, 1, 1, reply("ok"))

      state = running(work, &(&1.turn == nil))
      assert {from, [{:reply, from, :ok}], _state} = request(state, {:interrupt, "t1"})
      assert [%{"type" => "user"}] = stdin(bin, 1)
    end

    test "that cancels the turn's line answers :ok with no result", %{bin: bin, work: work} do
      # The capabilities are known before the start, as in a later turn.
      turn(bin, 1, 1, [lifecycle("queued"), init()])
      script(bin, "ctl.1", [interrupted([], ["@U@"])])

      assert {:ok, _actions} = interrupt(running(work, &(&1.caps != nil)))
      assert [%{"type" => "user"}, %{"type" => "control_request"}] = stdin(bin, 1)
    end

    test "after a replay waits for the start of the turn's line", %{bin: bin, work: work} do
      go = Path.join(bin, "go")
      rest = Path.join(bin, "out.rest")
      # The result of a failed replay line comes before the start.
      File.write!(rest, [replay_failed(), "\n", lifecycle("started"), "\n", init(), "\n"])
      gate = ~s(while [ ! -e "#{go}" ]; do sleep 0.05; done; out out.rest\n)
      turn(bin, 1, 1, [init()], gate)
      script(bin, "ctl.1", [interrupted(), aborted()])

      history = replay_history()

      {_from, _actions, state} =
        request(harness(work), {:turn, "t1", %Helyx.Context{messages: history}})

      state = settle(state, &(&1.caps != nil))
      assert {from, [], state} = request(state, {:interrupt, "t1"})
      assert state.turn.interrupt.request_id == nil

      File.write!(go, "")
      assert {actions, _state} = pump(state, [], replied?(from))
      assert {:reply, ^from, :ok} = List.last(actions)
      assert %{"type" => "control_request"} = List.last(stdin(bin, 1))
    end

    test "of a turn that ends before the interrupt is written answers :ok and writes nothing",
         %{bin: bin, work: work} do
      go = Path.join(bin, "go")
      File.write!(Path.join(bin, "out.rest"), [result("done"), "\n"])
      gate = ~s(while [ ! -e "#{go}" ]; do sleep 0.05; done; out out.rest\n)
      turn(bin, 1, 1, [lifecycle("started")], gate)

      state = running(work, &(&1.turn.messages == nil))
      assert {from, [], state} = request(state, {:interrupt, "t1"})

      File.write!(go, "")
      assert {actions, _state} = pump(state, [], replied?(from))
      assert {:reply, ^from, :ok} = List.last(actions)
      assert [%{"type" => "user"}] = stdin(bin, 1)
    end

    test "without interrupt_cancel_queued_v1 answers an error and writes nothing",
         %{bin: bin, work: work} do
      turn(bin, 1, 1, [lifecycle("started"), init(["interrupt_receipt_v1"])])
      state = running(work, &started?/1)

      assert {from, [{:reply, from, {:error, :no_cancel_queued}}], _state} =
               request(state, {:interrupt, "t1"})

      assert [%{"type" => "user"}] = stdin(bin, 1)
    end

    test "with work still queued answers an error", %{bin: bin, work: work} do
      turn(bin, 1, 1, begin())
      script(bin, "ctl.1", [interrupted(["q1"])])

      assert {{:error, :still_queued}, _actions} = interrupt(running(work, &started?/1))
    end

    # Only an exact `[]` confirms that no queued work remains.
    for {name, body} <- [
          {"a missing", %{cancelled: []}},
          {"a null", %{still_queued: nil, cancelled: []}},
          {"a non-list", %{still_queued: "none", cancelled: []}},
          {"a missing response", nil}
        ] do
      test "with #{name} still_queued answers an error", %{bin: bin, work: work} do
        turn(bin, 1, 1, begin())
        response = %{subtype: "success", request_id: "@R@", response: unquote(Macro.escape(body))}
        script(bin, "ctl.1", [j(%{type: "control_response", response: response}), aborted()])

        assert {{:error, :still_queued}, _actions} = interrupt(running(work, &started?/1))
      end
    end

    test "with an error response answers the error, cut", %{bin: bin, work: work} do
      turn(bin, 1, 1, begin())
      long = String.duplicate("é", 1_500)

      error =
        j(%{
          type: "control_response",
          response: %{subtype: "error", request_id: "@R@", error: long}
        })

      script(bin, "ctl.1", [error])

      assert {{:error, {:interrupt, text}}, _actions} = interrupt(running(work, &started?/1))
      assert byte_size(text) == 2_000 and String.valid?(text)
    end
  end

  describe "a steer" do
    # A turn that streams "a" and has no `result` yet.
    defp streaming(work), do: running(work, &(&1.turn.open? and &1.caps != nil))

    defp steer(state), do: request(state, {:steer, "t1", "s1", "more"})

    test "after the terminal answers :rejected and writes nothing", %{bin: bin, work: work} do
      turn(bin, 1, 1, reply("ok"))

      state = running(work, &(&1.turn == nil))
      assert {from, [{:reply, from, :rejected}], _state} = steer(state)
      assert [%{"type" => "user"}] = stdin(bin, 1)
    end

    test "written before the result keeps the turn until its start and the next result",
         %{bin: bin, work: work} do
      turn(bin, 1, 1, begin() ++ [delta("a")])
      # The fake reads the steer line, then gives the first result.
      turn(bin, 1, 2, [result("a"), lifecycle("started"), delta("b"), result("b")])

      assert {from, [{:reply, from, :ok}], state} = steer(streaming(work))
      {actions, _state} = pump(state, [], &ended?/1)
      assert [prompt, %{"type" => "user", "uuid" => uuid, "message" => message}] = stdin(bin, 1)
      assert uuid != prompt["uuid"]
      assert %{"role" => "user", "content" => [%{"type" => "text", "text" => "more"}]} = message

      assert [
               {:message_end, :end_turn, _},
               {:user_message, "s1", "more"},
               {:text_delta, "b"},
               {:done, _}
             ] =
               actions |> events_of() |> Enum.reject(&match?({:harness_session, _, _}, &1))
    end

    defp failed(errors) do
      j(%{
        type: "result",
        subtype: "error_during_execution",
        is_error: true,
        errors: errors,
        queued_turn_count: 0
      })
    end

    # The events of a turn whose held `result` is `held` and whose steer
    # then starts and succeeds.
    defp held_turn(bin, work, held) do
      turn(bin, 1, 1, begin() ++ [delta("a")])
      turn(bin, 1, 2, [held, lifecycle("started"), delta("b"), result("b")])

      {_from, _actions, state} = steer(streaming(work))
      {actions, _state} = pump(state, [], &ended?/1)
      actions |> events_of() |> Enum.reject(&match?({:harness_session, _, _}, &1))
    end

    # The error `result` before the steer's start is not the terminal; the
    # steer makes it obsolete, and it goes out as a notice (#241).
    test "an error result held for the steer goes out as a notice at the steer's start",
         %{bin: bin, work: work} do
      assert [
               {:message_end, :end_turn, _},
               {:notice, "the turn before the steer failed: error_during_execution: boom"},
               {:user_message, "s1", "more"},
               {:text_delta, "b"},
               {:done, _}
             ] = held_turn(bin, work, failed(["boom"]))
    end

    # The notice bound is 2,000 bytes (`HarnessIO.cap_error/1`); a cut of a
    # 3,000-byte multibyte error stays valid UTF-8.
    test "a held error over the notice bound is cut to 2,000 bytes", %{bin: bin, work: work} do
      events = held_turn(bin, work, failed([String.duplicate("é", 1_500)]))
      assert [text] = for({:notice, text} <- events, do: text)
      assert byte_size(text) <= 2_000 and byte_size(text) > 1_990 and String.valid?(text)
    end

    test "a success result held for the steer gives no notice", %{bin: bin, work: work} do
      refute Enum.any?(held_turn(bin, work, result("a")), &match?({:notice, _}, &1))
    end

    test "that starts after a tool result gives user_message after the result",
         %{bin: bin, work: work} do
      turn(bin, 1, 1, begin() ++ [tool_use("c1", %{command: "ls"})])
      turn(bin, 1, 2, [tool_result("c1", "out"), lifecycle("started"), delta("b"), result("b")])

      state = running(work, &(&1.turn.calls? and &1.caps != nil))
      {_from, _actions, state} = steer(state)
      {actions, _state} = pump(state, [], &ended?/1)

      assert [
               {:message_end, :tool_use, _},
               {:tool_result, "c1", {:ok, "out"}},
               {:user_message, "s1", "more"},
               {:text_delta, "b"},
               {:done, _}
             ] = events_of(actions)
    end

    test "with no start after a held result stops the harness process",
         %{bin: bin, work: work} do
      turn(bin, 1, 1, begin() ++ [delta("a")])
      turn(bin, 1, 2, [result("a")])

      {_from, _actions, state} = steer(streaming(work))
      state = settle(state, &(&1.turn.wait != nil))
      # The timer is armed for 5,000 ms; the test gives its message at once.
      remaining = :erlang.read_timer(state.turn.wait)
      assert remaining <= 5_000 and remaining > 5_000 - @load_ms
      :erlang.cancel_timer(state.turn.wait)
      send(self(), {:timeout, state.turn.wait, :steer_wait})
      assert {[{:stop, :steer_not_started}], _state} = pump(state, [], &ended?/1)
    end

    test "an interrupt of a held turn answers :ok at the control response",
         %{bin: bin, work: work} do
      turn(bin, 1, 1, begin() ++ [delta("a")])
      turn(bin, 1, 2, [result("a")])
      script(bin, "ctl.1", [interrupted([], ["@U@"])])

      {_from, _actions, state} = steer(streaming(work))
      state = settle(state, &(&1.turn.wait != nil))
      assert {:ok, _actions} = interrupt(state)
    end
  end

  test "a result of a turn with no model call ends the turn", %{bin: bin, work: work} do
    turn(bin, 1, 1, begin() ++ [result("", 0)])

    assert [{:harness_session, _id, 0}, {:done, _}] =
             events_of(run_direct([Message.user("hi")], work))
  end

  # A program turn: the program starts a turn by itself when a background
  # task ends. It has no `command_lifecycle`, and its `result` has `origin`
  # and a null `user_message_uuid` (research note, "Program turns").
  defp program_result(text) do
    line = JSON.decode!(result(text))
    origin = %{kind: "task-notification", producer: "session-task"}
    j(Map.merge(line, %{"origin" => origin, "user_message_uuid" => nil}))
  end

  test "a prompt during a program turn gets its own answer, not the program's",
       %{bin: bin, work: work} do
    turn(bin, 1, 1, reply("first"))
    # Observed order: the line is queued at once, the program turn ends,
    # then the line starts as a turn of its own. The program turn's `init`
    # came before the line; the tool call in it was not observed.
    turn(bin, 1, 2, [
      lifecycle("queued"),
      init(),
      delta("program"),
      tool_use("p1", %{command: "ls"}),
      call("n1", 1, "p1"),
      tool_result("p1", "out"),
      program_result("program"),
      lifecycle("started"),
      init(),
      delta("mine"),
      assistant(%{type: "text", text: "mine"}),
      result("mine")
    ])

    {_from, actions, state} =
      request(harness(work), {:turn, "t1", %Helyx.Context{messages: [Message.user("a")]}})

    {_actions, state} = pump(state, actions, &ended?/1)
    context = %Helyx.Context{messages: [Message.user("a"), Message.user("b")]}
    {_from, actions, state} = request(state, {:turn, "t2", context})
    {actions, state} = pump(state, actions, &ended?/1)

    assert [{:text_delta, "mine"}, {:done, _}] = events_of(actions)
    # A Helyx tool call of the program turn runs nothing.
    :ok = closed(state)
    assert %{"result" => %{"isError" => true}} = answers(bin, 1)["n1"]
  end

  test "a result before the start of the turn's line after a replay does not end the turn",
       %{bin: bin, work: work} do
    turn(bin, 1, 1, [init(), replay_failed() | reply("ok")])

    history = replay_history()

    assert [{:harness_session, _id, 0}, {:text_delta, "ok"} | _] =
             events_of(run_direct(history, work))
  end

  test "a result before the start to a program without msg_lifecycle_v1 stops it",
       %{bin: bin, work: work} do
    caps = ["interrupt_receipt_v1", "interrupt_cancel_queued_v1"]
    turn(bin, 1, 1, [init(caps), delta("program"), result("program")])

    actions = run_direct([Message.user("hi")], work)
    assert {:stop, :no_msg_lifecycle} = List.last(actions)
    assert [{:harness_session, _id, 0}] = events_of(actions)
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
    state = settle(state, &(&1.turn != nil and &1.turn.open?))
    assert %{request_id: nil, result?: false} = state.turn.interrupt
  end

  test "a replay to a program with no init line stops it", %{bin: bin, work: work} do
    turn(bin, 1, 1, [replayed(), lifecycle("queued"), delta("ok"), result("ok")])

    assert {:stop, :no_msg_lifecycle} = List.last(run_direct(replay_history(), work))
  end

  test "a close while a resumed program reports its session lost starts no program",
       %{bin: bin, work: work} do
    # The program reports the lost session only after the close.
    go = Path.join(bin, "go")
    gate = ~s(while [ ! -e "#{go}" ]; do sleep 0.05; done\n)
    script(bin, "start.1", [lost(@sid)], "exit 1\n")
    File.write!(Path.join(bin, "start.1"), gate <> File.read!(Path.join(bin, "start.1")))

    state = harness(work, harness_session_id: @sid)
    from = make_ref()
    assert {:ok, [], state} = ClaudeCode.harness_request(:close, from, state)
    File.write!(go, "")
    assert {[{:reply, ^from, :ok}], _state} = pump(state, [], replied?(from))
    assert programs(bin) == "1"
  end

  describe "an idle close" do
    # The line of the program at each change of its live background tasks
    # (`claude` 2.1.284); `tasks` is the whole set.
    defp tasks_line(fields) do
      j(Map.merge(%{type: "system", subtype: "background_tasks_changed", uuid: "u9"}, fields))
    end

    # One turn whose program sends `lines` after its result, between
    # turns; returns the state once `done?` holds.
    defp idle(bin, work, lines, tail, done?) do
      turn(bin, 1, 1, reply("ok") ++ lines, tail)
      context = %Helyx.Context{messages: [Message.user("hi")]}
      {_from, actions, state} = request(harness(work), {:turn, "t1", context})
      {_actions, state} = pump(state, actions, &ended?/1)
      settle(state, done?)
    end

    test "with a live background task answers :busy and keeps the program; with none it closes",
         %{bin: bin, work: work} do
      task = %{task_id: "bm9v5qfnr", task_type: "local_bash", description: "sleep 12"}
      go = Path.join(bin, "go")
      File.write!(Path.join(bin, "out.rest"), tasks_line(%{tasks: []}) <> "\n")
      gate = ~s(while [ ! -e "#{go}" ]; do sleep 0.05; done; out out.rest\n)
      state = idle(bin, work, [tasks_line(%{tasks: [task]})], gate, &(&1.tasks != []))

      assert {_from, [{:reply, _, :busy}], state} = request(state, :idle_close)
      assert programs(bin) == "1"

      File.write!(go, "")
      state = settle(state, &(&1.tasks == []))
      {from, [], state} = request(state, :idle_close)
      assert {[{:reply, ^from, :ok}], _state} = pump(state, [], replied?(from))
      assert programs(bin) == "1"
    end

    # #224: a sub-agent's lines carry `parent_tool_use_id`, and a
    # background sub-agent is in the set of background tasks (research
    # note, "Sub-agents at the end of a turn").
    test "a background sub-agent gives no events and keeps the program as a background task",
         %{bin: bin, work: work} do
      sub = &String.replace(&1, ~s("parent_tool_use_id":null), ~s("parent_tool_use_id":"toolu_a"))
      own = [tool_use("toolu_s", %{command: "sleep 40"}), tool_result("toolu_s", "x"), delta("s")]
      task = %{task_id: "a1", task_type: "local_agent", description: "research"}
      text = [delta("ok"), assistant(%{type: "text", text: "ok"}), result("ok")]
      turn(bin, 1, 1, begin() ++ Enum.map(own, sub) ++ text ++ [tasks_line(%{tasks: [task]})])
      context = %Helyx.Context{messages: [Message.user("hi")]}
      {_from, actions, state} = request(harness(work), {:turn, "t1", context})
      {actions, state} = pump(state, actions, &ended?/1)

      assert [{:harness_session, _, 0}, {:text_delta, "ok"}, {:done, _}] =
               for({:event, "t1", event} <- actions, do: event)

      state = settle(state, &(&1.tasks != []))
      assert {_from, [{:reply, _, :busy}], _state} = request(state, :idle_close)
    end

    for {name, fields} <- [
          {"a null tasks", %{tasks: nil}},
          {"no tasks field", %{}},
          {"a tasks string", %{tasks: "[]"}},
          {"a tasks map", %{tasks: %{}}}
        ] do
      test "after #{name} answers :busy", %{bin: bin, work: work} do
        line = tasks_line(unquote(Macro.escape(fields)))
        state = idle(bin, work, [line], "", &(&1.tasks == :unknown))
        assert {_from, [{:reply, _, :busy}], _state} = request(state, :idle_close)
      end
    end
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

    assert [%{stop_reason: :error, error: {:claude_code, "error_max_turns", "too many"}}] =
             of_type(events, :agent_end)

    assert [
             %{message: %Message{tool_call_id: "toolu_a", is_error: false}},
             %{message: %Message{tool_call_id: "toolu_b", is_error: true} = aborted}
           ] = of_type(events, :tool_execution_end)

    assert Message.text(aborted) == "aborted"

    assert [%{stop_reason: :end_turn}] = of_type(prompt(session, "next"), :agent_end)
    assert programs(bin) == "1"
  end

  test "a program that exits between turns ends the harness process; the next turn resumes",
       %{bin: bin} = ctx do
    turn(bin, 1, 1, reply("Hi."), "exit 3\n")
    turn(bin, 2, 1, reply("Back."))

    session = start(ctx)
    [%{harness_session_id: id}] = of_type(prompt(session, "hello"), :harness_session)
    # A turn that starts before the session saw the end runs on the old
    # harness process and fails (`docs/features/long-lived-harness.md`,
    # "Built in #199").
    wait_for_no_harness(Session.pid(session))
    assert [%{stop_reason: :end_turn}] = of_type(prompt(session, "again"), :agent_end)
    assert "--resume=#{id}" in args(bin, 2)
  end

  test "a program that exits during a turn fails it", %{bin: bin} = ctx do
    turn(bin, 1, 1, begin(), "exit 3\n")

    events = prompt(start(ctx), "go")

    assert [%{stop_reason: :error, error: {:harness_stop, {:claude_code_exit, 3}}}] =
             of_type(events, :agent_end)
  end

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
  # decode, 1.5 ms a line, takes longer than the 200 ms wait for the
  # `:DOWN` (the test fails on code that traps exits).
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

        pump(state, actions, fn _ -> false end)
      end)

    for _hold <- 1..2 do
      assert_receive {:"$gen_call", from, {:hold, _handle}}, 5_000
      GenServer.reply(from, :ok)
    end

    program = wait_for_pid(ready)
    :erlang.suspend_process(pid)
    File.write!(go, "")
    wait_for_pid(written)
    Process.exit(pid, :shutdown)
    :erlang.resume_process(pid)

    assert_receive {:DOWN, ^ref, :process, _pid, :shutdown}, 200
    # The keeper closes the port, so the watchdog ends the group.
    assert group_gone_within?(program, 300)
  end

  describe "the Helyx tools" do
    @spec_read %{name: "read", description: "Reads a file.", parameters: %{"type" => "object"}}

    defp mcp_request(request_id, message) do
      request = %{subtype: "mcp_message", server_name: "helyx", message: message}
      j(%{type: "control_request", request_id: request_id, request: request})
    end

    defp tools_call(request_id, id, meta) do
      params = %{name: "read", arguments: %{path: "a.txt"}, _meta: meta}
      mcp_request(request_id, %{jsonrpc: "2.0", id: id, method: "tools/call", params: params})
    end

    defp call(request_id, id, use_id),
      do: tools_call(request_id, id, %{"claudecode/toolUseId" => use_id, progressToken: id})

    # The answers the provider wrote, by control request id.
    defp answers(bin, n) do
      for %{"type" => "control_response", "response" => r} <- stdin(bin, n),
          into: %{},
          do: {r["request_id"], r["response"]["mcp_response"] || r}
    end

    # A line that changes the state, so a test knows that the lines before
    # it were read.
    defp marker, do: j(%{type: "system", subtype: "background_tasks_changed", tasks: ["marker"]})
    defp marked?(state), do: state.tasks == ["marker"]

    defp closed(state) do
      {from, [], state} = request(state, :close)
      {_actions, _state} = pump(state, [], replied?(from))
      :ok
    end

    defp tool_turn(work) do
      {:ok, state} = ClaudeCode.harness_init("haiku", [@spec_read], cwd: work)

      {_from, actions, state} =
        request(state, {:turn, "t1", %Helyx.Context{messages: [Message.user("x")]}})

      pump(state, actions, fn actions ->
        Enum.any?(actions, &match?({:event, _, {:tool_request, _, _, _}}, &1))
      end)
    end

    test "the program gets the MCP config of the helyx server, and not the strict switch",
         %{bin: bin, work: work} do
      closed(harness(work))
      args = args(bin, 1)
      assert ~s({"mcpServers":{"helyx":{"type":"sdk","name":"helyx"}}}) in args
      refute "--strict-mcp-config" in args
    end

    test "answers each initialize, the notifications, and tools/list", %{bin: bin, work: work} do
      initialize = %{
        jsonrpc: "2.0",
        id: 0,
        method: "initialize",
        params: %{protocolVersion: "2025-11-25", capabilities: %{}}
      }

      script(bin, "start.1", [
        mcp_request("i1", initialize),
        mcp_request("i2", %{jsonrpc: "2.0", method: "notifications/initialized"}),
        mcp_request("i3", %{jsonrpc: "2.0", id: 1, method: "tools/list"}),
        mcp_request("i4", %{initialize | id: 2}),
        mcp_request("i5", %{jsonrpc: "2.0", id: 3, method: "resources/list"}),
        mcp_request("i6", %{jsonrpc: "2.0", id: 4, method: "initialize"}),
        mcp_request("i7", %{initialize | id: 5, params: "2024-01-01"}),
        mcp_request("i8", %{initialize | id: 6, params: %{protocolVersion: "2025-06-18"}}),
        marker()
      ])

      {:ok, state} = ClaudeCode.harness_init("haiku", [@spec_read], cwd: work)
      closed(settle(state, &marked?/1))

      result = %{
        "protocolVersion" => "2025-11-25",
        "capabilities" => %{"tools" => %{}},
        "serverInfo" => %{"name" => "helyx", "version" => "0.1.0"}
      }

      tools = [
        %{
          "name" => "read",
          "description" => "Reads a file.",
          "inputSchema" => %{"type" => "object"}
        }
      ]

      assert %{
               "i1" => %{"id" => 0, "result" => ^result},
               "i2" => %{"jsonrpc" => "2.0", "result" => %{}} = ack,
               "i3" => %{"id" => 1, "result" => %{"tools" => ^tools}},
               "i4" => %{"id" => 2, "result" => ^result},
               "i5" => %{"id" => 3, "error" => %{"code" => -32_601}},
               "i6" => %{"id" => 4, "result" => ^result},
               "i7" => %{"id" => 5, "result" => ^result},
               "i8" => %{"id" => 6, "result" => %{"protocolVersion" => "2025-06-18"}}
             } = answers(bin, 1)

      refute Map.has_key?(ack, "id")
    end

    test "a tools/call gives a tool request, and its result goes back as an MCP result",
         %{bin: bin, work: work} do
      turn(bin, 1, 1, begin() ++ [call("m1", 2, "toolu_h1")])
      {actions, state} = tool_turn(work)

      assert {:event, "t1", {:tool_request, "toolu_h1", "read", %{"path" => "a.txt"}}} =
               List.last(actions)

      {from, actions, state} = request(state, {:tool_result, "t1", "toolu_h1", {:error, "boom"}})
      assert actions == [{:reply, from, :ok}]
      closed(state)

      assert %{
               "m1" => %{
                 "id" => 2,
                 "result" => %{
                   "content" => [%{"type" => "text", "text" => "boom"}],
                   "isError" => true
                 }
               }
             } = answers(bin, 1)
    end

    test "a tools/call with no tool use id, or with no turn, gets an error and gives no request",
         %{bin: bin, work: work} do
      script(bin, "start.1", [call("n1", 1, "toolu_early"), marker()])
      no_params = %{jsonrpc: "2.0", id: 3, method: "tools/call"}

      turn(
        bin,
        1,
        1,
        begin() ++
          [tools_call("n2", 2, %{progressToken: 2}), mcp_request("n3", no_params), result("done")]
      )

      {:ok, state} = ClaudeCode.harness_init("haiku", [@spec_read], cwd: work)
      state = settle(state, &marked?/1)

      {_from, actions, state} =
        request(state, {:turn, "t1", %Helyx.Context{messages: [Message.user("x")]}})

      {actions, state} = pump(state, actions, &ended?/1)
      closed(state)

      refute Enum.any?(actions, &match?({:event, _, {:tool_request, _, _, _}}, &1))

      assert %{
               "n1" => %{
                 "id" => 1,
                 "result" => %{
                   "isError" => true,
                   "content" => [%{"text" => "no Helyx turn" <> _}]
                 }
               },
               "n2" => %{"id" => 2, "result" => %{"isError" => true}},
               "n3" => %{"id" => 3, "result" => %{"isError" => true}}
             } = answers(bin, 1)
    end

    test "a call id that the provider rejected never gives a tool request later in the turn",
         %{bin: bin, work: work} do
      meta = %{"claudecode/toolUseId" => "toolu_x"}
      bad = %{name: "read", arguments: [], _meta: meta}
      bad_call = %{jsonrpc: "2.0", id: 2, method: "tools/call", params: bad}
      bad_name = %{name: 5, _meta: %{"claudecode/toolUseId" => "toolu_n"}}
      name_call = %{jsonrpc: "2.0", id: 6, method: "tools/call", params: bad_name}

      turn(
        bin,
        1,
        1,
        begin() ++
          [
            mcp_request("r1", bad_call),
            call("r2", 3, "toolu_x"),
            call("r3", 4, "toolu_z"),
            call("r4", 5, "toolu_z"),
            mcp_request("r5", name_call),
            call("r6", 7, "toolu_n"),
            result("done")
          ]
      )

      {:ok, state} = ClaudeCode.harness_init("haiku", [@spec_read], cwd: work)

      {_from, actions, state} =
        request(state, {:turn, "t1", %Helyx.Context{messages: [Message.user("x")]}})

      {actions, state} = pump(state, actions, &ended?/1)
      closed(state)

      # Only the first call of toolu_z maps; the open id is used too.
      assert [{:event, "t1", {:tool_request, "toolu_z", "read", _}}] =
               Enum.filter(actions, &match?({:event, _, {:tool_request, _, _, _}}, &1))

      assert %{
               "r4" => %{
                 "id" => 5,
                 "result" => %{
                   "isError" => true,
                   "content" => [%{"text" => "the call id was used" <> _}]
                 }
               },
               "r5" => %{"id" => 6, "result" => %{"isError" => true}},
               "r6" => %{
                 "id" => 7,
                 "result" => %{
                   "isError" => true,
                   "content" => [%{"text" => "the call id was used" <> _}]
                 }
               },
               "r1" => %{"id" => 2, "result" => %{"isError" => true}},
               "r2" => %{
                 "id" => 3,
                 "result" => %{
                   "isError" => true,
                   "content" => [%{"text" => "the call id was used before" <> _}]
                 }
               }
             } = answers(bin, 1)
    end

    test "notifications/cancelled withdraws the call; its later result is not written",
         %{bin: bin, work: work} do
      cancelled = %{jsonrpc: "2.0", method: "notifications/cancelled", params: %{requestId: 2}}
      turn(bin, 1, 1, begin() ++ [call("m1", 2, "toolu_h1")])
      {_actions, state} = tool_turn(work)

      File.write!(Path.join(bin, "out.late"), mcp_request("c1", cancelled) <> "\n")
      File.write!(Path.join(bin, "ctl.1"), "out out.late\n")
      # A control request from the host makes the fake write the notification.
      Helyx.HarnessIO.write(state, [
        j(%{type: "control_request", request_id: "x", request: %{subtype: "ping"}}),
        "\n"
      ])

      {actions, state} =
        pump(state, [], &Enum.any?(&1, fn a -> match?({:cancel_tool, _, _}, a) end))

      assert [{:cancel_tool, "t1", "toolu_h1"}] = actions

      {from, [{:reply, from, :ok}], state} =
        request(state, {:tool_result, "t1", "toolu_h1", {:ok, "late"}})

      closed(state)

      assert %{"c1" => %{"result" => %{}}} = answers = answers(bin, 1)
      refute Map.has_key?(answers, "m1")
    end

    test "a control_cancel_request withdraws the call and gets no answer", %{bin: bin, work: work} do
      turn(bin, 1, 1, begin() ++ [call("m1", 2, "toolu_h1")])
      {_actions, state} = tool_turn(work)

      File.write!(
        Path.join(bin, "out.late"),
        j(%{type: "control_cancel_request", request_id: "m1"}) <> "\n"
      )

      File.write!(Path.join(bin, "ctl.1"), "out out.late\n")

      Helyx.HarnessIO.write(state, [
        j(%{type: "control_request", request_id: "x", request: %{subtype: "ping"}}),
        "\n"
      ])

      {actions, state} =
        pump(state, [], &Enum.any?(&1, fn a -> match?({:cancel_tool, _, _}, a) end))

      assert [{:cancel_tool, "t1", "toolu_h1"}] = actions
      closed(state)
      assert answers(bin, 1) == %{}
    end

    test "in a session: the tool runs on the hands, and the transcript has one call and one result",
         %{bin: bin, work: work, sessions: sessions} do
      core = :"core_#{System.unique_integer([:positive])}"

      start_supervised!({Helyx.Core, name: core, plugins: [ClaudeCode, Fake, Helyx.Tool.Read]},
        id: :tools_core
      )

      File.write!(Path.join(work, "a.txt"), "hello\n")

      use_block = %{
        type: "tool_use",
        id: "toolu_h1",
        name: "mcp__helyx__read",
        input: %{path: "a.txt"}
      }

      turn(bin, 1, 1, begin() ++ [assistant(use_block), call("m1", 2, "toolu_h1")])

      script(bin, "resp.1", [
        tool_result("toolu_h1", "hello"),
        delta("Done."),
        assistant(%{type: "text", text: "Done."}),
        result("Done.", 2)
      ])

      session = start(%{core: core, work: work, sessions: sessions})
      events = prompt(session, "read it")
      GenServer.stop(Session.pid(session))

      assert [%{stop_reason: :end_turn}] = of_type(events, :agent_end)

      transcript =
        messages(events) ++ for(%{message: m} <- of_type(events, :tool_execution_end), do: m)

      calls =
        for %Message{content: blocks} <- transcript, %Message.ToolCall{} = c <- blocks, do: c

      assert [%Message.ToolCall{id: "toolu_h1", name: "mcp__helyx__read"}] = calls

      assert [%Message{tool_call_id: "toolu_h1"}] =
               for(%Message{role: :tool_result} = m <- transcript, do: m)

      assert %{
               "m1" => %{
                 "id" => 2,
                 "result" => %{"isError" => false, "content" => [%{"text" => text}]}
               }
             } =
               answers(bin, 1)

      assert text =~ "hello"
    end
  end
end
