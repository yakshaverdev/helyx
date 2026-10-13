defmodule Helyx.HarnessIO.HarnessToolsTest do
  use ExUnit.Case, async: true

  alias Helyx.HarnessIO

  # The names come from the bundled tools, so a renamed file tool fails
  # here and does not reach a harness again (#478).
  test "a harness gets every Helyx tool except the bundled file tools" do
    tools = [Helyx.Tool.Read, Helyx.Tool.Bash, Helyx.Tool.Edit, Helyx.Tool.Write]
    specs = for tool <- tools, do: %{name: tool.name(), description: "", parameters: %{}}
    other = %{name: "deploy", description: "", parameters: %{}}

    assert HarnessIO.harness_tools(specs ++ [other]) == [Enum.at(specs, 1), other]
  end
end
