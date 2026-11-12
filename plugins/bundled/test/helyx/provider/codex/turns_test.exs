defmodule Helyx.Provider.Codex.TurnsTest do
  # Turns in a session, resume, the replay of the history, and server requests.
  use ExUnit.Case, async: true

  import Helyx.Test.CodexFake
  import Helyx.Test.HarnessDriver, only: [pump: 4]
  import Helyx.Test.Events

  alias Helyx.{Message, Session}
  alias Helyx.Provider.{Codex, Fake}

  @moduletag :tmp_dir
  setup {Helyx.Test.CodexFake, :setup_fake}

  defp resumed(bin, n, tid, lines) do
    initialize(bin, n)
    on(bin, n, "thread/resume", [j(%{id: "@", result: %{thread: thread(tid)}})])
    on(bin, n, "turn/start", turn(tid, lines))
  end

  test "a turn: text, tool calls, and tool results join the transcript, and the id is stored",
       %{bin: bin} = ctx do
    fresh(
      bin,
      1,
      tid(),
      message(tid(), "msg_a", "I will list.") ++
        [
          started(tid(), command("exec-1", %{status: "inProgress"})),
          # A sub-agent's thread stays inside the harness.
          delta("019a0000-0000-7000-8000-00000000000f", "msg_x", "not mine"),
          completed(
            tid(),
            command("exec-1", %{status: "completed", aggregatedOutput: "a.txt\n", exitCode: 0})
          )
        ] ++ reply(tid(), "One file.")
    )

    session = start(ctx)
    events = prompt(session, "list the files")

    assert %{"params" => %{"clientInfo" => %{"name" => "helyx"}}} =
             request(bin, 1, "initialize")

    assert %{"method" => "initialized"} = Enum.at(stdin(bin, 1), 1)

    assert %{
             "params" => %{
               "approvalPolicy" => "never",
               "sandbox" => "danger-full-access",
               "model" => "gpt-6-luna",
               "cwd" => cwd
             }
           } = request(bin, 1, "thread/start")

    assert cwd == ctx.work
    assert request(bin, 1, "thread/inject_items") == nil

    assert %{"params" => %{"threadId" => tid(), "input" => [%{"text" => "list the files"}]}} =
             request(bin, 1, "turn/start")

    assert [%{provider: "codex", resume_id: stored_tid(), lost: false, cut: 0}] =
             of_type(events, :resume_id)

    call = %Message.ToolCall{
      id: "exec-1",
      name: "commandExecution",
      arguments: %{"command" => "/bin/zsh -lc ls", "cwd" => "/work"}
    }

    assert [
             %Message{role: :user},
             %Message{role: :assistant, stop_reason: :tool_use, model: "codex/gpt-6-luna"} =
               first,
             %Message{role: :assistant, stop_reason: :end_turn} = last
           ] = messages(events)

    assert first.content == [%Message.Text{text: "I will list."}, call]
    assert last.content == [%Message.Text{text: "One file."}]
    assert %Helyx.Usage{input: 12, output: 7, cache_read: 0, cache_write: 0} = last.usage

    assert [%{message: %Message{role: :tool_result, tool_call_id: "exec-1"} = result}] =
             of_type(events, :tool_execution_end)

    assert Message.text(result) == "a.txt\n"
    refute result.is_error
    assert [%{outcome: :done}] = of_type(events, :turn_end)

    assert {:ok, %{resume_ids: %{"codex" => {stored_tid(), 0, nil}}}} =
             Helyx.Test.SessionFile.resume(ctx.sessions, ctx.work)
  end

  test "a later turn runs in the same program, and a resumed session resumes the thread",
       %{bin: bin} = ctx do
    fresh(bin, 1, tid(), reply(tid(), "Hi."))
    on(bin, 1, "turn/start", as_turn(turn(tid(), reply(tid(), "Again.")), "turn2"), "", 2)
    resumed(bin, 2, tid(), reply(tid(), "Back."))

    session = start(ctx)
    prompt(session, "hello")
    events = prompt(session, "again")

    # One program: no start, no resume, and only the prompt.
    assert runs(bin) == "1"
    assert request(bin, 1, "thread/resume") == nil

    assert [_, %{"params" => %{"threadId" => tid(), "input" => [%{"text" => "again"}]}}] =
             for(%{"method" => "turn/start"} = line <- stdin(bin, 1), do: line)

    assert of_type(events, :resume_id) == []

    assert [%Message{role: :user}, %Message{content: [%Message.Text{text: "Again."}]}] =
             messages(events)

    # The session end closes the program: its input ends, and it exits.
    Helyx.Test.SessionFile.stop(session)
    {:ok, session, _} = Session.resume(ctx.core, sessions_dir: ctx.sessions, cwd: ctx.work)
    {:ok, _, _} = Session.subscribe(session)
    prompt(session, "back")

    assert %{
             "params" => %{
               "threadId" => tid(),
               "excludeTurns" => true,
               "approvalPolicy" => "never",
               "sandbox" => "danger-full-access"
             }
           } = request(bin, 2, "thread/resume")

    assert request(bin, 2, "thread/start") == nil
    assert request(bin, 2, "thread/inject_items") == nil
    assert %{"params" => %{"input" => [%{"text" => "back"}]}} = request(bin, 2, "turn/start")
  end

  test "a lost thread starts a fresh one in the same program, with the transcript replayed",
       %{bin: bin} = ctx do
    fresh(bin, 1, tid(), reply(tid(), "Hi."))
    fresh(bin, 2, fresh_tid(), reply(fresh_tid(), "Fresh."))

    on(bin, 2, "thread/resume", [
      j(%{id: "@", error: %{code: -32_600, message: "no rollout found for thread id #{tid()}"}})
    ])

    session = start(ctx)
    prompt(session, "hello")
    Helyx.Test.SessionFile.stop(session)
    {:ok, session, _} = Session.resume(ctx.core, sessions_dir: ctx.sessions, cwd: ctx.work)
    {:ok, _, _} = Session.subscribe(session)
    events = prompt(session, "again")

    assert runs(bin) == "2"
    assert %{"params" => %{"threadId" => tid()}} = request(bin, 2, "thread/resume")
    assert %{"params" => %{"model" => "gpt-6-luna"}} = request(bin, 2, "thread/start")

    assert %{
             "params" => %{
               "threadId" => fresh_tid(),
               "items" => [
                 %{
                   "type" => "message",
                   "role" => "user",
                   "content" => [%{"type" => "input_text", "text" => "hello"}]
                 },
                 %{
                   "type" => "message",
                   "role" => "assistant",
                   "content" => [%{"type" => "output_text", "text" => "Hi."}]
                 }
               ]
             }
           } = request(bin, 2, "thread/inject_items")

    assert %{"params" => %{"threadId" => fresh_tid(), "input" => [%{"text" => "again"}]}} =
             request(bin, 2, "turn/start")

    assert [%{resume_id: stored_fresh_tid(), lost: true, cut: 0}] =
             of_type(events, :resume_id)

    assert [%Message{role: :user}, %Message{content: [%Message.Text{text: "Fresh."}]}] =
             messages(events)

    assert {:ok, %{resume_ids: %{"codex" => {stored_fresh_tid(), 1, nil}}}} =
             Helyx.Test.SessionFile.resume(ctx.sessions, ctx.work)
  end

  test "a switch to a codex model replays the history, tool calls too", %{bin: bin} = ctx do
    long = String.duplicate("i", 65)

    calls = [
      %Message.ToolCall{id: "call:1", name: "read", arguments: %{"path" => "a"}},
      %Message.ToolCall{id: long, name: "mcp/srv.tool", arguments: %{}}
    ]

    :ok = Fake.script(ctx.core, "m", [calls, ["Read it."]])
    fresh(bin, 1, tid(), reply(tid(), "Done."))

    session = start(ctx, "fake/m")
    prompt(session, "read a")
    :ok = Session.set_model(session, "codex/gpt-6-luna")
    events = prompt(session, "and now?")

    assert request(bin, 1, "thread/resume") == nil

    assert %{
             "params" => %{
               "items" => [
                 %{"type" => "message", "role" => "user"},
                 %{"type" => "function_call"} = read,
                 %{"type" => "function_call"} = mcp,
                 %{"type" => "function_call_output"} = read_result,
                 %{"type" => "function_call_output"} = mcp_result,
                 %{"type" => "message", "role" => "assistant"}
               ]
             }
           } = request(bin, 1, "thread/inject_items")

    assert %{"name" => "read", "arguments" => ~s({"path":"a"}), "call_id" => "h_" <> _ = id} =
             read

    assert byte_size(id) == 64
    assert read_result["call_id"] == id
    assert %{"name" => "mcp_srv_tool", "call_id" => "h_" <> _ = long_id} = mcp
    assert byte_size(long_id) == 64 and long_id != id
    assert mcp_result["call_id"] == long_id
    assert is_binary(read_result["output"])
    assert [%{lost: false, cut: 0}] = of_type(events, :resume_id)
  end

  test "a failed turn fails the turn with its error", %{bin: bin} = ctx do
    fresh(bin, 1, tid(), [
      started(tid(), command("exec-a", %{status: "inProgress"})),
      started(tid(), %{search() | id: "exec-b"}),
      completed(
        tid(),
        command("exec-a", %{status: "failed", aggregatedOutput: "no", exitCode: 2})
      ),
      completed(tid(), %{search() | id: "exec-b", status: "failed"}),
      turn_end(tid(), "failed", "usage limit")
    ])

    events = prompt(start(ctx), "go")

    assert [%{outcome: :error, error: "codex: usage limit"}] = of_type(events, :turn_end)

    assert [
             %{message: %Message{tool_call_id: "exec-a", is_error: true}},
             %{message: %Message{tool_call_id: "exec-b", is_error: true}}
           ] = of_type(events, :tool_execution_end)
  end

  test "the error text of a failed turn is cut at 2,000 bytes, not in a character",
       %{bin: bin} = ctx do
    fresh(bin, 1, tid(), [turn_end(tid(), "failed", "a" <> String.duplicate("é", 1_000))])

    assert [%{outcome: :error, error: "codex: " <> text}] =
             of_type(prompt(start(ctx), "go"), :turn_end)

    assert byte_size(text) == 1_999 and String.valid?(text)
  end

  test "an approval request with no item is declined at once; any other server request gets an error",
       %{bin: bin, work: work} do
    fresh(
      bin,
      1,
      tid(),
      [
        j(%{id: 0, method: "item/commandExecution/requestApproval", params: %{threadId: tid()}}),
        j(%{id: "r", method: "item/fileChange/requestApproval", params: %{threadId: tid()}}),
        j(%{id: 7, method: "item/tool/requestUserInput", params: %{threadId: tid()}}),
        j(%{id: 8, method: "applyPatchApproval", params: %{conversationId: tid()}})
      ] ++ reply(tid(), "ok")
    )

    assert [{:resume_id, stored_tid(), 0}, {:text_delta, "ok"}, {:done, _}] =
             run_direct([Message.user("go")], work)

    answers =
      for %{"id" => id} = line <- stdin(bin, 1), not is_map_key(line, "method"), do: {id, line}

    assert [
             {0, %{"result" => %{"decision" => "decline"}}},
             {"r", %{"result" => %{"decision" => "decline"}}},
             {7, %{"error" => %{"code" => -32_601}}},
             {8, %{"error" => %{"code" => -32_601}}}
           ] = answers
  end

  # A request of another thread or turn whose item id names an open call of
  # the current turn must not get that call's decision.
  test "one item id in two threads and two turns: only the request of the thread and its turn goes to Core",
       %{bin: bin, work: work} do
    approval = fn id, thread, turn, item ->
      j(%{
        id: id,
        method: "item/fileChange/requestApproval",
        params: %{threadId: thread, turnId: turn, itemId: item}
      })
    end

    child = "019a0000-0000-7000-8000-00000000000f"

    fresh(bin, 1, tid(), [
      started(tid(), %{type: "fileChange", id: "call_1", changes: [], status: "inProgress"}),
      approval.(1, child, "turn1", "call_1"),
      approval.(2, tid(), "turn0", "call_1"),
      approval.(3, child, "turnc", "call_1"),
      approval.(0, tid(), "turn1", "call_1")
    ])

    {:ok, state} = connect(work)
    {_from, actions, state} = turn_on(state)

    {actions, state} =
      pump(Codex, state, actions, fn actions ->
        Enum.any?(actions, &match?({:event, _, {:approval, _, _}}, &1))
      end)

    assert [{:approval, "0", "call_1"}] =
             for({:event, "t1", {:approval, _, _} = event} <- actions, do: event)

    {_from, _actions, state} = ask(state, {:approval, "t1", "0", :allow})
    close(state)

    answers =
      for %{"id" => id} = line <- stdin(bin, 1), not is_map_key(line, "method"), do: {id, line}

    assert [
             {1, %{"result" => %{"decision" => "decline"}}},
             {2, %{"result" => %{"decision" => "decline"}}},
             {3, %{"result" => %{"decision" => "decline"}}},
             {0, %{"result" => %{"decision" => "accept"}}}
           ] = answers
  end

  # The type of the item binds the request to a call of the program's own
  # tools: a Helyx tool call (`dynamicToolCall`) gets no approval.
  test "an approval request for an item of another type, or for no open item, is declined at once",
       %{bin: bin, work: work} do
    approval = fn id, method, item ->
      j(%{
        id: id,
        method: method,
        params: %{threadId: tid(), turnId: "turn1", itemId: item}
      })
    end

    dynamic = %{
      type: "dynamicToolCall",
      id: "call_d",
      tool: "read",
      arguments: %{},
      status: "inProgress"
    }

    fresh(bin, 1, tid(), [
      started(tid(), dynamic),
      started(tid(), %{type: "fileChange", id: "call_f", changes: [], status: "inProgress"}),
      approval.(1, "item/fileChange/requestApproval", "call_d"),
      approval.(2, "item/commandExecution/requestApproval", "call_f"),
      approval.(3, "item/fileChange/requestApproval", "call_x"),
      j(%{id: 4, method: "item/fileChange/requestApproval"}),
      approval.(0, "item/fileChange/requestApproval", "call_f")
    ])

    {:ok, state} = connect(work)
    {_from, actions, state} = turn_on(state)

    {actions, state} =
      pump(Codex, state, actions, fn actions ->
        Enum.any?(actions, &match?({:event, _, {:approval, _, _}}, &1))
      end)

    assert [{:approval, "0", "call_f"}] =
             for({:event, "t1", {:approval, _, _} = event} <- actions, do: event)

    {_from, _actions, state} = ask(state, {:approval, "t1", "0", {:deny, "no"}})
    close(state)

    answers =
      for %{"id" => id} = line <- stdin(bin, 1), not is_map_key(line, "method"), do: {id, line}

    assert [
             {1, %{"result" => %{"decision" => "decline"}}},
             {2, %{"result" => %{"decision" => "decline"}}},
             {3, %{"result" => %{"decision" => "decline"}}},
             {4, %{"result" => %{"decision" => "decline"}}},
             {0, %{"result" => %{"decision" => "decline"}}}
           ] = answers
  end

  test "an approval request after the end of the Helyx turn is declined at once",
       %{bin: bin, work: work} do
    late =
      j(%{
        id: 5,
        method: "item/fileChange/requestApproval",
        params: %{threadId: tid(), turnId: "turn1", itemId: "call_1"}
      })

    fresh(bin, 1, tid(), reply(tid(), "ok") ++ [late])

    assert [{:resume_id, stored_tid(), 0}, {:text_delta, "ok"}, {:done, _}] =
             run_direct([Message.user("go")], work)

    assert [{5, %{"result" => %{"decision" => "decline"}}}] =
             for(
               %{"id" => id} = line <- stdin(bin, 1),
               not is_map_key(line, "method"),
               do: {id, line}
             )
  end

  # ADR 0013 §4; docs/research/codex-app-server.md, "An `apply_patch`
  # approval under `untrusted` and `read-only`".
  test "an approval request of an item is an approval event; Core's answer is accept or decline",
       %{bin: bin, work: work} do
    approval = fn id, method, item ->
      j(%{id: id, method: method, params: %{threadId: tid(), turnId: "turn1", itemId: item}})
    end

    fresh(bin, 1, tid(), [
      started(tid(), %{type: "fileChange", id: "call_1", changes: [], status: "inProgress"}),
      approval.(0, "item/fileChange/requestApproval", "call_1"),
      started(tid(), command("call_2", %{status: "inProgress"})),
      approval.("0", "item/commandExecution/requestApproval", "call_2")
    ])

    {:ok, state} = connect(work)
    {_from, actions, state} = turn_on(state)

    {actions, state} =
      pump(Codex, state, actions, fn actions ->
        Enum.count(actions, &match?({:event, _, {:approval, _, _}}, &1)) == 2
      end)

    # The JSON of the id: the integer 0 and the string "0" are two ids.
    assert [{:approval, "0", "call_1"}, {:approval, ~s("0"), "call_2"}] =
             for({:event, "t1", {:approval, _, _} = event} <- actions, do: event)

    {from, actions, state} = ask(state, {:approval, "t1", ~s("0"), {:deny, "no"}})
    assert [{:reply, ^from, :ok}] = actions
    {from, actions, state} = ask(state, {:approval, "t1", "0", :allow})
    assert [{:reply, ^from, :ok}] = actions
    close(state)

    answers =
      for %{"id" => id} = line <- stdin(bin, 1), not is_map_key(line, "method"), do: {id, line}

    assert [
             {"0", %{"result" => %{"decision" => "decline"}}},
             {0, %{"result" => %{"decision" => "accept"}}}
           ] = answers
  end

  # A tool name keeps its length, so two names that differ only after 64
  # characters stay different.
  test "a replayed call id keeps to the API limit and a tool name to its characters",
       %{bin: bin, work: work} do
    fresh(bin, 1, tid(), reply(tid(), "ok"))

    ids = [
      String.duplicate("a", 63),
      String.duplicate("b", 64),
      String.duplicate("c", 65),
      "é",
      "e",
      "",
      "f"
    ]

    names = [
      String.duplicate("l", 63),
      String.duplicate("n", 64),
      String.duplicate("m", 64) <> "x",
      "é" <> String.duplicate("o", 64),
      "",
      "p",
      String.duplicate("m", 64) <> "y"
    ]

    calls =
      Enum.zip_with(ids, names, &%Message.ToolCall{id: &1, name: &2, arguments: %{}})

    run_direct([%Message{role: :assistant, content: calls}, Message.user("go")], work)
    %{"params" => %{"items" => items}} = request(bin, 1, "thread/inject_items")
    [a63, b64 | _] = ids

    assert [^a63, ^b64, id65, id_multibyte, "e", "h_" <> _, "f"] =
             Enum.map(items, & &1["call_id"])

    assert "h_" <> _ = id65
    assert "h_" <> _ = id_multibyte
    assert byte_size(id65) == 64
    assert byte_size(id_multibyte) == 64
    assert id65 != id_multibyte

    assert Enum.map(items, & &1["name"]) == [
             String.duplicate("l", 63),
             String.duplicate("n", 64),
             String.duplicate("m", 64) <> "x",
             "_" <> String.duplicate("o", 64),
             "_",
             "p",
             String.duplicate("m", 64) <> "y"
           ]
  end

  test "a message with no deltas gives its text whole", %{bin: bin, work: work} do
    item = %{type: "agentMessage", id: "msg_1", text: "Whole."}
    fresh(bin, 1, tid(), [completed(tid(), item), turn_end(tid(), "completed")])

    assert [{:resume_id, stored_tid(), 0}, {:text_delta, "Whole."}, {:done, _}] =
             run_direct([Message.user("go")], work)
  end

  test "the replay keeps the newest messages within 400,000 bytes and never starts at a result",
       %{bin: bin, work: work} do
    fresh(bin, 1, tid(), reply(tid(), "ok"))
    big = String.duplicate("x", 150_000)
    call = %Message.ToolCall{id: "c1", name: "read", arguments: %{}}

    history = [
      %Message{role: :user, content: [%Message.Text{text: "old " <> big}]},
      %Message{role: :assistant, content: [%Message.Text{text: big <> big}, call]},
      %Message{role: :tool_result, tool_call_id: "c1", content: [%Message.Text{text: big}]},
      %Message{role: :assistant, content: [%Message.Text{text: "tail"}]},
      Message.user("go")
    ]

    # The result and the tail fit; the assistant message with the call does
    # not, so the replay starts after the result, at the tail.
    assert [{:resume_id, stored_tid(), 3} | _] = run_direct(history, work)

    assert %{"params" => %{"items" => [%{"content" => [%{"text" => "tail"}]}]}} =
             request(bin, 1, "thread/inject_items")
  end
end
