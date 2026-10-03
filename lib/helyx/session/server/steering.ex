defmodule Helyx.Session.Server.Steering do
  @moduledoc false
  # Applies the steer state of a session (`Helyx.Session.Queue`, `queue` in
  # `Helyx.Session.Server.State`), its only writer: each change of the
  # queue counts emits `queue_update`, a taken steer joins the transcript,
  # and a notice is a `:steer_unconfirmed` event
  # (docs/features/long-lived-harness.md, "Steer").

  import Helyx.Session.Server.State, only: [ask: 4, provider_pid: 1]
  import Helyx.Session.Server.Events, only: [emit: 3, emit: 4]

  alias Helyx.Session.{Id, Queue, Turn}
  alias Helyx.Session.Server.{ProviderConn, Records, State}

  # Returns the reply to the client and the state.
  def queue(%State{} = state, key, text) do
    case Queue.push(state.queue, key, text) do
      {:ok, queue} -> {:ok, put(state, {queue, []})}
      {:error, :queue_full} = error -> {error, state}
    end
  end

  def drop_queues(%State{} = state), do: put(state, {Queue.drop(state.queue), []})

  # Everything still queued, steers first, and the state with empty queues.
  def drain(%State{} = state) do
    {texts, queue} = Queue.drain(state.queue)
    {texts, put(state, {queue, []})}
  end

  # The queued steers join the transcript as user messages, in order.
  # Returns their texts.
  def append_steers(%State{} = state) do
    {steers, queue} = Queue.drain_steers(state.queue)
    state = Enum.reduce(steers, state, &Records.append_user(&2, &1))
    {steers, put(state, {queue, []})}
  end

  # Accepts a client steer on a turn or a wait, in one step: it takes a
  # place in the 32 steers or is rejected with `:queue_full`. A steer on a
  # `submitted` turn, also with a context request open, goes to the
  # provider process; in `preparing` and `submitting` it stays in the local
  # queue ("Turn states"), and so it does in a wait. A sent steer counts in
  # the 32 steers until its `user_message` and its answer
  # (`Helyx.Session.Queue`).
  # Returns the reply to the client and the state.
  def steer(%State{activity: %Turn{phase: phase}} = state, text)
      when phase in [:submitted, :context] do
    if Queue.room?(state.queue),
      do: {:ok, send_steer(text, state)},
      else: {{:error, :queue_full}, state}
  end

  def steer(state, text), do: queue(state, :steers, text)

  # At the `:ok` of the turn, the steers that waited in `submitting` go to
  # the provider process, in order. Each keeps the place it took in the
  # queue.
  def send_local_steers(%State{} = state) do
    {steers, queue} = Queue.drain_steers(state.queue)
    Enum.reduce(steers, put(state, {queue, []}), &send_steer/2)
  end

  # Sends a steer to the provider process with its own id and the steer
  # bound (see `Helyx.Session.ProviderProcess`). The caller holds its place
  # in the 32 steers.
  defp send_steer(text, %State{activity: turn, conn: %ProviderConn{pid: pid}} = state) do
    steer_id = Id.new()
    from = ask(state, pid, {:steer, turn.id, steer_id, text}, :reply)
    %{state | queue: Queue.sent(state.queue, from, steer_id, text)}
  end

  def take(state, steer_id), do: put(state, Queue.take(state.queue, steer_id))
  def answer(state, from, reply), do: put(state, Queue.answer(state.queue, from, reply))
  def abort(state), do: put(state, Queue.abort(state.queue))
  def provider_down(state), do: put(state, Queue.provider_down(state.queue))

  # With no provider process, no steer request of the turn is open any more.
  def end_turn(state, turn_id, normal?) do
    state = put(state, Queue.end_turn(state.queue, turn_id, normal?))
    if provider_pid(state), do: state, else: provider_down(state)
  end

  defp put(%State{queue: old} = state, {queue, effects}) do
    state = Enum.reduce(effects, %{state | queue: queue}, &effect/2)
    counts = Queue.counts(queue)
    if counts == Queue.counts(old), do: state, else: emit(state, :queue_update, counts)
  end

  defp effect({:take, text}, state), do: Records.take_steer(state, text)

  defp effect({:notice, turn_id, text}, state),
    do: emit(state, turn_id, :steer_unconfirmed, %{text: text})
end
