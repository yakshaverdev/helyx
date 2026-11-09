defmodule Helyx.Tool.MCP.CallTest do
  # The calls of MCP tools against the stub of `Helyx.Test.MCPStub`: the
  # time limit, the abort, the restart of decision 14 and its cap, and the
  # isolation of decision 15 (docs/features/mcp-client.md, slice 10). The
  # tests set the app env of `helyx_plugins`, so they run one at a time.
  use ExUnit.Case, async: false

  import Helyx.Test.MCPStub, only: [server: 2, tool: 1, config: 2, log: 1]

  alias Helyx.Message.ToolCall
  alias Helyx.Provider.Fake
  alias Helyx.Session
  alias Helyx.Session.ToolRegistry

  @moduletag :tmp_dir

  # The time limit of a call in these tests, in place of 60 s.
  @call_ms 1_000
  # Room for a loaded machine in a wait for a state that must come.
  @load_ms 20_000

  setup %{tmp_dir: dir} do
    config = Application.get_env(:helyx_plugins, :mcp_config)
    on_exit(fn -> Application.put_env(:helyx_plugins, :mcp_config, config) end)
    on_exit(fn -> Application.delete_env(:helyx_plugins, :mcp_call_ms) end)
    Application.put_env(:helyx_plugins, :mcp_call_ms, @call_ms)
    core = :"core_#{System.unique_integer([:positive])}"

    start_supervised!(
      {Helyx.Core, name: core, plugins: [Fake, Helyx.Tool.ToolSearch, Helyx.Tool.MCP]},
      id: core
    )

    %{core: core, dir: dir, log: Path.join(dir, "stub.log")}
  end

  defp start(%{core: core, dir: dir}, servers, script) do
    Application.put_env(:helyx_plugins, :mcp_config, config(dir, servers))
    model = "mcp_#{System.unique_integer([:positive])}"
    :ok = Fake.script(core, model, script ++ [["Done."]])
    {:ok, session} = Session.start(core, model: "fake/#{model}", cwd: dir)
    {:ok, _snapshot, _ref} = Session.subscribe(session)
    session
  end

  defp view(session),
    do: ToolRegistry.view(:sys.get_state(Session.pid(session)).registry, [])

  defp group(session, name, done?) do
    until = System.monotonic_time(:millisecond) + @load_ms

    Stream.repeatedly(fn ->
      group = Enum.find(view(session).groups, &(&1.group == name))
      if group && done?.(group.state), do: group, else: Process.sleep(20) && nil
    end)
    |> Enum.find(&(&1 || System.monotonic_time(:millisecond) > until))
  end

  defp ready(session, name), do: group(session, name, &(&1 == :ready))

  defp search(id, name),
    do: [%ToolCall{id: id, name: "tool_search", arguments: %{"query" => name}}]

  defp call(id, name, args \\ %{}), do: [%ToolCall{id: id, name: name, arguments: args}]

  defp results(count) do
    for _ <- 1..count do
      assert_receive {:helyx_event,
                      %Helyx.Event{type: :tool_execution_end, data: %{message: message}}},
                     @load_ms

      {message.is_error, Helyx.Message.text(message)}
    end
  end

  defp starts(log), do: for(%{"start" => pid} <- log(log), do: Integer.to_string(pid))

  defp alive?(pid), do: match?({_, 0}, System.cmd("kill", ["-0", pid], stderr_to_stdout: true))

  test "a call past the time limit cancels and stops its server, and a later call runs on a new one",
       ctx do
    spec = %{"pages" => [[tool("hang"), tool("echo")]], "log" => ctx.log}

    script = [
      search("c1", "s__hang"),
      call("c2", "s__hang"),
      search("c3", "s__echo"),
      call("c4", "s__echo", %{"x" => 1})
    ]

    session = start(ctx, %{"s" => server(ctx.dir, spec)}, script)
    assert ready(session, "s")
    :ok = Session.prompt(session, "go")

    assert [_search, hang, _search2, echo] = results(4)
    assert hang == {true, "timed out after 1 s; the call may have run"}
    assert echo == {false, ~s(echo {"x":1})}
    assert [old, new] = starts(ctx.log)
    refute alive?(old)
    assert alive?(new)

    assert [%{"params" => %{"requestId" => _id}}] =
             for(%{"method" => _} = m <- log(ctx.log), do: m)
  end

  test "an abort stops the server's group before it returns, and the server starts again", ctx do
    spec = %{"pages" => [[tool("hang"), tool("echo")]], "log" => ctx.log}
    Application.put_env(:helyx_plugins, :mcp_call_ms, 60_000)

    session =
      start(ctx, %{"s" => server(ctx.dir, spec)}, [search("c1", "s__hang"), call("c2", "s__hang")])

    assert ready(session, "s")
    :ok = Session.prompt(session, "go")
    assert [_search] = results(1)
    # The hang call reached the server Task.
    Process.sleep(200)
    [old] = starts(ctx.log)

    :ok = Session.abort(session)
    refute alive?(old)

    until = System.monotonic_time(:millisecond) + @load_ms

    Stream.repeatedly(fn -> Process.sleep(20) && starts(ctx.log) end)
    |> Enum.find(&(length(&1) == 2 or System.monotonic_time(:millisecond) > until))

    assert [^old, _new] = starts(ctx.log)
    assert ready(session, "s")
  end

  test "a call whose limit passes while its server starts again is not sent", ctx do
    Application.put_env(:helyx_plugins, :mcp_call_ms, 300)
    spec = %{"pages" => [[tool("hang"), tool("echo")]], "log" => ctx.log}
    # Each start of the server takes half a second.
    %{"command" => perl, "args" => args} = server(ctx.dir, spec)

    entry = %{
      "command" => "/bin/sh",
      "args" => ["-c", ~S(sleep 0.5; exec "$@"), "sh", perl | args]
    }

    script = [
      search("c1", "s__hang"),
      search("c2", "s__echo"),
      call("c3", "s__hang"),
      call("c4", "s__echo", %{"x" => 1})
    ]

    session = start(ctx, %{"s" => entry}, script)
    assert ready(session, "s")
    :ok = Session.prompt(session, "go")

    assert [_search, _search2, {true, "timed out after 0 s; the call may have run"}, echo] =
             results(4)

    assert echo ==
             {true, "timed out after 0 s: the MCP server did not start, the call did not run"}
  end

  test "a delivered call stops no group: the next call runs on the same server", ctx do
    spec = %{"pages" => [[tool("echo")]], "log" => ctx.log}

    script = [
      search("c1", "s__echo"),
      call("c2", "s__echo", %{"n" => 1}),
      call("c3", "s__echo", %{"n" => 2})
    ]

    session = start(ctx, %{"s" => server(ctx.dir, spec)}, script)
    assert ready(session, "s")
    :ok = Session.prompt(session, "go")
    assert [_search, {false, ~s(echo {"n":1})}, {false, ~s(echo {"n":2})}] = results(3)
    assert [_one] = starts(ctx.log)
  end

  @tag timeout: 120_000
  test "the fourth call with no response fails the server", ctx do
    # Room for each start again inside the next call's limit.
    Application.put_env(:helyx_plugins, :mcp_call_ms, 1_500)
    spec = %{"pages" => [[tool("hang")]], "log" => ctx.log}
    script = [search("c1", "s__hang") | for(n <- 2..5, do: call("c#{n}", "s__hang"))]
    session = start(ctx, %{"s" => server(ctx.dir, spec)}, script)
    assert ready(session, "s")
    :ok = Session.prompt(session, "go")
    assert [_search | hangs] = results(5)
    assert Enum.all?(hangs, &(&1 == {true, "timed out after 1 s; the call may have run"}))

    assert %{state: {:error, "did not answer a call 4 times"}} =
             group(session, "s", &match?({:error, _}, &1))

    assert length(starts(ctx.log)) == 4
  end

  test "a server whose watchdog dies leaves another server's tools callable", ctx do
    log_a = Path.join(ctx.dir, "a.log")
    servers = %{"a" => server(ctx.dir, %{"log" => log_a}), "b" => server(ctx.dir, %{})}
    session = start(ctx, servers, [search("c1", "b__echo"), call("c2", "b__echo", %{"y" => 2})])
    assert ready(session, "a") && ready(session, "b")
    [%{"parent" => watchdog}] = for %{"parent" => _} = line <- log(log_a), do: line
    {_, 0} = System.cmd("kill", ["-KILL", Integer.to_string(watchdog)])

    assert %{state: {:error, _reason}} = group(session, "a", &match?({:error, _}, &1))
    :ok = Session.prompt(session, "go")
    assert [_search, {false, ~s(echo {"y":2})}] = results(2)
  end
end
