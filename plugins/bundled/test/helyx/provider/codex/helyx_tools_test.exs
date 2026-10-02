defmodule Helyx.Provider.Codex.HelyxToolsTest do
  # The Helyx tools that Codex calls as dynamic tools.
  use ExUnit.Case, async: true

  import Helyx.Test.CodexFake
  import Helyx.Test.Events
  import Helyx.Test.HarnessDriver
  import Helyx.Test.OSHelpers

  alias Helyx.{Message, Session}
  alias Helyx.Provider.{Codex, Fake}

  @moduletag :tmp_dir
  setup {Helyx.Test.CodexFake, :setup_fake}

  describe "the Helyx tools" do
    @spec_read %{name: "read", description: "Reads a file.", parameters: %{"type" => "object"}}

    defp dyn(id, fields \\ %{}),
      do:
        Map.merge(
          %{type: "dynamicToolCall", id: id, tool: "read", arguments: %{}, status: "inProgress"},
          fields
        )

    defp tool_call(tid, rpc_id, call_id, fields \\ %{}) do
      params = %{
        threadId: tid,
        turnId: "turn1",
        callId: call_id,
        namespace: nil,
        tool: "read",
        arguments: %{path: "a.txt"}
      }

      j(%{id: rpc_id, method: "item/tool/call", params: Map.merge(params, fields)})
    end

    # The answers to the tool calls that Helyx wrote, in order, with their
    # request ids.
    defp answers(bin, n),
      do: for(%{"id" => id, "result" => %{"contentItems" => _} = r} <- stdin(bin, n), do: {id, r})

    # Shell code that writes `lines` in the background once Helyx wrote a
    # tool answer, or once `file` exists.
    defp after_answer(bin, name, lines) do
      lines_file(bin, name, lines)
      ~s{(while ! grep -q contentItems "$d/stdin.$n"; do sleep 0.02; done; out "$d/#{name}") &\n}
    end

    defp after_file(bin, name, file, lines) do
      lines_file(bin, name, lines)
      ~s{(while [ ! -f "#{file}" ]; do sleep 0.02; done; out "$d/#{name}") &\n}
    end

    defp tools_turn(work, tools \\ [@spec_read], opts \\ []) do
      {:ok, state} = Codex.init("m", tools, [cwd: work] ++ opts)
      turn = {:turn, "t1", %Helyx.Context{messages: [Message.user("x")]}}
      {_from, actions, state} = ask(state, turn)
      {state, actions}
    end

    defp digest?(id),
      do: match?([tid(), digest] when byte_size(digest) == 16, String.split(id, "#"))

    test "initialize asks for experimentalApi, thread/start gives the tools, and the id names the tool set",
         %{bin: bin, work: work} do
      fresh(bin, 1, tid(), reply(tid(), "Hi."))
      {state, actions} = tools_turn(work)
      {actions, state} = pump(Codex, state, actions, &turn_ended?/1)
      close(state)

      assert %{"params" => %{"capabilities" => %{"experimentalApi" => true}}} =
               request(bin, 1, "initialize")

      assert %{
               "params" => %{
                 "dynamicTools" => [
                   %{
                     "type" => "function",
                     "name" => "read",
                     "description" => "Reads a file.",
                     "inputSchema" => %{"type" => "object"}
                   }
                 ]
               }
             } = request(bin, 1, "thread/start")

      assert [{:resume, id, 0} | _] = events(actions)
      assert digest?(id)
      refute Enum.any?(events(actions), &match?({:notice, _}, &1))
    end

    @tag :slow
    test "a stored id resumes only a thread with the session's tool set", %{bin: bin, work: work} do
      fresh(bin, 1, tid(), reply(tid(), "Hi."))
      {state, actions} = tools_turn(work)
      {actions, state} = pump(Codex, state, actions, &turn_ended?/1)
      [{:resume, id, 0} | _] = events(actions)
      close(state)

      runs = [
        {[@spec_read], id, "thread/resume"},
        {[@spec_read], tid(), "thread/start"},
        {[], id, "thread/start"},
        {[], tid(), "thread/resume"},
        {[%{@spec_read | description: "Other."}], id, "thread/start"}
      ]

      for {{tools, stored, method}, n} <- Enum.with_index(runs, 2) do
        initialize(bin, n)
        on(bin, n, "thread/resume", [j(%{id: "@", result: %{thread: thread(tid())}})])
        on(bin, n, "thread/start", [j(%{id: "@", result: %{thread: thread(fresh_tid())}})])

        {:ok, state} = Codex.init("m", tools, cwd: work, resume_id: stored)
        close(state)
        assert request(bin, n, method), "run #{n}"
        caps = request(bin, n, "initialize")["params"]["capabilities"]
        assert caps == if(tools == [], do: nil, else: %{"experimentalApi" => true})
      end

      assert %{"params" => %{"threadId" => tid()}} = request(bin, 2, "thread/resume")
    end

    test "an initialize error starts the thread without the tools, and the first turn gives a notice",
         %{bin: bin, work: work} do
      fresh(bin, 1, tid(), reply(tid(), "Hi."))
      on(bin, 1, "initialize", [j(%{id: "@", error: %{code: -32_600, message: "no"}})], "", 1)
      on(bin, 1, "turn/start", as_turn(turn(tid(), reply(tid(), "Again.")), "turn2"), "", 2)
      {state, actions} = tools_turn(work)
      {actions, state} = pump(Codex, state, actions, &turn_ended?/1)

      {_from, next, state} =
        ask(state, {:turn, "t2", %Helyx.Context{messages: [Message.user("y")]}})

      {next, state} = pump(Codex, state, next, &turn_ended?/1)
      close(state)

      assert [
               %{"params" => %{"capabilities" => %{"experimentalApi" => true}}},
               %{"params" => second}
             ] = for(%{"method" => "initialize"} = line <- stdin(bin, 1), do: line)

      refute Map.has_key?(second, "capabilities")
      refute Map.has_key?(request(bin, 1, "thread/start")["params"], "dynamicTools")

      assert [
               {:notice, "the Helyx tools are off for Codex" <> _},
               {:resume, tid(), 0} | _
             ] =
               events(actions)

      refute Enum.any?(next, &match?({:event, _, {:notice, _}}, &1))
    end

    test "the exact experimentalApi error of thread/start starts the thread without the tools",
         %{bin: bin, work: work} do
      fresh(bin, 1, tid(), reply(tid(), "Hi."))

      error = %{
        code: -32_600,
        message: "thread/start.dynamicTools requires experimentalApi capability"
      }

      on(bin, 1, "thread/start", [j(%{id: "@", error: error})], "", 1)
      {state, actions} = tools_turn(work)
      {actions, state} = pump(Codex, state, actions, &turn_ended?/1)
      close(state)

      assert [%{"params" => %{"dynamicTools" => [_]}}, %{"params" => second}] =
               for(%{"method" => "thread/start"} = line <- stdin(bin, 1), do: line)

      refute Map.has_key?(second, "dynamicTools")
      assert [{:notice, _}, {:resume, tid(), 0} | _] = events(actions)
    end

    test "a call of an open dynamicToolCall item gives a tool request, and its result goes back",
         %{bin: bin, work: work} do
      fresh(bin, 1, tid(), [started(tid(), dyn("call_d1")), tool_call(tid(), 0, "call_d1")])
      {state, actions} = tools_turn(work)

      requested? = &Enum.any?(&1, fn a -> match?({:event, _, {:tool_request, _, _, _}}, a) end)
      {actions, state} = pump(Codex, state, actions, requested?)

      assert {:event, "t1", {:tool_request, "call_d1", "read", %{"path" => "a.txt"}}} =
               List.last(actions)

      {from, actions, state} = ask(state, {:tool_result, "t1", "call_d1", {:ok, "hello"}})
      assert actions == [{:reply, from, :ok}]
      close(state)

      assert [{0, %{"contentItems" => [%{"type" => "inputText", "text" => "hello"}]} = answer}] =
               answers(bin, 1)

      assert answer["success"] == true
    end

    test "a call with the request id null gets its result", %{bin: bin, work: work} do
      fresh(bin, 1, tid(), [started(tid(), dyn("call_d1")), tool_call(tid(), nil, "call_d1")])
      {state, actions} = tools_turn(work)
      requested? = &Enum.any?(&1, fn a -> match?({:event, _, {:tool_request, _, _, _}}, a) end)
      {_actions, state} = pump(Codex, state, actions, requested?)
      {_from, _actions, state} = ask(state, {:tool_result, "t1", "call_d1", {:ok, "hello"}})
      close(state)
      assert [{nil, %{"success" => true}}] = answers(bin, 1)
    end

    test "a thread id that is empty or leaves no room for the digest fails the connect", %{
      bin: bin,
      work: work
    } do
      initialize(bin, 1)
      long = %{thread(tid()) | id: String.duplicate("a", 240)}
      on(bin, 1, "thread/start", [j(%{id: "@", result: %{thread: long}})])

      assert {:error, {:malformed, "thread/start"}} =
               Codex.init("m", [@spec_read], cwd: work)

      initialize(bin, 2)
      at = %{thread(tid()) | id: String.duplicate("a", 239)}
      on(bin, 2, "thread/start", [j(%{id: "@", result: %{thread: at}})])
      assert {:ok, state} = Codex.init("m", [@spec_read], cwd: work)
      close(state)

      initialize(bin, 3)
      empty = %{thread(tid()) | id: ""}
      on(bin, 3, "thread/start", [j(%{id: "@", result: %{thread: empty}})])

      assert {:error, {:malformed, "thread/start"}} = Codex.init("m", [], cwd: work)
    end

    test "a call with no turn, one that does not map, and a used call id get an error and give no request",
         %{bin: bin, work: work} do
      initialize(bin, 1)

      on(bin, 1, "thread/start", [
        j(%{id: "@", result: %{thread: thread(tid())}}),
        tool_call(tid(), 0, "call_early")
      ])

      on(bin, 1, "thread/inject_items", [j(%{id: "@", result: %{}})])

      lines = [
        started(tid(), dyn("call_d1")),
        started(tid(), command("exec-1", %{status: "inProgress"})),
        tool_call(tid(), 1, "call_d1"),
        tool_call(tid(), 2, "call_d1"),
        tool_call(tid(), 3, "exec-1"),
        tool_call(tid(), 4, "call_none"),
        tool_call(tid(), 5, "call_x", %{callId: 7}),
        tool_call(tid(), 6, "call_d1", %{turnId: "turn0"}),
        tool_call(tid(), 7, "call_d3", %{arguments: "a.txt"}),
        completed(tid(), command("exec-1", done())),
        completed(tid(), dyn("call_d1", %{status: "failed"}))
      ]

      on(bin, 1, "turn/start", turn(tid(), lines ++ reply(tid(), "Done.")))
      {state, actions} = tools_turn(work)
      {actions, state} = pump(Codex, state, actions, &turn_ended?/1)
      close(state)

      assert [{:tool_request, "call_d1", _, _}] =
               for({:tool_request, _, _, _} = e <- events(actions), do: e)

      texts =
        for {id, %{"success" => false, "contentItems" => [%{"text" => t}]}} <- answers(bin, 1),
            do: {id, t}

      assert texts == [
               {0, "no Helyx turn is running"},
               {2, "the call id was used before in this turn"},
               {3, "the call does not map to a tool use"},
               {4, "the call does not map to a tool use"},
               {5, "the call does not map to a tool use"},
               {6, "the call id was used before in this turn"},
               {7, "the call does not map to a tool use"}
             ]
    end

    defp tools_core(ctx) do
      core = :"core_#{System.unique_integer([:positive])}"

      start_supervised!({Helyx.Core, name: core, plugins: [Codex, Fake, Helyx.Tool.Bash]},
        id: :tools_core
      )

      %{ctx | core: core}
    end

    defp bash(id, command), do: dyn(id, %{tool: "bash", arguments: %{command: command}})

    defp bash_call(tid, id, command),
      do: tool_call(tid, 0, id, %{tool: "bash", arguments: %{command: command}})

    defp transcript_calls(events) do
      transcript =
        messages(events) ++ for(%{message: m} <- of_type(events, :tool_execution_end), do: m)

      {for(%Message{content: blocks} <- transcript, %Message.ToolCall{} = c <- blocks, do: c.id),
       for(%Message{role: :tool_result} = m <- transcript, do: m.tool_call_id)}
    end

    # The running tool writes its pid, then sleeps.
    defp sleeper(pidfile), do: ~s(echo $$ > "#{pidfile}"; exec sleep 30)

    defp running(command),
      do: [started(tid(), bash("call_d1", command)), bash_call(tid(), "call_d1", command)]

    test "in a session: the tool runs on the hands, and the transcript has one call and one result",
         %{bin: bin} = ctx do
      ctx = tools_core(ctx)
      content = [%{type: "inputText", text: "hello"}]

      done =
        Map.merge(bash("call_d1", "echo hello"), %{
          status: "completed",
          success: true,
          contentItems: content
        })

      rest = after_answer(bin, "rest", [completed(tid(), done)] ++ reply(tid(), "Done."))
      fresh(bin, 1, tid(), running("echo hello"), rest)

      session = start(ctx)
      events = prompt(session, "say hello")
      GenServer.stop(Session.pid(session))

      assert [%{stop_reason: :end_turn}] = of_type(events, :agent_end)
      assert transcript_calls(events) == {["call_d1"], ["call_d1"]}
      assert [{0, %{"success" => true, "contentItems" => [%{"text" => text}]}}] = answers(bin, 1)
      assert text =~ "hello"
      assert [%{harness_session_id: id}] = of_type(events, :provider_session)
      assert digest?(id)
    end

    test "an abort while the tool runs kills it, answers aborted, then interrupts, and keeps the program",
         %{bin: bin} = ctx do
      ctx = tools_core(ctx)
      pidfile = Path.join(bin, "pid")
      command = sleeper(pidfile)
      fresh(bin, 1, tid(), running(command))

      on(bin, 1, "turn/interrupt", [
        completed(tid(), Map.put(bash("call_d1", command), :status, "failed")),
        j(%{id: "@", result: %{}}),
        turn_end(tid(), "interrupted")
      ])

      session = start(ctx)
      :ok = Session.prompt(session, "sleep")
      pid = wait_for_pid(pidfile)
      :ok = Session.abort(session)

      assert [%{stop_reason: :aborted}] = of_type(collect_until(:agent_end), :agent_end)
      assert gone_within?(pid)

      lines = stdin(bin, 1)
      answer = Enum.find_index(lines, &match?(%{"id" => 0, "result" => _}, &1))
      interrupt = Enum.find_index(lines, &(&1["method"] == "turn/interrupt"))
      assert answer < interrupt

      assert %{"result" => %{"success" => false, "contentItems" => [%{"text" => "aborted"}]}} =
               Enum.at(lines, answer)

      assert runs(bin) == "1"
      GenServer.stop(Session.pid(session))
    end

    test "a crash of the program while the tool runs fails the turn and kills the tool",
         %{bin: bin} = ctx do
      ctx = tools_core(ctx)
      pidfile = Path.join(bin, "pid")
      command = sleeper(pidfile)
      crash = ~s{(while [ ! -f "#{pidfile}" ]; do sleep 0.02; done; kill $$) &\n}
      fresh(bin, 1, tid(), running(command), crash)

      session = start(ctx)
      :ok = Session.prompt(session, "sleep")
      pid = wait_for_pid(pidfile)

      assert [%{stop_reason: :error, error: {:provider_stop, {:codex_exit, _}}}] =
               of_type(collect_until(:agent_end), :agent_end)

      assert gone_within?(pid)
      GenServer.stop(Session.pid(session))
    end

    test "a normal end while the tool runs kills it and answers aborted", %{bin: bin} = ctx do
      ctx = tools_core(ctx)
      pidfile = Path.join(bin, "pid")
      command = sleeper(pidfile)
      failed = Map.put(bash("call_d1", command), :status, "failed")
      rest = [completed(tid(), failed), usage(tid()), turn_end(tid(), "completed")]
      fresh(bin, 1, tid(), running(command), after_file(bin, "rest", pidfile, rest))
      on(bin, 1, "turn/start", as_turn(turn(tid(), reply(tid(), "Next.")), "turn2"), "", 2)

      session = start(ctx)
      events = prompt(session, "sleep")
      pid = wait_for_pid(pidfile)

      assert [%{stop_reason: :end_turn}] = of_type(events, :agent_end)
      assert transcript_calls(events) == {["call_d1"], ["call_d1"]}

      # The next turn starts only after the hands' cleanup and the late
      # answer.
      assert [%{stop_reason: :end_turn}] = of_type(prompt(session, "next"), :agent_end)
      assert gone_within?(pid)

      assert [{0, %{"success" => false, "contentItems" => [%{"text" => "aborted"}]}}] =
               answers(bin, 1)

      GenServer.stop(Session.pid(session))
    end
  end
end
