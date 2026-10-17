defmodule Helyx.Session.ChildTest do
  # The start options of a child session: `:tools` and `:parent`,
  # its link in the header, which keeps it out of the session list
  # (docs/features/agent-tool.md).
  use ExUnit.Case, async: true

  import Helyx.Test.Events, only: [collect_until: 1]
  import Helyx.Test.SessionCase, only: [start_core: 1, final_text: 1]

  alias Helyx.Session
  alias Helyx.Session.File.Scan

  @moduletag :tmp_dir

  setup do
    %{core: start_core([Helyx.Test.Provider, Helyx.Test.Tool.Upcase, Helyx.Test.Tool.Context])}
  end

  defp parent(call_id), do: %{session_id: "parent000000", call_id: call_id}

  defp start(core, dir, opts),
    do: Session.start(core, [model: "test/tools", cwd: dir, sessions_dir: dir] ++ opts)

  defp tool_names(session) do
    {:ok, _snapshot, _ref} = Session.subscribe(session)
    :ok = Session.prompt(session, "names")
    final_text(collect_until(:turn_end))
  end

  test "a session gets only the tools that `:tools` names", %{core: core, tmp_dir: dir} do
    {:ok, all} = start(core, dir, [])
    assert tool_names(all) == "context,upcase"

    {:ok, child} = start(core, dir, tools: ["upcase", "no such tool"])
    assert tool_names(child) == "upcase"
    {:ok, other} = start(core, dir, tools: ["context"])
    assert tool_names(other) == "context"
  end

  test "a bad tool list starts nothing", %{core: core, tmp_dir: dir} do
    for bad <- ["upcase", [:upcase], ["upcase" | "context"], %{}] do
      assert start(core, dir, tools: bad) == {:error, :invalid_tools}
    end

    assert File.ls!(dir) == []
  end

  test "the header links the parent; the list and the newest pick leave the child out", %{
    core: core,
    tmp_dir: dir
  } do
    {:ok, top} = start(core, dir, [])
    tool_names(top)
    {:ok, child} = start(core, dir, parent: parent("call_1"))
    tool_names(child)

    assert {:ok, path, header} = Scan.find(dir, child.id)
    assert header["parent"] == %{"session_id" => "parent000000", "call_id" => "call_1"}
    assert Enum.map(Scan.list(dir, :all), & &1.id) == [top.id]
    assert {:ok, picked} = Session.File.pick(dir, dir, [])
    assert Path.basename(picked, ".jsonl") == top.id
    assert Path.basename(path, ".jsonl") == child.id
  end

  test "the parent call id has 1 to 256 bytes of UTF-8", %{core: core, tmp_dir: dir} do
    for ok <- [String.duplicate("a", 256), String.duplicate("é", 128), "a"] do
      assert {:ok, _} = start(core, dir, parent: parent(ok))
    end

    for bad <- [String.duplicate("a", 257), String.duplicate("é", 128) <> "a", "", <<0xFF>>, 1] do
      assert start(core, dir, parent: parent(bad)) == {:error, :invalid_parent}
    end
  end

  test "a bad parent link starts nothing", %{core: core, tmp_dir: dir} do
    for bad <- [
          %{session_id: "short", call_id: "c"},
          %{session_id: nil, call_id: "c"},
          Map.put(parent("c"), :extra, 1),
          %{"session_id" => "parent000000", "call_id" => "c"},
          "parent000000"
        ] do
      assert start(core, dir, parent: bad) == {:error, :invalid_parent}
    end

    assert File.ls!(dir) == []
  end
end
