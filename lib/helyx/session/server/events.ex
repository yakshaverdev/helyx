defmodule Helyx.Session.Server.Events do
  @moduledoc false
  # The event stream of a session: the only writer of `seq` and
  # `subscribers` in `Helyx.Session.Server.State`. Each event gets the next
  # `seq` and goes to every subscriber; the snapshot gives the `seq` of the
  # last event (docs/features/session-snapshot.md). The records that the
  # events tell of are written in `Helyx.Session.Server.Records`.

  alias Helyx.{Event, ModelRef}
  alias Helyx.Session.{Queue, Snapshot, Turn}
  alias Helyx.Session.Server.{State, Wait}

  def subscribe(%State{} = state, pid) do
    subscribers = Map.put_new_lazy(state.subscribers, pid, fn -> Process.monitor(pid) end)
    %{state | subscribers: subscribers}
  end

  def unsubscribe(%State{} = state, pid) do
    {ref, subscribers} = Map.pop(state.subscribers, pid)
    _ = ref && Process.demonitor(ref, [:flush])
    %{state | subscribers: subscribers}
  end

  def subscriber_down(%State{subscribers: subscribers} = state, pid),
    do: %{state | subscribers: Map.delete(subscribers, pid)}

  # The state of the session in one value (`Helyx.Session.Snapshot`), with
  # the `seq` of its last event: a subscribe takes it in the same call.
  def snapshot(%State{} = state) do
    %Snapshot{
      instance_id: state.instance_id,
      seq: state.seq,
      messages: state.transcript,
      turn: turn(state.activity),
      model: ModelRef.to_string(state.model),
      queue: Queue.counts(state.queue),
      persisting: state.file != nil
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
    seq = state.seq + 1

    event = %Event{
      type: type,
      session_id: state.id,
      instance_id: state.instance_id,
      turn_id: turn_id,
      seq: seq,
      data: data
    }

    for {pid, _ref} <- state.subscribers, do: send(pid, {:helyx_event, event})

    %{state | seq: seq}
  end
end
