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

  defp collect(type, timeout, acc) do
    receive do
      {:helyx_event, %Event{type: ^type} = event} -> Enum.reverse([event | acc])
      {:helyx_event, %Event{} = event} -> collect(type, timeout, [event | acc])
    after
      timeout -> flunk("timed out waiting for #{type}; got #{inspect(Enum.reverse(acc))}")
    end
  end
end
