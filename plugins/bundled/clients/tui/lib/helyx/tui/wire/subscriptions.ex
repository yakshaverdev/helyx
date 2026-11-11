defmodule Helyx.TUI.Wire.Subscriptions do
  @moduledoc false
  # The subscriptions of one connection (`docs/features/tui-attach.md`,
  # decisions 7, 11, and 18): which `sub` is live or dropped, what the owner
  # has acked, and the reply of a subscribe or a detach. The connection owns
  # the socket, the request ids, the waiting table, and the writer; every
  # rule about a subscription is here. A sub ends at `session_end` or at the
  # reply of an `unsubscribe` (a switch's detach); a sub that no frame
  # carries is dropped, with no request, until the server ends it
  # (wire-protocol.md, O4).

  require Helyx.TUI.Wire, as: Wire

  alias Helyx.Event

  defstruct subs: %{}, acks: %{}

  @type kind :: :live | :dropped
  @type t :: %__MODULE__{
          subs: %{String.t() => kind()},
          acks: %{String.t() => non_neg_integer()}
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
    # Only an event of a live sub is acked; a dropped sub drops its ack too.
    if live?(state, sub), do: put_in(state.acks[sub], seq), else: state
  end

  @doc false
  # The ack frames of the next batch, for the live subs only, and their
  # clear: an ack covers the events before it.
  @spec take_acks(t()) :: {[map()], t()}
  def take_acks(state) do
    acks =
      for {sub, seq} <- state.acks,
          live?(state, sub) and Wire.carries?(sub),
          do: %{"type" => "ack", "sub" => sub, "seq" => seq}

    {acks, %{state | acks: %{}}}
  end

  @doc false
  # An event of a known sub: the owner hears it when the sub is live, and a
  # dropped sub drops it. An unknown sub, and an event that the schema
  # refuses, is a contract break.
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
  # The sub stays live until the reply, so its late events still ack. A sub
  # that no frame carries has no `unsubscribe`: it is dropped until its
  # `session_end`, or the server's bound of unacked events, which closes the
  # connection with `4408`.
  @spec detach(t(), String.t()) ::
          {:ok, {:unsub, String.t()}} | {:dropped, t()} | {:error, :unknown_sub}
  def detach(state, sub) do
    cond do
      not live?(state, sub) -> {:error, :unknown_sub}
      Wire.carries?(sub) -> {:ok, {:unsub, sub}}
      true -> {:dropped, dropped(state, sub)}
    end
  end

  @doc false
  # The reply of a subscribe or a detach, and `:next` for every other op. A
  # subscribe reply whose `sub` is known is a contract break, whatever its
  # caller is: the server makes each `sub` unique on the connection. A
  # subscribe reply that comes after its deadline is dropped: the deadline
  # ends the TUI, and with it the connection, so no owner can take a sub
  # that it gave up on. A
  # late detach reply ends the sub silently; a live one gives the reply of
  # the wire to its caller.
  @spec reply(t(), term(), term(), term()) ::
          {:next, t()} | {:detached | :dropped, t()} | :broken
  def reply(%__MODULE__{subs: subs}, _caller, "subscribe", {:ok, _snapshot_or_replay, sub})
      when is_map_key(subs, sub),
      do: :broken

  def reply(state, :late, "subscribe", _result), do: {:next, state}

  def reply(state, _caller, "subscribe", {:ok, _snapshot_or_replay, sub}),
    do: {:next, subscribed(state, sub, :live)}

  def reply(state, :late, {:unsub, sub}, _result), do: {:detached, detached(state, sub)}

  # A live detach gets the reply of the wire, as every other op does.
  def reply(state, {_from, _timer}, {:unsub, sub}, _result),
    do: {:next, detached(state, sub)}

  def reply(state, _caller, _op, _result), do: {:next, state}

  defp subscribed(state, sub, kind), do: %{state | subs: Map.put(state.subs, sub, kind)}

  defp dropped(state, sub), do: subscribed(state, sub, :dropped)

  defp detached(state, sub), do: %{state | subs: Map.delete(state.subs, sub)}
end
