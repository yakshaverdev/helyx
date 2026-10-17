defmodule Helyx.Tool.AgentTest do
  # The agent tool: a child session per call, its result, its link to the
  # parent, its depth, and the four ends of a child: an abort of the parent
  # turn, a stop of the parent session, a Core stop, and a child that ends
  # by itself (docs/features/agent-tool.md).
  use ExUnit.Case, async: true

  import Helyx.Test.Events, only: [collect_until: 1]

  alias Helyx.{Message, Session}
  alias Helyx.Message.ToolCall
  alias Helyx.Provider.Fake
  alias Helyx.Session.File.Scan

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    core = :"core_#{System.unique_integer([:positive])}"

    start_supervised!(
      {Helyx.Core,
       name: core,
       plugins: [Fake, Helyx.Tool.Agent, Helyx.Tool.Read, Helyx.Test.Tool.Block],
       sessions_dir: dir},
      id: core
    )

    %{core: core}
  end

  defp agent(id, prompt \\ "the task"),
    do: %ToolCall{
      id: id,
      name: "agent",
      arguments: %{"description" => "a task", "prompt" => prompt}
    }

  # The parent and its children share the model of the parent: its script
  # gives one response per call, in the order the calls come.
  defp parent(core, dir, responses, opts \\ []) do
    model = "agent_#{System.unique_integer([:positive])}"
    :ok = Fake.script(core, model, responses)
    {:ok, session} = Helyx.Sessions.start(core, [model: "fake/#{model}", cwd: dir] ++ opts)
    {:ok, _snapshot, _ref} = Session.subscribe(session)
    :ok = Session.prompt(session, "go")
    session
  end

  # A response that blocks the child in the block tool; the test gets
  # `{:blocked, child_id}`.
  defp block,
    do: [%ToolCall{id: "b1", name: "block", arguments: %{"to" => Helyx.Test.Gate.open()}}]

  defp results(events),
    do: for(%{message: m} <- Helyx.Test.Events.of_type(events, :tool_execution_end), do: m)

  defp messages(events), do: Helyx.Test.Events.messages(events)

  defp child_id(%Message{} = result) do
    [_, id] = Regex.run(~r/\A\[agent session ([A-Za-z0-9_-]{12})\]\n\n/, Message.text(result))
    id
  end

  defp child_pid(core, id), do: Session.pid(%Session{id: id, core: core})

  test "the result is the child's final text, and the child is linked and stopped", %{
    core: core,
    tmp_dir: dir
  } do
    session = parent(core, dir, [[agent("c1")], ["child ", "answer"], ["Done."]])
    events = collect_until(:turn_end)

    assert [result] = results(events)
    refute result.is_error
    id = child_id(result)
    assert Message.text(result) == "[agent session #{id}]\n\nchild answer"
    assert child_pid(core, id) == nil

    assert {:ok, _path, header} = Scan.find(dir, id)
    assert header["parent"] == %{"session_id" => session.id, "call_id" => "c1"}

    assert header["model"] ==
             :sys.get_state(Session.pid(session)).model |> Helyx.ModelRef.to_string()

    assert header["cwd"] == dir
    assert Enum.map(Scan.list(dir, :all), & &1.id) == [session.id]
  end

  test "a child has no agent tool, so it cannot start a child", %{core: core, tmp_dir: dir} do
    _session = parent(core, dir, [[agent("c1")], [agent("c2")], ["no agent"], ["Done."]])
    [result] = results(collect_until(:turn_end))
    assert Message.text(result) =~ ~r/\]\n\nno agent\z/

    {:ok, path, _header} = Scan.find(dir, child_id(result))
    assert File.read!(path) =~ "unknown tool: agent"
  end

  test "a child gets no tool that the parent lacks", %{core: core, tmp_dir: dir} do
    read = %ToolCall{id: "r1", name: "read", arguments: %{"path" => "x"}}

    _session =
      parent(core, dir, [[agent("c1")], [read], ["no read"], ["Done."]], tools: ["agent"])

    [result] = results(collect_until(:turn_end))
    assert Message.text(result) =~ ~r/\]\n\nno read\z/

    {:ok, path, _header} = Scan.find(dir, child_id(result))
    assert File.read!(path) =~ "unknown tool: read"
  end

  test "a failed child turn gives an error result with the reason", %{core: core, tmp_dir: dir} do
    _session = parent(core, dir, [[agent("c1")]])
    [result] = results(collect_until(:turn_end))
    assert result.is_error
    assert Message.text(result) =~ ~r/\]\n\nthe turn failed: .*no_script/
  end

  test "calls run together, and an abort of the parent turn ends each child", %{
    core: core,
    tmp_dir: dir
  } do
    blocked = block()
    session = parent(core, dir, [[agent("c1"), agent("c2")], blocked, blocked])

    assert_receive {:blocked, one}
    assert_receive {:blocked, two}
    pids = [child_pid(core, one), child_pid(core, two)]
    refs = Enum.map(pids, &Process.monitor/1)

    :ok = Session.abort(session)
    for ref <- refs, do: assert_receive({:DOWN, ^ref, :process, _pid, _reason})

    results = results(collect_until(:turn_end))

    assert Enum.map(results, &{&1.is_error, Message.text(&1)}) == [
             {true, "aborted"},
             {true, "aborted"}
           ]
  end

  test "a stop of the parent session ends the child", %{core: core, tmp_dir: dir} do
    session = parent(core, dir, [[agent("c1")], block()])
    assert_receive {:blocked, id}
    pid = child_pid(core, id)
    ref = Process.monitor(pid)

    :ok = Helyx.Sessions.stop(session)
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}
  end

  test "a Core stop ends the child", %{core: core, tmp_dir: dir} do
    _session = parent(core, dir, [[agent("c1")], block()])
    assert_receive {:blocked, id}
    pid = child_pid(core, id)
    ref = Process.monitor(pid)

    :ok = stop_supervised(core)
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}
  end

  test "a child that ends by itself gives an error result", %{core: core, tmp_dir: dir} do
    _session = parent(core, dir, [[agent("c1")], block(), ["Done."]])
    assert_receive {:blocked, id}

    Process.exit(child_pid(core, id), :kill)
    [result] = results(collect_until(:turn_end))
    assert result.is_error
    assert Message.text(result) == "[agent session #{id}]\n\nthe session ended (crashed)"
  end

  test "a parent that crashes takes no release, and the owner stops the child", %{
    core: core,
    tmp_dir: dir
  } do
    session = parent(core, dir, [[agent("c1")], block()])
    assert_receive {:blocked, id}
    pid = child_pid(core, id)
    ref = Process.monitor(pid)

    Process.exit(Session.pid(session), :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}
  end

  test "a child that the Core cap refuses gives an error result, and the parent goes on", %{
    core: core,
    tmp_dir: dir
  } do
    for _ <- 1..63, do: {:ok, _} = Helyx.Sessions.start(core, model: "fake/echo", cwd: dir)
    _session = parent(core, dir, [[agent("c1")], ["Done."]])
    events = collect_until(:turn_end)

    assert [result] = results(events)
    assert result.is_error
    assert Message.text(result) =~ "do this task yourself"
    assert Message.text(List.last(messages(events))) == "Done."
  end

  test "a call id over 256 bytes gives an error result and starts no session", %{
    core: core,
    tmp_dir: dir
  } do
    session = parent(core, dir, [[agent(String.duplicate("a", 257))], ["Done."]])
    [result] = results(collect_until(:turn_end))

    assert result.is_error
    assert Message.text(result) == "agent: the session did not start: :invalid_parent"
    assert Helyx.Sessions.list_live(core) |> Enum.map(& &1.id) == [session.id]
  end

  test "bad arguments give an error result and start no session", %{core: core, tmp_dir: dir} do
    call = %ToolCall{id: "c1", name: "agent", arguments: %{"description" => "x", "prompt" => 1}}
    session = parent(core, dir, [[call], ["Done."]])
    [result] = results(collect_until(:turn_end))

    assert result.is_error
    assert Message.text(result) == "agent needs a description and a prompt, both strings"
    assert Helyx.Sessions.list_live(core) |> Enum.map(& &1.id) == [session.id]
  end
end
