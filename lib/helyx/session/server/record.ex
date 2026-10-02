defmodule Helyx.Session.Server.Record do
  @moduledoc false
  # The record of a session: the only writer of `seq`, `subscribers`,
  # `transcript`, and `file` in `Helyx.Session.Server.State`. Each event
  # gets the next `seq` and goes to every subscriber; each completed message
  # joins the transcript and, when the session has one, the session file
  # (docs/features/long-lived-harness.md).

  require Logger

  alias Helyx.{Event, Message}
  alias Helyx.Session.Server.State
  alias Helyx.Session.Turn

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

  # Appends a completed message to the transcript and, when the session has
  # a file, to disk. Streamed partial messages never come through here.
  def append_message(%State{} = state, %Message{} = message) do
    state = persist(state, &Helyx.Session.File.append_message(&1, message))
    %{state | transcript: state.transcript ++ [message]}
  end

  def persist(%State{file: nil} = state, _append), do: state

  def persist(%State{file: file} = state, append) do
    %{state | file: append.(file)}
  rescue
    # A disk failure must not take the session down. The turn, or the model
    # switch, goes on in memory; persistence stays off for this session. Only
    # the disk write is caught: a value the file cannot encode is rejected
    # at the stream boundary (see `Helyx.Session.Stream`), and a model ref by
    # `ModelRef.parse/1`, so an encode error here is a
    # bug and crashes loudly rather than silently losing the rest of the
    # session. One notice tells the clients; its fixed text stays in the
    # bound of a notice, and the log has the error.
    error in File.Error ->
      Logger.warning("session file append failed, persistence off: " <> Exception.message(error))
      text = "the session file could not be written; the rest of this session is not saved"
      emit(%{state | file: nil}, turn_id(state.activity), :notice, %{text: text})
  end

  # Only the queue drain at a normal turn end fires between turns; every
  # other `emit/3` with no turn is a bug and crashes here. An event with no
  # turn by intent gives its turn id to `emit/4`.
  def emit(%State{activity: %Turn{id: turn_id}} = state, type, data),
    do: emit(state, turn_id, type, data)

  def emit(%State{} = state, :queue_update, data),
    do: emit(state, nil, :queue_update, data)

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

  defp turn_id(%Turn{id: id}), do: id
  defp turn_id(_idle_or_wait), do: nil
end
