defmodule Helyx.Transport.WebSocket.WireTest do
  # The wire form of the UI blocks (`docs/features/wire-protocol.md`,
  # `docs/features/ui-blocks.md`).
  use ExUnit.Case, async: true

  alias Helyx.{Event, Message, UIBlock}
  alias Helyx.Session.{Snapshot, Totals}
  alias Helyx.Transport.WebSocket.Wire

  @call %Message.ToolCall{id: "c1", name: "bash", arguments: %{}}
  # String keys, nested values, every JSON type, and text that JSON escapes.
  @block %{
    "kind" => "future_kind",
    "text" => "a \"plan\"\né",
    "cut" => false,
    "rows" => [%{"a" => 1, "b" => [2.5, true, false, nil, "s"]}, %{}],
    "count" => -7
  }

  defp event(type, data),
    do: %Event{type: type, session_id: "s1", instance_id: "i1", turn_id: "t1", seq: 3, data: data}

  defp snapshot(ui_blocks),
    do: %Snapshot{
      instance_id: "i1",
      seq: 3,
      messages: [],
      turn: nil,
      model: "fake/echo",
      queue: %{steers: 0, follow_ups: 0, running: 0, held: 0, waiting: 0},
      persisting: true,
      usage: %Totals{},
      context: nil,
      ui_blocks: ui_blocks
    }

  # The JSON text of a wire value, read back.
  defp wire(value), do: value |> JSON.encode!() |> JSON.decode!()

  test "a tool result has ui_blocks when it has any, each block as it is, and none when empty" do
    result = %{Message.tool_result(@call, {:ok, "ok"}) | id: "r1"}

    assert {:ok, @block} = UIBlock.check(@block)
    with_blocks = Wire.value(%{result | ui_blocks: [@block, %{"kind" => "x", "text" => ""}]})
    assert with_blocks["ui_blocks"] == [@block, %{"kind" => "x", "text" => ""}]
    assert wire(with_blocks)["ui_blocks"] == [@block, %{"kind" => "x", "text" => ""}]
    assert with_blocks["is_error"] == false

    refute Map.has_key?(Wire.value(result), "ui_blocks")
    refute Map.has_key?(Wire.value(Message.user("hi", %{kind: :user, id: nil})), "ui_blocks")
  end

  test "the ui_block event has call_id, null for the turn, key, and the block as it is" do
    for call_id <- ["c1", nil] do
      encoded = Wire.event(event(:ui_block, %{call_id: call_id, key: "plan", block: @block}))

      assert encoded["type"] == "ui_block"
      assert encoded["data"] == %{"call_id" => call_id, "key" => "plan", "block" => @block}
      assert wire(encoded)["data"] == %{"call_id" => call_id, "key" => "plan", "block" => @block}
    end
  end

  # The keys of `snapshot` in the schema of `docs/features/wire-protocol.md`.
  @snapshot_schema ~w(instance_id seq messages older turn model queue persisting
                      usage context asks ui_blocks activated)

  test "the snapshot of the encoder has exactly the keys of the schema" do
    keys = Wire.snapshot(snapshot([])) |> Map.keys() |> MapSet.new()
    assert keys == MapSet.new(@snapshot_schema)
  end

  test "the snapshot has ui_blocks, each as the data of its event, in order" do
    shown = [
      %{call_id: "c1", key: "p", block: @block},
      %{call_id: nil, key: "plan", block: %{"kind" => "progress", "text" => "1 of 3"}}
    ]

    assert wire(Wire.snapshot(snapshot(shown)))["ui_blocks"] == [
             %{"call_id" => "c1", "key" => "p", "block" => @block},
             %{
               "call_id" => nil,
               "key" => "plan",
               "block" => %{"kind" => "progress", "text" => "1 of 3"}
             }
           ]

    assert wire(Wire.snapshot(snapshot([])))["ui_blocks"] == []
  end

  # Core admits no block with an integer of 101 digits (ADR 0011 §2), so the
  # encoder never gets one; it has no check of its own and writes the value.
  test "an integer of 101 digits: Core refuses the block, and the encoder would write it as it is" do
    big = Integer.pow(10, 100)
    block = %{"kind" => "progress", "text" => "t", "n" => big}

    assert UIBlock.check(block) == :error
    assert {:ok, _block} = UIBlock.check(%{block | "n" => big - 1})

    encoded = JSON.encode!(Wire.event(event(:ui_block, %{call_id: nil, key: "k", block: block})))
    assert encoded =~ ~s("n":#{big})
  end
end
