defmodule Helyx.Session.QueuesTest do
  use ExUnit.Case, async: true

  alias Helyx.Session.Queues

  defp push!(queues, key, text) do
    {:ok, queues} = Queues.push(queues, key, text)
    queues
  end

  test "push keeps the arrival order of each queue" do
    queues =
      %Queues{}
      |> push!(:follow_ups, "f1")
      |> push!(:steers, "s1")
      |> push!(:follow_ups, "f2")
      |> push!(:steers, "s2")

    assert Queues.counts(queues) == %{steers: 2, follow_ups: 2}
    assert Queues.drain(queues) == {["s1", "s2", "f1", "f2"], %Queues{}}
  end

  test "each queue holds at most 32 entries, and a full queue does not block the other" do
    full = Enum.reduce(1..31, %Queues{}, &push!(&2, :steers, "s#{&1}"))
    assert Queues.counts(full).steers == 31

    full = push!(full, :steers, "s32")
    assert Queues.push(full, :steers, "s33") == {:error, :queue_full}
    assert Queues.counts(full) == %{steers: 32, follow_ups: 0}

    assert {:ok, queues} = Queues.push(full, :follow_ups, "f1")
    assert Queues.counts(queues) == %{steers: 32, follow_ups: 1}
  end

  test "held steers count in the limit" do
    queues = Enum.reduce(1..30, %Queues{}, &push!(&2, :steers, "s#{&1}"))

    assert Queues.steer_room?(queues, 1)
    refute Queues.steer_room?(queues, 2)
    assert {:ok, _queues} = Queues.push(queues, :steers, "s31", 1)
    assert Queues.push(queues, :steers, "s31", 2) == {:error, :queue_full}
  end

  test "the limit counts entries, not bytes" do
    text = String.duplicate("折🚀", 1000)
    full = Enum.reduce(1..32, %Queues{}, fn _n, queues -> push!(queues, :follow_ups, text) end)

    assert Queues.push(full, :follow_ups, "折") == {:error, :queue_full}
    assert {[^text | _], %Queues{}} = Queues.drain(full)
  end

  test "drain_steers takes the steers and keeps the follow-ups" do
    queues = %Queues{} |> push!(:steers, "s1") |> push!(:follow_ups, "f1")

    assert {["s1"], rest} = Queues.drain_steers(queues)
    assert Queues.counts(rest) == %{steers: 0, follow_ups: 1}
    assert Queues.drain_steers(rest) == {[], rest}
  end

  test "drain of empty queues returns nothing" do
    assert Queues.drain(%Queues{}) == {[], %Queues{}}
  end
end
