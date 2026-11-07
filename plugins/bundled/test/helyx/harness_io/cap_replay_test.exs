defmodule Helyx.HarnessIO.CapReplayTest do
  use ExUnit.Case, async: true

  alias Helyx.HarnessIO

  # `@replay_max_bytes` in `Helyx.HarnessIO`.
  @replay_max_bytes 400_000

  test "a history much larger than the cap encodes only the groups it keeps" do
    group_bytes = 1_000
    fits = div(@replay_max_bytes, group_bytes)
    count = fits * 10
    entries = for i <- 1..count, do: {i, 1, true}
    me = self()

    {:ok, kept, cut} =
      HarnessIO.cap_replay(entries, count, fn i ->
        send(me, {:encoded, i})
        :binary.copy("x", group_bytes)
      end)

    assert length(kept) == fits
    assert cut == count - fits

    # The newest `fits` groups, each once, and the one group that passes the cap.
    assert drain([]) == Enum.to_list((count - fits)..count)
  end

  test "the open turn keeps its interrupted result when only the closed history is cut" do
    sizes = %{
      old_user: 100_000,
      old_message: 49_000,
      old_result: 50_000,
      open_call: 300_000,
      interrupted: 200
    }

    entries = [
      {:old_user, 1, true},
      {:old_message, 1, true},
      {:old_result, 1, false},
      {:open_call, 1, true},
      {:interrupted, 1, false}
    ]

    {:ok, kept, cut} = HarnessIO.cap_replay(entries, 5, encode(sizes))

    assert for({group, _data} <- kept, do: group) ==
             [:old_message, :old_result, :open_call, :interrupted]

    assert cut == 1
  end

  test "an open turn at the cap is kept whole" do
    sizes = %{open_call: @replay_max_bytes - 200, interrupted: 200}
    entries = [{:open_call, 1, true}, {:interrupted, 1, false}]

    assert {:ok, [open_call, interrupted], 0} =
             HarnessIO.cap_replay(entries, 2, encode(sizes))

    assert {:open_call, _data} = open_call
    assert {:interrupted, _data} = interrupted
  end

  test "an open turn over the cap is a typed error, not a silent cut" do
    sizes = %{call: 350_000, interrupted: 100_000}
    entries = [{:call, 1, true}, {:interrupted, 1, false}]

    assert {:error, {:replay_over_limit, 450_000}} =
             HarnessIO.cap_replay(entries, 2, encode(sizes))
  end

  defp encode(sizes), do: fn group -> :binary.copy("x", Map.fetch!(sizes, group)) end

  defp drain(acc) do
    receive do
      {:encoded, i} -> drain([i | acc])
    after
      0 -> acc
    end
  end
end
