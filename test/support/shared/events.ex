defmodule Helyx.Test.Events do
  @moduledoc false
  # The one receive loop over a subscriber's session events.
  import ExUnit.Assertions

  alias Helyx.Event

  # The cap of a wait that must happen: the `assert_receive` timeout that
  # the test helper sets.
  def wait_ms, do: Application.fetch_env!(:ex_unit, :assert_receive_timeout)

  # The events in the mailbox up to and including the first of `type`.
  def collect_until(type, timeout \\ wait_ms()), do: collect(type, timeout, [])

  def messages(events), do: for(%Event{type: :message_end, data: %{message: m}} <- events, do: m)
  def of_type(events, type), do: for(%Event{type: ^type, data: data} <- events, do: data)

  # True when the term holds a pid, a reference, a port, or a function,
  # which no contract value may hold (ADR 0006 §2).
  def handle?(term)
      when is_pid(term) or is_reference(term) or is_port(term) or is_function(term),
      do: true

  def handle?(term) when is_map(term), do: handle?(:maps.to_list(term))
  def handle?(term) when is_tuple(term), do: handle?(Tuple.to_list(term))
  def handle?([head | tail]), do: handle?(head) or handle?(tail)
  def handle?(_term), do: false

  defp collect(type, timeout, acc) do
    receive do
      {:helyx_event, %Event{type: ^type} = event} -> Enum.reverse([event | acc])
      {:helyx_event, %Event{} = event} -> collect(type, timeout, [event | acc])
    after
      timeout -> flunk("timed out waiting for #{type}; got #{inspect(Enum.reverse(acc))}")
    end
  end
end
