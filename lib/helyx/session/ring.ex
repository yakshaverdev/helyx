defmodule Helyx.Session.Ring do
  @moduledoc false
  # The replay ring of a session: its newest events, at most 1,024 and
  # 4 MiB by `:erlang.external_size/1`. `seq` is the seq of the newest
  # event of the session, and `from` is the lowest `after` that the ring
  # can serve (docs/features/replay-ring.md).

  alias Helyx.Event

  @max_count 1_024
  @max_bytes 4 * 1024 * 1024

  defstruct events: :queue.new(), count: 0, bytes: 0, from: 0, seq: 0

  @type t :: %__MODULE__{
          events: :queue.queue({non_neg_integer(), Event.t()}),
          count: non_neg_integer(),
          bytes: non_neg_integer(),
          from: non_neg_integer(),
          seq: non_neg_integer()
        }

  def max_count, do: @max_count
  def max_bytes, do: @max_bytes

  # An event over the bytes empties the ring and marks a gap at its seq.
  @spec push(t(), Event.t()) :: t()
  def push(%__MODULE__{} = ring, %Event{seq: seq} = event) do
    case :erlang.external_size(event) do
      size when size > @max_bytes ->
        %{ring | events: :queue.new(), count: 0, bytes: 0, from: seq, seq: seq}

      size ->
        trim(%{
          ring
          | events: :queue.in({size, event}, ring.events),
            count: ring.count + 1,
            bytes: ring.bytes + size,
            seq: seq
        })
    end
  end

  defp trim(%__MODULE__{count: count, bytes: bytes} = ring)
       when count > @max_count or bytes > @max_bytes do
    {{:value, {size, event}}, events} = :queue.out(ring.events)
    trim(%{ring | events: events, count: count - 1, bytes: bytes - size, from: event.seq})
  end

  defp trim(ring), do: ring

  # The events after `seq`, oldest first, or `:error` when the ring dropped
  # one of them. The caller checks that `seq` is not above the last event.
  @spec since(t(), non_neg_integer()) :: {:ok, [Event.t()]} | :error
  def since(%__MODULE__{from: from} = ring, seq) when seq >= from,
    do:
      {:ok,
       for({_size, %Event{seq: s} = event} <- :queue.to_list(ring.events), s > seq, do: event)}

  def since(_ring, _seq), do: :error
end
