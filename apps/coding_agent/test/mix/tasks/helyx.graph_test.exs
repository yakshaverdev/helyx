defmodule Mix.Tasks.Helyx.GraphTest do
  # Not async: the turn trace is global to the node.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  test "calls prints the calls between project functions, one line each" do
    out = capture_io(fn -> Mix.Tasks.Helyx.Graph.run(["calls"]) end)
    assert out =~ "CodingAgent.Print.run/2 -> Helyx.Session.prompt/2\n"
    refute out =~ "Enum."
  end

  test "turn prints the processes and messages of one traced turn" do
    out = capture_io(fn -> Mix.Tasks.Helyx.Graph.run(["turn"]) end)
    assert out =~ ~r/^sequenceDiagram\n/
    assert out =~ ~r/participant (p\d+) as Helyx.Session.Server\n/
    assert out =~ ~r/participant p\d+ as Helyx.Session.Hands\n/
    assert out =~ "Note over"
    assert out =~ ": Helyx.Tool.Read.run/2"
    assert out =~ ": event turn_end"
  end

  test "a wrong argument raises the usage" do
    for argv <- [[], ["nope"], ["calls", "--mermaid"], ["calls", "Helyx.Session"]] do
      assert_raise Mix.Error, ~r/usage/, fn -> Mix.Tasks.Helyx.Graph.run(argv) end
    end
  end
end
