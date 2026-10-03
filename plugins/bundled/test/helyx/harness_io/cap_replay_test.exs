defmodule Helyx.HarnessIO.CapReplayTest do
  use ExUnit.Case, async: true

  alias Helyx.HarnessIO

  test "a history much larger than the cap encodes only the groups it keeps" do
    group_bytes = 1_000
    fits = div(HarnessIO.replay_max_bytes(), group_bytes)
    count = fits * 10
    entries = for i <- 1..count, do: {i, 1, true}
    me = self()

    {kept, cut} =
      HarnessIO.cap_replay(entries, count, fn i ->
        send(me, {:encoded, i})
        :binary.copy("x", group_bytes)
      end)

    assert length(kept) == fits
    assert cut == count - fits

    # The newest `fits` groups, each once, and the one group that passes the cap.
    assert drain([]) == Enum.to_list((count - fits)..count)
  end

  defp drain(acc) do
    receive do
      {:encoded, i} -> drain([i | acc])
    after
      0 -> acc
    end
  end
end
