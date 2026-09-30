defmodule Helyx.Test.Events do
  @moduledoc false
  # The one receive loop over a subscriber's session events.
  import ExUnit.Assertions

  alias Helyx.Event

  # A whole turn, which can start OS processes on a loaded machine. Only a
  # failing test waits this long.
  @turn_ms 5_000

  def turn_ms, do: @turn_ms

  # The events in the mailbox up to and including the first of `type`.
  def collect_until(type, timeout \\ @turn_ms), do: collect(type, timeout, [])

  defp collect(type, timeout, acc) do
    receive do
      {:helyx_event, %Event{type: ^type} = event} -> Enum.reverse([event | acc])
      {:helyx_event, %Event{} = event} -> collect(type, timeout, [event | acc])
    after
      timeout -> flunk("timed out waiting for #{type}; got #{inspect(Enum.reverse(acc))}")
    end
  end
end
