defmodule Helyx.Session.Server.Events do
  @moduledoc false
  # The event stream of a session: the only writer of `ring` (with `seq`) and
  # `subscribers` in `Helyx.Session.Server.State`. Each event gets the next
  # `seq`, joins the replay ring, and goes to every subscriber that has
  # credits; the snapshot gives the `seq` of the last event
  # (docs/features/session-snapshot.md, docs/features/replay-ring.md). The
  # records that the events tell of are written in
  # `Helyx.Session.Server.Records`.

  alias Helyx.{Event, ModelRef}
  alias Helyx.Session.{History, Queue, Ring, Snapshot, Totals, Turn}
  alias Helyx.Session.Server.{State, Wait}

  # The unacked events of one subscriber (ADR 0008 §5).
  @credits 16_384
  def credits, do: @credits

  # The entry and the reply of a subscribe in one step: the events after
  # `after` from the ring, or the snapshot. The base of the credits is the
  # seq that the reply ends at for the subscriber, so a replayed event
  # counts. Each subscription starts with fresh credits; a repeated
  # subscribe keeps the monitor of its entry.
  def subscribe(%State{} = state, pid, ref, tail, after_) do
    {reply, base} =
      case replay(state, after_) do
        {:ok, events} -> {{:replay, events}, elem(after_, 1)}
        :error -> {snapshot(state, tail), state.ring.seq}
      end

    monitor =
      case state.subscribers do
        %{^pid => {monitor, _ref, _acked}} -> monitor
        _none -> Process.monitor(pid)
      end

    {reply, put_in(state.subscribers[pid], {monitor, ref, base})}
  end

  defp replay(%State{instance_id: id, ring: %Ring{seq: seq} = ring}, {id, after_seq})
       when after_seq <= seq,
       do: Ring.since(ring, after_seq)

  defp replay(_state, _after), do: :error

  # An ack lowers the count of its subscriber; an ack above the seq of the
  # session, or of a pid with no entry, acks nothing that the session sent.
  def ack(%State{subscribers: subscribers, ring: %Ring{seq: seq}} = state, pid, acked)
      when acked <= seq and is_map_key(subscribers, pid) do
    {monitor, ref, base} = subscribers[pid]
    put_in(state.subscribers[pid], {monitor, ref, max(base, acked)})
  end

  def ack(state, _pid, _acked), do: state

  def unsubscribe(%State{} = state, pid) do
    {entry, subscribers} = Map.pop(state.subscribers, pid)
    _ = entry && Process.demonitor(elem(entry, 0), [:flush])
    %{state | subscribers: subscribers}
  end

  def subscriber_down(%State{subscribers: subscribers} = state, pid),
    do: %{state | subscribers: Map.delete(subscribers, pid)}

  # The state of the session in one value (`Helyx.Session.Snapshot`), with
  # the `seq` of its last event: a subscribe takes it in the same call. A
  # nil `tail` gives the whole transcript.
  def snapshot(%State{} = state, tail) do
    {usage, context} = Totals.of(state.transcript, state.compacted)

    page =
      if tail,
        do: History.cut(state.transcript, tail),
        else: %{messages: state.transcript, more: false}

    %Snapshot{
      instance_id: state.instance_id,
      seq: state.ring.seq,
      messages: page.messages,
      more: page.more,
      turn: turn(state.activity),
      model: ModelRef.to_string(state.model),
      queue: Queue.counts(state.queue),
      persisting: state.file != nil,
      usage: usage,
      context: context
    }
  end

  defp turn(%Turn{} = turn), do: Turn.snapshot(turn)
  defp turn(activity), do: Wait.snapshot_turn(activity)

  # Only the queue events fire between turns: the drain at a normal turn
  # end, and an abort in a wait. Every other `emit/3` with no turn is a bug
  # and crashes here. An event with no turn by intent gives its turn id to
  # `emit/4`.
  def emit(%State{activity: %Turn{id: turn_id}} = state, type, data),
    do: emit(state, turn_id, type, data)

  def emit(%State{} = state, type, data) when type in [:queue_update, :queue_dropped],
    do: emit(state, nil, type, data)

  def emit(state, turn_id, type, data) do
    seq = state.ring.seq + 1

    event = %Event{
      type: type,
      session_id: state.id,
      instance_id: state.instance_id,
      turn_id: turn_id,
      seq: seq,
      data: data
    }

    slow = for {pid, entry} <- state.subscribers, deliver(pid, entry, event) == :slow, do: pid

    %{state | ring: Ring.push(state.ring, event), subscribers: Map.drop(state.subscribers, slow)}
  end

  # The event, or past the credits the slow end in its place: the entry
  # goes, and no event follows the end.
  defp deliver(pid, {monitor, ref, acked}, %Event{seq: seq}) when seq - acked > @credits do
    Process.demonitor(monitor, [:flush])
    send(pid, {:helyx_end, ref, :slow})
    :slow
  end

  defp deliver(pid, _entry, event), do: send(pid, {:helyx_event, event})
end
