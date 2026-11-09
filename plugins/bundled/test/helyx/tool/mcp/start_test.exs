defmodule Helyx.Tool.MCP.StartTest do
  # The start and the listing of MCP servers against the stub of
  # `Helyx.Test.MCPStub`, a local program (docs/features/mcp-client.md,
  # slice 9). The tests set the app env of `helyx_plugins`, so they run
  # one at a time.
  use ExUnit.Case, async: false

  import Helyx.Test.MCPStub, only: [server: 2, tool: 1, tool: 2, config: 2, log: 1]

  alias Helyx.Message.ToolCall
  alias Helyx.Provider.Fake
  alias Helyx.Session
  alias Helyx.Session.ToolRegistry

  @moduletag :tmp_dir

  # The start bound of these tests, in place of 30 s.
  @wait_ms 1_500
  # Room for a loaded machine in a wait for a state that must come.
  @load_ms 20_000

  setup %{tmp_dir: dir} do
    # The test helper's config, which names no file, comes back after each.
    config = Application.get_env(:helyx_plugins, :mcp_config)
    on_exit(fn -> Application.put_env(:helyx_plugins, :mcp_config, config) end)

    for key <- [:mcp_wait_ms, :mcp_watchdog_exe] do
      on_exit(fn -> Application.delete_env(:helyx_plugins, key) end)
    end

    Application.put_env(:helyx_plugins, :mcp_wait_ms, @wait_ms)
    core = :"core_#{System.unique_integer([:positive])}"

    start_supervised!(
      {Helyx.Core, name: core, plugins: [Fake, Helyx.Tool.ToolSearch, Helyx.Tool.MCP]},
      id: core
    )

    %{core: core, dir: dir}
  end

  # A session whose model gives `script`, after the config of `servers`.
  defp start(%{core: core, dir: dir}, servers, script \\ []) do
    Application.put_env(:helyx_plugins, :mcp_config, config(dir, servers))
    model = "mcp_#{System.unique_integer([:positive])}"
    :ok = Fake.script(core, model, script)
    {:ok, session} = Session.start(core, model: "fake/#{model}", cwd: dir)
    {:ok, _snapshot, _ref} = Session.subscribe(session)
    session
  end

  defp view(session),
    do: ToolRegistry.view(:sys.get_state(Session.pid(session)).registry, [])

  # The state of the group of `name` once `done?` holds for it.
  defp group(session, name, done? \\ &(&1 != :starting)) do
    until = System.monotonic_time(:millisecond) + @load_ms

    Stream.repeatedly(fn ->
      group = Enum.find(view(session).groups, &(&1.group == name))
      if group && done?.(group.state), do: group, else: Process.sleep(20) && nil
    end)
    |> Enum.find(&(&1 || System.monotonic_time(:millisecond) > until))
  end

  defp names(session), do: view(session).entries |> Enum.map(& &1.name) |> Enum.sort()

  defp results(count) do
    for _ <- 1..count do
      assert_receive {:helyx_event,
                      %Helyx.Event{type: :tool_execution_end, data: %{message: message}}},
                     @load_ms

      {message.is_error, Helyx.Message.text(message)}
    end
  end

  # A model turn that activates `name` with `tool_search`, then calls it.
  defp search_and_call(name, args) do
    [
      [%ToolCall{id: "c1", name: "tool_search", arguments: %{"query" => name}}],
      [%ToolCall{id: "c2", name: name, arguments: args}],
      ["Done."]
    ]
  end

  defp notices do
    receive do
      {:helyx_event, %Helyx.Event{type: :notice, data: %{text: text}}} -> [text | notices()]
    after
      0 -> []
    end
  end

  test "a server lists its tools in pages as deferred tools, and a task-only tool is left out",
       ctx do
    pages = [
      [tool("echo"), tool("alpha")],
      [tool("beta"), tool("job", %{"execution" => %{"taskSupport" => "required"}})]
    ]

    session = start(ctx, %{"s" => server(ctx.dir, %{"pages" => pages})})
    assert %{state: :ready, tools: 3} = group(session, "s")
    assert names(session) == ["s__alpha", "s__beta", "s__echo"]
    assert "MCP server s: 1 tools were left out: they need tasks" in notices()
  end

  test "a tool of a bad shape is left out alone", ctx do
    pages = [[tool("echo"), tool("bad", %{"execution" => "x"}), %{"name" => 7}, "x"]]
    session = start(ctx, %{"s" => server(ctx.dir, %{"pages" => pages})})
    assert %{state: :ready} = group(session, "s")
    assert names(session) == ["s__bad", "s__echo"]
  end

  test "two MCP names that map to one name keep the first, with a notice of Core", ctx do
    session = start(ctx, %{"s" => server(ctx.dir, %{"pages" => [[tool("a.b"), tool("a_b")]]})})
    assert %{state: :ready, tools: 1} = group(session, "s")
    assert names(session) == ["s__a_b"]
    assert Enum.any?(notices(), &(&1 =~ "s__a_b"))
  end

  test "a nextCursor that is not a string fails the server", ctx do
    spec = %{"pages" => [[tool("echo")]], "cursor" => 5}
    session = start(ctx, %{"s" => server(ctx.dir, spec)})

    assert %{state: {:error, "tools/list: a nextCursor that is not a string"}} =
             group(session, "s")
  end

  test "a server gets the kept variables of the node and its config env, no other", ctx do
    System.put_env("HELYX_MCP_TEST_SECRET", "s")
    on_exit(fn -> System.delete_env("HELYX_MCP_TEST_SECRET") end)
    log = Path.join(ctx.dir, "env.log")
    names = ["PATH", "STUB_X", "HELYX_MCP_TEST_SECRET"]
    entry = Map.put(server(ctx.dir, %{"env" => names, "log" => log}), "env", %{"STUB_X" => "x"})
    session = start(ctx, %{"s" => entry})
    assert %{state: :ready} = group(session, "s")
    assert env = Enum.find_value(log(log), & &1["env"])
    assert env["STUB_X"] == "x"
    assert env["HELYX_MCP_TEST_SECRET"] == nil
    assert is_binary(env["PATH"])
  end

  test "a ping of the server gets {}, and another request -32601", ctx do
    log = Path.join(ctx.dir, "requests.log")

    requests = [
      %{"jsonrpc" => "2.0", "id" => "p1", "method" => "ping"},
      %{"jsonrpc" => "2.0", "id" => "s1", "method" => "sampling/createMessage", "params" => %{}}
    ]

    session = start(ctx, %{"s" => server(ctx.dir, %{"requests" => requests, "log" => log})})
    assert %{state: :ready} = group(session, "s")
    Process.sleep(100)
    answers = Map.new(log(log), &{&1["id"], &1})
    assert answers["p1"]["result"] == %{}
    assert answers["s1"]["error"]["code"] == -32601
  end

  test "a call runs on its server, and list_changed lists the tools again", ctx do
    spec = %{"pages" => [[tool("changed")]], "relist" => [[tool("changed"), tool("fresh")]]}
    session = start(ctx, %{"s" => server(ctx.dir, spec)}, search_and_call("s__changed", %{}))
    assert %{state: :ready} = group(session, "s")
    :ok = Session.prompt(session, "go")
    assert [{false, _search}, {false, "ok"}] = results(2)
    assert %{tools: 2} = group(session, "s", fn _ -> "s__fresh" in names(session) end)
  end

  test "a server that stops answering a listing after its start fails at the bound", ctx do
    spec = %{"pages" => [[tool("changed")]], "relist" => nil}
    session = start(ctx, %{"s" => server(ctx.dir, spec)}, search_and_call("s__changed", %{}))
    assert %{state: :ready} = group(session, "s")
    :ok = Session.prompt(session, "go")
    assert [{false, _search}, {false, "ok"}] = results(2)

    assert %{state: {:error, "a listing of tools did not end in 1 s"}} =
             group(session, "s", &match?({:error, _}, &1))
  end

  test "a server whose protocol version Helyx does not speak is failed", ctx do
    session = start(ctx, %{"s" => server(ctx.dir, %{"version" => "1999-01-01"})})

    assert %{state: {:error, "initialize: a protocol version that Helyx does not speak"}} =
             group(session, "s")
  end

  test "a refused config starts no server and gives one notice", ctx do
    path = config(ctx.dir, %{"s" => server(ctx.dir, %{})})
    File.chmod!(path, 0o622)
    Application.put_env(:helyx_plugins, :mcp_config, path)
    model = "mcp_#{System.unique_integer([:positive])}"
    :ok = Fake.script(ctx.core, model, [])
    {:ok, session} = Session.start(ctx.core, model: "fake/#{model}", cwd: ctx.dir)
    {:ok, _snapshot, _ref} = Session.subscribe(session)

    assert_receive {:helyx_event, %Helyx.Event{type: :notice, data: %{text: text}}}, @load_ms
    assert text =~ "is writable by others; no MCP server starts"
    assert view(session).groups == []
  end

  test "a stalled server fails alone at the bound while another lists and runs a call", ctx do
    pid_file = Path.join(ctx.dir, "stalled.pid")
    stall = Path.join(ctx.dir, "stall")
    File.write!(stall, "#!/bin/sh\necho $$ > #{pid_file}\nread x\n")
    File.chmod!(stall, 0o755)
    Application.put_env(:helyx_plugins, :mcp_watchdog_exe, %{"a" => stall})
    servers = %{"a" => server(ctx.dir, %{}), "b" => server(ctx.dir, %{})}
    started = System.monotonic_time(:millisecond)
    session = start(ctx, servers, search_and_call("b__echo", %{"x" => 1}))

    # B is ready, and its tool is found and runs, while A is in its start.
    assert %{state: :ready} = group(session, "b")
    :ok = Session.prompt(session, "go")
    assert [{false, search}, {false, ~s(echo {"x":1})}] = results(2)
    assert search =~ "b__echo"
    assert %{state: :starting} = Enum.find(view(session).groups, &(&1.group == "a"))
    assert System.monotonic_time(:millisecond) - started < @wait_ms

    assert %{state: {:error, "did not start in 1 s"}} = group(session, "a")
    assert %{state: :ready} = group(session, "b")
    # The closed port ended the stalled program at the end of its input.
    stalled = pid_file |> File.read!() |> String.trim()
    assert Helyx.Test.OSHelpers.gone_within?(stalled)
  end

  test "a server that exits after its start is failed", ctx do
    entry = %{"command" => "/bin/sh", "args" => ["-c", "exit 3"]}
    session = start(ctx, %{"s" => entry})
    assert %{state: {:error, _reason}} = group(session, "s")
  end
end
