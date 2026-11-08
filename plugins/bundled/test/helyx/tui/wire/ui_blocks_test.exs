defmodule Helyx.TUI.Wire.UIBlocksTest do
  # The decode of the UI blocks of the wire in the client of the TUI
  # (`docs/features/wire-protocol.md`, `docs/features/ui-blocks.md`).
  use ExUnit.Case, async: true

  alias Helyx.{Event, Message, UIBlock}
  alias Helyx.Session.{Snapshot, Totals}
  alias Helyx.Transport.WebSocket.{Frame, Wire}
  alias Helyx.TUI.Wire.Decode

  @call %Message.ToolCall{id: "c1", name: "bash", arguments: %{}}
  @block %{"kind" => "progress", "text" => "1 of 3", "done" => 1, "of" => 3}
  # A kind that no client knows, with nested fields: the client takes it.
  @unknown %{
    "kind" => "future_kind",
    "text" => "a \"plan\"\né",
    "cut" => true,
    "rows" => [%{"a" => [2.5, true, false, nil, "s"]}, %{}]
  }

  defp event(type, data),
    do: %Event{type: type, session_id: "s1", instance_id: "i1", turn_id: "t1", seq: 3, data: data}

  defp result(blocks),
    do: %{Message.tool_result(@call, {:ok, "ok"}) | id: "r1", ui_blocks: blocks}

  defp calls, do: %Message{role: :assistant, id: "a1", content: [@call], stop_reason: :tool_use}

  defp snapshot(messages, ui_blocks),
    do: %Snapshot{
      instance_id: "i1",
      seq: 3,
      messages: messages,
      more: false,
      turn: %{id: "t1", partial: nil, elapsed_ms: 0},
      model: "fake/echo",
      queue: %{steers: 0, follow_ups: 0, running: 0, held: 0, waiting: 0},
      persisting: true,
      usage: %Totals{},
      context: nil,
      ui_blocks: ui_blocks
    }

  defp wire(value), do: value |> JSON.encode!() |> JSON.decode!()

  defp subscribe(snapshot_json),
    do:
      Decode.result("subscribe", %{
        "ok" => true,
        "result" => %{"sub" => "1", "snapshot" => snapshot_json}
      })

  defp shown(block, call_id \\ "c1"),
    do: wire(Wire.event(event(:ui_block, %{call_id: call_id, key: "p", block: block})))

  test "the ui_block event decodes as it was, with a call id and with null, of any kind" do
    for call_id <- ["c1", nil], block <- [@block, @unknown] do
      event = event(:ui_block, %{call_id: call_id, key: "p", block: block})
      assert Decode.event(wire(Wire.event(event))) == {:ok, event}
    end
  end

  test "the ui_blocks of a tool result decode as they were; a missing key is none" do
    for blocks <- [[], [@block], [@unknown | List.duplicate(@block, 7)]] do
      event = event(:tool_execution_end, %{message: result(blocks)})
      assert Decode.event(wire(Wire.event(event))) == {:ok, event}
    end

    # An empty list on the wire, which the server leaves out, is no blocks.
    empty =
      put_in(
        wire(Wire.event(event(:tool_execution_end, %{message: result([])}))),
        ["data", "message", "ui_blocks"],
        []
      )

    assert {:ok, %Event{data: %{message: %Message{ui_blocks: []}}}} = Decode.event(empty)
  end

  test "the snapshot ui_blocks and its messages decode as they were" do
    shown = [
      %{call_id: "c1", key: "p", block: @block},
      %{call_id: nil, key: "plan", block: @unknown}
    ]

    for snapshot <- [
          snapshot([calls()], shown),
          snapshot([calls(), result([@block])], []),
          snapshot([], [])
        ] do
      assert subscribe(wire(Wire.snapshot(snapshot))) == {:ok, {:ok, snapshot, "1"}}
    end

    assert subscribe(Map.delete(wire(Wire.snapshot(snapshot([], []))), "ui_blocks")) == :error

    broken = %{wire(Wire.snapshot(snapshot([], []))) | "ui_blocks" => [%{"key" => "p"}]}
    assert subscribe(broken) == :error
  end

  test "a broken ui_block event is a contract break; the kind is not read for its meaning" do
    good = shown(@block)

    for broken <- [
          shown(%{@block | "kind" => 1}),
          shown(%{@block | "kind" => "Progress"}),
          shown(%{@block | "kind" => String.duplicate("k", 65)}),
          shown(Map.delete(@block, "text")),
          shown(%{@block | "text" => nil}),
          shown(Map.put(@block, "cut", "yes")),
          shown("1 of 3"),
          put_in(good, ["data", "key"], ""),
          put_in(good, ["data", "key"], String.duplicate("k", 65)),
          put_in(good, ["data", "call_id"], 1),
          update_in(good["data"], &Map.delete(&1, "call_id")),
          update_in(good["data"], &Map.delete(&1, "block"))
        ] do
      assert Decode.event(broken) == :error, inspect(broken)
    end

    assert {:ok, %Event{}} = Decode.event(shown(%{@block | "kind" => String.duplicate("k", 64)}))

    assert {:ok, %Event{}} =
             Decode.event(put_in(good, ["data", "key"], String.duplicate("é", 32)))
  end

  test "ui_blocks on a message that is not a tool result, not a list, or over 8 is a contract break" do
    ok = wire(Wire.event(event(:tool_execution_end, %{message: result([@block])})))
    start = wire(Wire.event(event(:message_start, %{message: calls()})))

    for broken <- [
          put_in(ok, ["data", "message", "ui_blocks"], List.duplicate(@block, 9)),
          put_in(ok, ["data", "message", "ui_blocks"], @block),
          put_in(ok, ["data", "message", "ui_blocks"], [%{"text" => "t"}]),
          put_in(start, ["data", "message", "ui_blocks"], [@block])
        ] do
      assert Decode.event(broken) == :error, inspect(broken)
    end

    assert {:ok, %Event{}} =
             Decode.event(put_in(ok, ["data", "message", "ui_blocks"], List.duplicate(@block, 8)))
  end

  # Core cuts a block over the bound, so a block of 65,537 bytes of JSON on
  # the wire is a contract break; one of 65,536 bytes passes.
  test "a block at the byte bound passes, and one byte over it is a contract break" do
    base = %{"kind" => "k", "text" => ""}
    room = UIBlock.max_bytes() - byte_size(JSON.encode!(base))
    # Each newline is two bytes of JSON.
    at = %{
      base
      | "text" => String.duplicate("\n", div(room, 2)) <> String.duplicate("a", rem(room, 2))
    }

    assert byte_size(JSON.encode!(at)) == UIBlock.max_bytes()
    over = %{at | "text" => at["text"] <> "a"}

    assert {:ok, %Event{}} = Decode.event(shown(at))
    assert Decode.event(shown(over)) == :error
  end

  # Core admits no integer of more than 100 digits in a block (ADR 0011 §2).
  # The frame decode of the client takes integers of up to 1,024 digits, so
  # a 101-digit one reaches the decoder, which refuses it as Core would.
  test "an integer of 101 digits in a block passes the frame decode and is a contract break" do
    for {digits, taken?} <- [{100, true}, {101, false}] do
      n = Integer.pow(10, digits - 1)

      for value <- [n, -n, [%{"n" => n}]] do
        frame = %{"type" => "event", "sub" => "1", "event" => shown(%{@block | "done" => value})}
        assert {:frame, %{"event" => decoded}} = Frame.decode(JSON.encode!(frame), nil, :outbound)
        assert match?({:ok, %Event{}}, Decode.event(decoded)) == taken?, "#{digits} digits"
      end
    end

    # Past the 1,024 digits of the frame decode, the frame itself is refused.
    frame = ~s({"type":"event","sub":"1","event":{"n":#{String.duplicate("9", 1025)}}})
    assert Frame.decode(frame, nil, :outbound) == {:close, 4400}
  end
end
