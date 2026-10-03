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

  describe "the block bound of 1,024" do
    # 1,024 blocks of alternating text and thinking, the last one text.
    defp at_bound do
      Enum.reduce(1..1_024, turn(), fn n, turn ->
        event = if rem(n, 2) == 0, do: {:text_delta, "a"}, else: {:thinking_delta, "b"}
        {:ok, turn} = Turn.add_block(turn, event, 1)
        turn
      end)
    end

    test "1,024 blocks pass, and a delta that merges into the last block passes" do
      turn = at_bound()
      assert length(Turn.assistant_message(turn, []).content) == 1_024

      {:ok, turn} = Turn.add_block(turn, {:text_delta, "c"}, 1)
      assert %Message.Text{text: "ac"} = List.last(Turn.assistant_message(turn, []).content)
    end

    test "the 1,025th block fails, and a tool call counts as a block" do
      call = %Message.ToolCall{id: "c1", name: "read", arguments: %{}}

      assert Turn.add_block(at_bound(), {:thinking_delta, "b"}, 1) ==
               {:error, {:too_many_blocks, 1_025, 1_024}}

      assert Turn.add_block(at_bound(), {:tool_call, call}, 16) ==
               {:error, {:too_many_blocks, 1_025, 1_024}}
    end

    test "a closed message starts the count again" do
      turn = %{Turn.close_partial(at_bound()) | partial: []}
      assert {:ok, %Turn{blocks: 1}} = Turn.add_block(turn, {:thinking_delta, "b"}, 1)
    end
  end
end
