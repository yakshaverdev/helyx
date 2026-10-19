defmodule Helyx.Provider.ClaudeCode.HelyxToolsTest do
  # The Helyx tools: the MCP server of the provider in the program.
  use ExUnit.Case, async: true

  import Helyx.Test.ClaudeCodeFake
  import Helyx.Test.Events
  import Helyx.Test.HarnessDriver

  alias Helyx.{Message, Session}
  alias Helyx.Provider.{ClaudeCode, Fake}

  @moduletag :tmp_dir

  setup {Helyx.Test.ClaudeCodeFake, :setup_fake}

  describe "the Helyx tools" do
    @spec_bash %{name: "bash", description: "Runs a command.", parameters: %{"type" => "object"}}

    # The Helyx file tools, which the program gets as any other tool.
    @file_tools for name <- ~w(read edit write),
                    do: %{name: name, description: "", parameters: %{}}

    # A line that changes the state, so a test knows that the lines before
    # it were read.
    defp marker, do: j(%{type: "system", subtype: "background_tasks_changed", tasks: ["marker"]})
    defp marked?(state), do: state.tasks == ["marker"]

    defp tool_turn(work) do
      {:ok, state} = ClaudeCode.init("haiku", [@spec_bash], cwd: work)

      {_from, actions, state} =
        request(state, {:turn, "t1", %Helyx.Context{messages: [Message.user("x")]}})

      pump(ClaudeCode, state, actions, fn actions ->
        Enum.any?(actions, &match?({:event, _, {:tool_request, _, _, _}}, &1))
      end)
    end

    test "the program starts at the first turn with only the helyx server, no tools, commands, or user config of its own, and the turn's prompt",
         %{bin: bin, work: work} do
      state = harness(work)
      assert state.port == nil
      context = %Helyx.Context{system: "Be brief.", messages: [Message.user("x")]}
      {_from, _actions, state} = request(state, {:turn, "t1", context})
      closed(state)
      args = args(bin, 1)
      assert ~s({"mcpServers":{"helyx":{"type":"sdk","name":"helyx","alwaysLoad":true}}}) in args

      for flag <- ~w(--tools= --setting-sources= --strict-mcp-config --system-prompt=
                     --system-prompt-snapshot=off --disable-slash-commands),
          do: assert(flag in args)

      refute Enum.any?(args, &String.starts_with?(&1, "--disallowedTools"))
      assert initialize(bin, 1) == "Be brief."
    end

    test "a nil system is the empty prompt, never the program's own", %{bin: bin, work: work} do
      {_from, _actions, state} =
        request(harness(work), {:turn, "t1", %Helyx.Context{messages: [Message.user("x")]}})

      closed(state)
      assert initialize(bin, 1) == ""
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

      {:ok, state} = ClaudeCode.init("haiku", @file_tools ++ [@spec_bash], cwd: work)

      {_from, _actions, state} =
        request(state, {:turn, "t1", %Helyx.Context{messages: [Message.user("x")]}})

      closed(settle(ClaudeCode, state, &marked?/1))

      result = %{
        "protocolVersion" => "2025-11-25",
        "capabilities" => %{"tools" => %{}},
        "serverInfo" => %{"name" => "helyx", "version" => "0.1.0"}
      }

      tools =
        for spec <- @file_tools ++ [@spec_bash],
            do: %{
              "name" => spec.name,
              "description" => spec.description,
              "inputSchema" => spec.parameters
            }

      assert %{
               "i1" => %{"id" => 0, "result" => ^result},
               "i2" => %{"jsonrpc" => "2.0", "result" => %{}} = ack,
               "i3" => %{"id" => 1, "result" => %{"tools" => ^tools}},
               "i4" => %{"id" => 2, "result" => ^result},
               "i5" => %{"id" => 3, "error" => %{"code" => -32_601}},
               "i6" => %{"id" => 4, "error" => %{"code" => -32_601}},
               "i7" => %{"id" => 5, "error" => %{"code" => -32_601}},
               "i8" => %{"id" => 6, "result" => %{"protocolVersion" => "2025-06-18"}}
             } = answers(bin, 1)

      refute Map.has_key?(ack, "id")
    end

    test "a tools/call gives a tool request, and its result goes back as an MCP result",
         %{bin: bin, work: work} do
      turn(bin, 1, 1, begin() ++ [call("m1", 2, "toolu_h1")])
      {actions, state} = tool_turn(work)

      assert {:event, "t1", {:tool_request, "toolu_h1", "bash", %{"command" => "cat a.txt"}}} =
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

    test "a tools/call with no tool use id, before the turn's start, or of a tool not given gets an error",
         %{bin: bin, work: work} do
      script(bin, "start.1", [call("n1", 1, "toolu_early"), marker()])
      no_params = %{jsonrpc: "2.0", id: 3, method: "tools/call"}
      read = %{name: "read", arguments: %{path: "a.txt"}, _meta: %{"claudecode/toolUseId" => "r"}}
      not_listed = %{jsonrpc: "2.0", id: 4, method: "tools/call", params: read}

      turn(
        bin,
        1,
        1,
        begin() ++
          [
            tools_call("n2", 2, %{progressToken: 2}),
            mcp_request("n3", no_params),
            mcp_request("n4", not_listed),
            result("done")
          ]
      )

      {:ok, state} = ClaudeCode.init("haiku", [@spec_bash], cwd: work)

      {_from, actions, state} =
        request(state, {:turn, "t1", %Helyx.Context{messages: [Message.user("x")]}})

      {actions, state} = pump(ClaudeCode, state, actions, &ended?/1)
      closed(state)

      refute Enum.any?(actions, &match?({:event, _, {:tool_request, _, _, _}}, &1))

      assert %{
               "n1" => %{
                 "id" => 1,
                 "result" => %{
                   "isError" => true,
                   "content" => [%{"text" => "the call does not map to a tool use"}]
                 }
               },
               "n2" => %{"id" => 2, "result" => %{"isError" => true}},
               "n3" => %{"id" => 3, "result" => %{"isError" => true}},
               "n4" => %{
                 "id" => 4,
                 "result" => %{
                   "isError" => true,
                   "content" => [%{"text" => "the call does not map to a tool use"}]
                 }
               }
             } = answers(bin, 1)
    end

    test "a call whose name is not a string gets an error", %{bin: bin, work: work} do
      bad_name = %{name: 5, _meta: %{"claudecode/toolUseId" => "toolu_n"}}
      name_call = %{jsonrpc: "2.0", id: 6, method: "tools/call", params: bad_name}

      turn(
        bin,
        1,
        1,
        begin() ++ [mcp_request("r5", name_call), result("done")]
      )

      {:ok, state} = ClaudeCode.init("haiku", [@spec_bash], cwd: work)

      {_from, actions, state} =
        request(state, {:turn, "t1", %Helyx.Context{messages: [Message.user("x")]}})

      {actions, state} = pump(ClaudeCode, state, actions, &ended?/1)
      closed(state)

      refute Enum.any?(actions, &match?({:event, _, {:tool_request, _, _, _}}, &1))

      assert %{"r5" => %{"id" => 6, "result" => %{"isError" => true}}} = answers(bin, 1)
    end

    test "notifications/cancelled forgets the call and gives no action; its later result is not written",
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

      state = settle(ClaudeCode, state, &(&1.calls == %{}), &(&1 == []))

      {from, [{:reply, from, :ok}], state} =
        request(state, {:tool_result, "t1", "toolu_h1", {:ok, "late"}})

      closed(state)

      assert %{"c1" => %{"result" => %{}}} = answers = answers(bin, 1)
      refute Map.has_key?(answers, "m1")
    end

    test "in a session: the tool runs on the hands, and the transcript has one call and one result",
         %{bin: bin, work: work, sessions: sessions} do
      core = :"core_#{System.unique_integer([:positive])}"

      start_supervised!({Helyx.Core, name: core, plugins: [ClaudeCode, Fake, Helyx.Tool.Bash]},
        id: :tools_core
      )

      File.write!(Path.join(work, "a.txt"), "hello\n")

      use_block = %{
        type: "tool_use",
        id: "toolu_h1",
        name: "mcp__helyx__bash",
        input: %{command: "cat a.txt"}
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

      assert [%{outcome: :done}] = of_type(events, :turn_end)

      transcript =
        messages(events) ++ for(%{message: m} <- of_type(events, :tool_execution_end), do: m)

      calls =
        for %Message{content: blocks} <- transcript, %Message.ToolCall{} = c <- blocks, do: c

      assert [%Message.ToolCall{id: "toolu_h1", name: "bash"}] = calls

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
