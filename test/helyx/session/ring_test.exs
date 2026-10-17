defmodule Helyx.Session.RingTest do
  use ExUnit.Case, async: true

  alias Helyx.Event
  alias Helyx.Session.Ring

  defp event(seq, text \\ "x"),
    do: %Event{
      type: :notice,
      session_id: "s",
      instance_id: "i",
      turn_id: nil,
      seq: seq,
      data: %{text: text}
    }

  defp push_all(ring, seqs), do: Enum.reduce(seqs, ring, &Ring.push(&2, event(&1)))

  defp seqs({:ok, events}), do: Enum.map(events, & &1.seq)

  test "the ring holds 1,024 events; the 1,025th drops the oldest and moves from" do
    full = push_all(%Ring{}, 1..1_024)
    assert full.count == 1_024
    assert full.from == 0
    assert seqs(Ring.since(full, 0)) == Enum.to_list(1..1_024)

    over = Ring.push(full, event(1_025))
    assert over.count == 1_024
    assert over.from == 1
    assert Ring.since(over, 0) == :error
    assert seqs(Ring.since(over, 1)) == Enum.to_list(2..1_025)
  end

  test "the events after a seq, and none after the last" do
    ring = push_all(%Ring{}, 1..5)
    assert seqs(Ring.since(ring, 3)) == [4, 5]
    assert Ring.since(ring, 5) == {:ok, []}
  end

  test "the byte bound drops the oldest events until the sum fits" do
    # Two events of a little over a third of the bytes each fit; a third
    # passes the bound and drops the first.
    text = String.duplicate("a", div(Ring.max_bytes(), 3))
    ring = Enum.reduce(1..3, %Ring{}, &Ring.push(&2, event(&1, text)))

    assert ring.count == 2
    assert ring.bytes <= Ring.max_bytes()
    assert ring.from == 1
    assert seqs(Ring.since(ring, 1)) == [2, 3]
  end

  test "an event at the byte bound stays; one over it empties the ring and marks a gap" do
    small = :erlang.external_size(event(1, ""))
    at = event(2, String.duplicate("a", Ring.max_bytes() - small))
    assert :erlang.external_size(at) == Ring.max_bytes()

    ring = Ring.push(%Ring{}, at)
    assert seqs(Ring.since(ring, 0)) == [2]

    over = event(3, String.duplicate("a", Ring.max_bytes() - small + 1))
    ring = ring |> Ring.push(over) |> Ring.push(event(4))
    assert ring.from == 3
    assert Ring.since(ring, 2) == :error
    assert seqs(Ring.since(ring, 3)) == [4]
  end
end
