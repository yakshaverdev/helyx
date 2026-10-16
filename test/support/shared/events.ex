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

  # Polls `fun` every 10 ms until it returns true, and flunks with `text`
  # when `ms` pass first.
  def wait_until(fun, ms \\ wait_ms(), text \\ "the condition did not hold"),
    do: poll(fun, System.monotonic_time(:millisecond) + ms, text)

  def messages(events), do: for(%Event{type: :message_end, data: %{message: m}} <- events, do: m)
  def of_type(events, type), do: for(%Event{type: ^type, data: data} <- events, do: data)

  # The snapshot of a subscribe of the caller: a barrier after the earlier
  # calls of the caller. The caller stays subscribed; the extra monitor goes.
  def snapshot(session) do
    {:ok, snapshot, ref} = Helyx.Session.subscribe(session)
    Process.demonitor(ref, [:flush])
    snapshot
  end

  # True when the term holds a pid, a reference, a port, or a function,
  # which no contract value may hold (ADR 0006 §2).
  def handle?(term)
      when is_pid(term) or is_reference(term) or is_port(term) or is_function(term),
      do: true

  def handle?(term) when is_map(term), do: handle?(:maps.to_list(term))
  def handle?(term) when is_tuple(term), do: handle?(Tuple.to_list(term))
  def handle?([head | tail]), do: handle?(head) or handle?(tail)
  def handle?(_term), do: false

  defp poll(fun, deadline, text) do
    cond do
      fun.() ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        flunk(text)

      true ->
        Process.sleep(10)
        poll(fun, deadline, text)
    end
  end

  defp collect(type, timeout, acc) do
    receive do
      {:helyx_event, %Event{type: ^type} = event} -> Enum.reverse([event | acc])
      {:helyx_event, %Event{} = event} -> collect(type, timeout, [event | acc])
    after
      timeout -> flunk("timed out waiting for #{type}; got #{inspect(Enum.reverse(acc))}")
    end
  end
end
