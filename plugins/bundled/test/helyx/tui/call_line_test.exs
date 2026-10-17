defmodule Helyx.TUI.CallLineTest do
  # The line of a tool call in a tool cell, and its cut.
  use ExUnit.Case, async: true

  alias Helyx.Message
  alias Helyx.TUI.CallLine

  test "a tool call line is cut at 8,192 bytes, after newlines become ␤" do
    # A name and a key of newlines, each far over the cut: "␤" is 3 bytes
    # for 1, and neither is copied whole.
    lines = String.duplicate("\n", 1_000_000)
    call = %Message.ToolCall{id: "c", name: lines, arguments: %{lines => 1}}

    line = CallLine.line(call)
    assert byte_size(line) in 8_190..8_192
    assert String.starts_with?(line, "⚙ ␤␤")
    refute line =~ "\n"

    # U+00A0 renders as `\u00A0` through `inspect/1`, and the keys are raw.
    arguments = Map.new(1..2_000, &{"k#{&1}", String.duplicate("\u00A0", 100)})
    line = CallLine.line(%Message.ToolCall{id: "c", name: "bash", arguments: arguments})
    assert byte_size(line) in 8_190..8_192
    assert String.starts_with?(line, "⚙ bash k")
  end

  test "an agent call line is its description, with the cuts of every call line" do
    agent = &%Message.ToolCall{id: "c", name: "agent", arguments: &1}

    assert CallLine.line(agent.(%{"description" => "review", "prompt" => "p"})) ==
             "⚙ agent: review"

    line = CallLine.line(agent.(%{"description" => String.duplicate("é\n", 10_000)}))
    assert byte_size(line) in 8_190..8_192
    assert String.starts_with?(line, "⚙ agent: é␤")
    refute line =~ "\n"

    # A description that is not a string shows as any call.
    assert CallLine.line(agent.(%{"description" => 1})) == "⚙ agent description=1"

    id = Helyx.Sessions.child_id("parent000000", "c")

    assert CallLine.line(agent.(%{"description" => "review"}), "parent000000") ==
             "⚙ agent #{id}: review"

    long =
      CallLine.line(
        agent.(%{"description" => String.duplicate("x", 10_000)}),
        "parent000000"
      )

    assert String.starts_with?(long, "⚙ agent #{id}: x")
  end
end
