defmodule Helyx.Session.TurnTest do
  use ExUnit.Case, async: true

  alias Helyx.{Message, ModelRef}
  alias Helyx.Session.Turn

  defp turn do
    {:ok, model} = ModelRef.parse("fake/echo")
    %Turn{id: "t1", model: model, provider: Helyx.Test.Provider, partial: []}
  end

  test "assistant_message builds the content in stream order, with the fields" do
    call = %Message.ToolCall{id: "c1", name: "read", arguments: %{}}

    {:ok, turn} = Turn.add_block(turn(), {:text_delta, "he"}, 2)
    {:ok, turn} = Turn.add_block(turn, {:text_delta, "llo"}, 3)
    {:ok, turn} = Turn.add_block(turn, {:tool_call, call}, 16)

    assert %Message{
             role: :assistant,
             model: "fake/echo",
             stop_reason: :tool_use,
             content: [%Message.Text{text: "hello"}, ^call]
           } = Turn.assistant_message(turn, stop_reason: :tool_use)
  end

  test "assistant_message with no blocks has empty content" do
    assert %Message{content: [], model: "fake/echo"} = Turn.assistant_message(turn(), [])
  end
end
