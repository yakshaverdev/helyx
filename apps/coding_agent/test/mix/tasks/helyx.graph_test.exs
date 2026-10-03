defmodule Mix.Tasks.Helyx.GraphTest do
  # Not async: the turn trace is global to the node.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  test "calls prints the function calls of a module, one line each" do
    out = capture_io(fn -> Mix.Tasks.Helyx.Graph.run(["calls", "Helyx.Session.Hands"]) end)
    assert out =~ "Helyx.Session.Server.ToolRuns.effect/3 -> Helyx.Session.Hands.run/3\n"
    refute out =~ "Enum."
  end

  test "calls --mermaid prints a flowchart" do
    out =
      capture_io(fn ->
        Mix.Tasks.Helyx.Graph.run(["calls", "Helyx.Session.Hands", "--mermaid"])
      end)

    assert out =~ ~r/^flowchart LR\n/
    assert out =~ ~s(["Helyx.Session.Hands.run/3"])
  end

  test "turn prints the processes and messages of one traced turn" do
    out = capture_io(fn -> Mix.Tasks.Helyx.Graph.run(["turn"]) end)
    assert out =~ ~r/^sequenceDiagram\n/
    assert out =~ ~r/participant (p\d+) as Helyx.Session.Server\n/
    assert out =~ ~r/participant p\d+ as Helyx.Session.Hands\n/
    assert out =~ "Note over"
    assert out =~ ": Helyx.Tool.Read.run/2"
    assert out =~ ": event agent_end"
  end

  test "a wrong argument raises the usage" do
    assert_raise Mix.Error, ~r/usage/, fn -> Mix.Tasks.Helyx.Graph.run(["nope"]) end
  end
end
