defmodule Helyx.Provider.ConformanceTest do
  # A harness gives the same Helyx events as an API provider for one
  # registered tool: the name, the arguments, the result, an error, and the
  # snapshot (docs/features/provider-parity.md). Two turns, each with one
  # `bash` call: `echo hi`, then a call with no command, which the tool
  # answers with an error.
  use ExUnit.Case, async: true

  import Helyx.Test.Events, only: [collect_until: 1, of_type: 2]
  require Helyx.Test.CodexFake

  alias Helyx.{Message, Session}
  alias Helyx.Provider.{ClaudeCode, Codex, Fake}
  alias Helyx.Test.{ClaudeCodeFake, CodexFake}

  @moduletag :tmp_dir

  @ok %{"command" => "echo hi"}
  @bad %{}

  defp core(provider) do
    core = :"core_#{System.unique_integer([:positive])}"

    start_supervised!(
      {Helyx.Core, name: core, plugins: Enum.uniq([provider, Fake, Helyx.Tool.Bash])},
      id: {:conformance_core, provider}
    )

    core
  end

  # The events and the snapshot of the two turns.
  defp run(ctx, core, model) do
    {:ok, session} =
      Session.start(core, model: model, cwd: ctx.work, sessions_dir: ctx.sessions <> model)

    {:ok, _, _} = Session.subscribe(session)
    events = for text <- ["run it", "again"], do: prompt(session, text)
    {:ok, snapshot, _ref} = Session.subscribe(session)
    GenServer.stop(Session.pid(session))
    {List.flatten(events), snapshot.messages}
  end

  defp prompt(session, text) do
    :ok = Session.prompt(session, text)
    collect_until(:turn_end)
  end

  defp api(ctx) do
    core = core(Fake)
    call = fn id, args -> %Message.ToolCall{id: id, name: "bash", arguments: args} end
    responses = [[call.("c1", @ok)], ["Ran."], [call.("c2", @bad)], ["Failed."]]
    :ok = Fake.script(core, "conf", responses)
    run(ctx, core, "fake/conf")
  end

  # What a provider must not change: the outcomes, the tool calls with
  # their results, and the messages without their ids, model, and usage.
  defp shape({events, messages}) do
    ends =
      for %{message: %Message{} = m} <- of_type(events, :tool_execution_end),
          do: {m.tool_name, Message.text(m), m.is_error}

    {Enum.map(of_type(events, :turn_end), & &1.outcome), ends, messages(messages)}
  end

  defp messages(messages) do
    ids =
      for(%Message{content: blocks} <- messages, %Message.ToolCall{id: id} <- blocks, do: id)
      |> Enum.with_index()
      |> Map.new()

    for m <- messages do
      blocks = Enum.map(m.content, &block(&1, ids))
      {m.role, blocks, ids[m.tool_call_id], m.tool_name, m.is_error}
    end
  end

  defp block(%Message.Text{text: text}, _ids), do: text

  defp block(%Message.ToolCall{id: id, name: name, arguments: args}, ids),
    do: {ids[id], name, args}

  describe "Claude Code" do
    setup {ClaudeCodeFake, :setup_fake}

    defp claude_call(n, args) do
      use = %{type: "tool_use", id: "toolu_#{n}", name: "mcp__helyx__bash", input: args}
      meta = %{"claudecode/toolUseId" => "toolu_#{n}"}
      params = %{name: "bash", arguments: args, _meta: meta}
      message = %{jsonrpc: "2.0", id: n, method: "tools/call", params: params}

      ClaudeCodeFake.begin() ++
        [ClaudeCodeFake.assistant(use), ClaudeCodeFake.mcp_request("m#{n}", message)]
    end

    # The answer to the K-th Helyx answer: the tool result, which the
    # program copies from the MCP answer (research note, "isError"), and
    # the reply.
    defp claude_after(bin, k, n, {result, error?}, text) do
      block = %{tool_use_id: "toolu_#{n}", type: "tool_result", content: result, is_error: error?}
      user = %{type: "user", message: %{role: "user", content: [block]}, parent_tool_use_id: nil}

      lines = [
        JSON.encode!(user),
        ClaudeCodeFake.delta(text),
        ClaudeCodeFake.assistant(%{type: "text", text: text}),
        ClaudeCodeFake.result(text, 2)
      ]

      File.write!(Path.join(bin, "out.after.#{k}"), Enum.map(lines, &[&1, "\n"]))
    end

    test "the same events and snapshot as an API provider", %{bin: bin} = ctx do
      ClaudeCodeFake.turn(bin, 1, 1, claude_call(1, @ok))
      ClaudeCodeFake.turn(bin, 1, 2, claude_call(2, @bad))
      claude_after(bin, 1, 1, {"hi\n", false}, "Ran.")
      claude_after(bin, 2, 2, {"bash needs a command", true}, "Failed.")

      File.write!(
        Path.join(bin, "resp.1"),
        ~s{answered=$((answered+1)); out "out.after.$answered"\n}
      )

      harness = run(ctx, core(ClaudeCode), "claude-code/haiku")
      assert shape(harness) == shape(api(ctx))
      assert {[:done, :done], [{"bash", _, false}, {"bash", _, true}], _} = shape(harness)
    end
  end

  describe "Codex" do
    setup {CodexFake, :setup_fake}

    defp dyn(n, status, args),
      do: %{
        type: "dynamicToolCall",
        id: "call_#{n}",
        tool: "bash",
        arguments: args,
        status: status
      }

    # The completed item copies the answer (schema of 0.163.0).
    defp answered(n, args, {result, error?}),
      do:
        Map.merge(dyn(n, "completed", args), %{
          contentItems: [%{type: "inputText", text: result}],
          success: not error?
        })

    defp codex_turn(bin, n, args, answer, text) do
      import CodexFake

      params = %{
        threadId: tid(),
        turnId: "turn1",
        callId: "call_#{n}",
        tool: "bash",
        arguments: args
      }

      call = j(%{id: 100 + n, method: "item/tool/call", params: params})
      rest = [completed(tid(), answered(n, args, answer))] ++ reply(tid(), text)
      lines_file(bin, "rest.#{n}", rest)

      # The rest of the turn waits for the N-th Helyx answer.
      tail =
        ~s{(while [ "$(grep -c contentItems "$d/stdin.$n")" -lt #{n} ]; do sleep 0.02; done; out "$d/rest.#{n}") &\n}

      on(
        bin,
        1,
        "turn/start",
        turn(tid(), [started(tid(), dyn(n, "inProgress", args)), call]),
        tail,
        n
      )
    end

    test "the same events and snapshot as an API provider", %{bin: bin} = ctx do
      CodexFake.fresh(bin, 1, CodexFake.tid(), [])
      codex_turn(bin, 1, @ok, {"hi\n", false}, "Ran.")
      codex_turn(bin, 2, @bad, {"bash needs a command", true}, "Failed.")

      harness = run(ctx, core(Codex), "codex/gpt-6-luna")
      assert shape(harness) == shape(api(ctx))
      assert {[:done, :done], [{"bash", _, false}, {"bash", _, true}], _} = shape(harness)
    end
  end
end
