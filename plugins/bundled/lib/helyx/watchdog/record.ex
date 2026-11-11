defmodule Helyx.Watchdog.Record do
  @moduledoc false
  # The release record of one group of `Helyx.Watchdog`, which every copy of
  # its handle carries: one signed `:atomics` slot. Its states are in
  # `docs/features/tool-resource-release.md`, "The release record". A taken
  # record holds `deadline * 4 + 1`, so it never equals a state of no
  # release.

  @held 0
  @gone 2
  @unconfirmed 3

  # The poll interval of a release that waits for another one to end.
  @poll_ms 20

  def new, do: :atomics.new(1, signed: true)

  # Takes the record for a release with `deadline`: `:taken`, `:gone` when
  # its group was confirmed gone, or `:held` when another release holds it
  # past `deadline`.
  def take(record, deadline) do
    case :atomics.get(record, 1) do
      @gone ->
        :gone

      state when state in [@held, @unconfirmed] ->
        swap(record, state, deadline)

      taken ->
        if now() >= lease(taken), do: swap(record, taken, deadline), else: wait(record, deadline)
    end
  end

  # A probe confirmed the group gone.
  def gone(record), do: :atomics.put(record, 1, @gone)

  # The release with `deadline` ends with the group not confirmed gone, or
  # raised; a record that it no longer holds stays as it is.
  def unconfirmed(record, deadline),
    do: :atomics.compare_exchange(record, 1, taken(deadline), @unconfirmed)

  defp swap(record, from, deadline) do
    case :atomics.compare_exchange(record, 1, from, taken(deadline)) do
      :ok -> :taken
      _changed -> take(record, deadline)
    end
  end

  defp wait(record, deadline) do
    left = deadline - now()

    if left <= 0 do
      :held
    else
      Process.sleep(min(@poll_ms, left))
      take(record, deadline)
    end
  end

  defp taken(deadline), do: deadline * 4 + 1
  defp lease(taken), do: div(taken - 1, 4)
  defp now, do: System.monotonic_time(:millisecond)
end
