defmodule Helyx.Tool.BundledNamesTest do
  # Every bundled Tool plugin passes the name rule of `Helyx.Tool.specs/2`
  # (docs/features/mcp-client.md, slice 1).
  use ExUnit.Case, async: true

  @tools [
    Helyx.Tool.Agent,
    Helyx.Tool.Bash,
    Helyx.Tool.Edit,
    Helyx.Tool.Find,
    Helyx.Tool.Grep,
    Helyx.Tool.Question,
    Helyx.Tool.Read,
    Helyx.Tool.Skill,
    Helyx.Tool.ToolSearch,
    Helyx.Tool.WebFetch,
    Helyx.Tool.Write,
    Helyx.Memory.Markdown
  ]

  test "the bundled tools pass the name rule" do
    core = :"core_#{System.unique_integer([:positive])}"
    start_supervised!({Helyx.Core, name: core, plugins: [Helyx.Provider.Fake | @tools]})

    assert {:ok, tools} = Helyx.Tool.specs(core)

    assert Enum.map(tools, fn {_tool, spec} -> spec.name end) ==
             ~w(agent bash edit find grep memory_write question read skill tool_search web_fetch write)
  end
end
