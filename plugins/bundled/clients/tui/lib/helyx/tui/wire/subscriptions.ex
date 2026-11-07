defmodule Helyx.TUI.Wire.Subscriptions do
  @moduledoc false
  # The subscriptions of one connection (`docs/features/tui-attach.md`,
  # decisions 7, 11, and 18): which `sub` is live or dropped, what the owner
  # has acked, and the reply of a subscribe or a detach. The connection owns
  # the socket, the request ids, the waiting table, and the writer; every
  # rule about a subscription is here. A sub ends at `session_end`, at the
  # reply of an `unsubscribe` (a switch's detach), or at the `unsubscribe`
  # that follows a late subscribe reply; no frame of it follows that reply
  # (wire-protocol.md, O4).

  alias Helyx.Event

  defstruct subs: %{}, acks: %{}, unsubscribes: []

  @type kind :: :live | :dropped
  @type t :: %__MODULE__{
          subs: %{String.t() => kind()},
          acks: %{String.t() => non_neg_integer()},
          unsubscribes: [{String.t(), String.t()}]
        }

  @doc false
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc false
  @spec live?(t(), String.t()) :: boolean()
  def live?(%__MODULE__{subs: subs}, sub), do: subs[sub] == :live

  defp known?(%__MODULE__{subs: subs}, sub), do: Map.has_key?(subs, sub)

  @doc false
  @spec ack(t(), String.t(), non_neg_integer()) :: t()
  def ack(state, sub, seq) do
    # Only an event of a live sub is acked; one that a late reply made is
    # dropped, and its ack too.
    if live?(state, sub), do: put_in(state.acks[sub], seq), else: state
  end

  @doc false
  # The ack frames of the next batch, for the live subs only, and their
  # clear: an ack covers the events before it.
  @spec take_acks(t()) :: {[map()], t()}
  def take_acks(state) do
    acks =
      for {sub, seq} <- state.acks,
          live?(state, sub),
          do: %{"type" => "ack", "sub" => sub, "seq" => seq}

    {acks, %{state | acks: %{}}}
  end

  @doc false
  # An event of a known sub: the owner hears it when the sub is live, and a
  # sub that a late reply made drops it. An unknown sub, and an event that
  # the schema refuses, is a contract break.
  @spec event(t(), pid(), String.t(), term()) :: {:ok, t()} | :broken
  def event(state, owner, sub, {:ok, %Event{} = event}) do
    cond do
      not known?(state, sub) ->
        :broken

      live?(state, sub) ->
        send(owner, {:helyx_event, event})
        {:ok, state}

      true ->
        {:ok, state}
    end
  end

  def event(state, _owner, sub, {:ok, nil}),
    do: if(known?(state, sub), do: {:ok, state}, else: :broken)

  def event(_state, _owner, _sub, :error), do: :broken

  @doc false
  # The end of a session: the sub leaves, and the owner hears it only when
  # the sub was live.
  @spec ended(t(), pid(), String.t(), String.t()) :: {:ok, t()} | :broken
  def ended(state, owner, sub, reason) when reason in ["stopped", "crashed"] do
    if known?(state, sub) do
      if live?(state, sub),
        do: send(owner, {:helyx_end, sub, String.to_existing_atom(reason)})

      {:ok, %{state | subs: Map.delete(state.subs, sub)}}
    else
      :broken
    end
  end

  @doc false
  # The detach of a switch: the pending op of a live sub, or `:unknown_sub`.
  # The sub stays live until the reply, so its late events still ack.
  @spec detach(t(), String.t()) :: {:ok, {:unsub, String.t()}} | {:error, :unknown_sub}
  def detach(state, sub) do
    if live?(state, sub), do: {:ok, {:unsub, sub}}, else: {:error, :unknown_sub}
  end

  @doc false
  # The reply of a subscribe or a detach, and `:next` for every other op. A
  # late subscribe reply is a subscription that its caller gave up on: it
  # is dropped, and its `unsubscribe` is due. A late detach reply ends the
  # sub silently; a live one gives the reply of the wire to its caller.
  @spec reply(t(), term(), term(), term()) ::
          {:next, t()} | {:detached, t()} | {:late_subscribe, String.t(), t()} | :broken
  def reply(state, :late, "subscribe", {:ok, _snapshot_or_replay, sub}),
    do: {:late_subscribe, sub, state}

  def reply(state, _caller, "subscribe", {:ok, _snapshot_or_replay, sub}) do
    # The server makes each `sub` unique on the connection.
    if known?(state, sub), do: :broken, else: {:next, subscribed(state, sub, :live)}
  end

  def reply(state, {:unsubscribe, sub}, "unsubscribe", _result),
    do: {:detached, detached(state, sub)}

  def reply(state, :late, {:unsub, sub}, _result), do: {:detached, detached(state, sub)}

  # A live detach gets the reply of the wire, as every other op does.
  def reply(state, {_from, _timer}, {:unsub, sub}, _result),
    do: {:next, detached(state, sub)}

  def reply(state, _caller, _op, _result), do: {:next, state}

  @doc false
  # A late subscribe reply: the sub is dropped, and its `unsubscribe`
  # registers the next request id and goes out when a request frame has a
  # free place. `write` writes a request frame of the connection; `max` is
  # its bound of frames that wait.
  @spec late_subscribe(
          map(),
          String.t(),
          pos_integer(),
          (map(), String.t(), String.t(), map() -> term())
        ) :: term()
  def late_subscribe(state, sub, max, write) do
    id = Integer.to_string(state.next)

    state = %{
      state
      | subs: enqueue(dropped(state.subs, sub), id, sub),
        next: state.next + 1,
        waiting: Map.put(state.waiting, id, {"unsubscribe", {:unsubscribe, sub}})
    }

    flush(state, max, write)
  end

  @doc false
  # The next queued unsubscribe, when a request frame has a free place.
  @spec flush(map(), pos_integer(), (map(), String.t(), String.t(), map() -> term())) :: term()
  def flush(state, max, write) do
    case next_unsubscribe(state.subs, state.unwritten, max) do
      {:write, id, sub, subs} -> write.(%{state | subs: subs}, id, "unsubscribe", %{"sub" => sub})
      :none -> {:noreply, state}
    end
  end

  defp enqueue(state, id, sub), do: %{state | unsubscribes: state.unsubscribes ++ [{id, sub}]}

  defp next_unsubscribe(%{unsubscribes: [{id, sub} | rest]} = state, unwritten, max)
       when unwritten < max,
       do: {:write, id, sub, %{state | unsubscribes: rest}}

  defp next_unsubscribe(_state, _unwritten, _max), do: :none

  defp subscribed(state, sub, kind), do: %{state | subs: Map.put(state.subs, sub, kind)}

  defp dropped(state, sub), do: subscribed(state, sub, :dropped)

  defp detached(state, sub), do: %{state | subs: Map.delete(state.subs, sub)}
end
