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

    turn =
      turn()
      |> Turn.add_block({:text_delta, "he"})
      |> Turn.add_block({:text_delta, "llo"})
      |> Turn.add_block({:tool_call, call})

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
