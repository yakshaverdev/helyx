defmodule Helyx.Session.Server.Steering do
  @moduledoc false
  # The steering of a session: the only writer of `queues` in
  # `Helyx.Session.Server.State`, and the one that applies the effects of
  # the steer ledger (`Helyx.Session.Steers`). Each change of the queues
  # emits `queue_update` (docs/features/long-lived-harness.md).

  import Helyx.Session.Server.State, only: [ask: 4]
  import Helyx.Session.Server.Record, only: [emit: 3, emit: 4]

  alias Helyx.Session.{Id, Queues, Steers}
  alias Helyx.Session.Server.{Messages, ProviderConn, State}

  # Queues `text` under `key`. The steers that the turn holds count in the
  # limit of the steers.
  def queue(%State{} = state, key, text) do
    held = if key == :steers, do: held(state), else: 0

    case Queues.push(state.queues, key, text, held) do
      {:ok, queues} -> {:ok, emit_queue(%{state | queues: queues})}
      {:error, :queue_full} = error -> error
    end
  end

  defp emit_queue(%State{} = state), do: emit(state, :queue_update, Queues.counts(state.queues))

  def drop_queues(%State{queues: queues} = state) when queues == %Queues{}, do: state
  def drop_queues(%State{} = state), do: emit_queue(%{state | queues: %Queues{}})

  # Everything still queued, steers first, and the state with empty queues.
  def drain(%State{} = state) do
    case Queues.drain(state.queues) do
      {[], _queues} -> {[], state}
      {texts, queues} -> {texts, emit_queue(%{state | queues: queues})}
    end
  end

  # The queued steers join the transcript as user messages, in order.
  # Returns their texts.
  def append_steers(%State{} = state) do
    case Queues.drain_steers(state.queues) do
      {[], _queues} ->
        {[], state}

      {steers, queues} ->
        state = Enum.reduce(steers, %{state | queues: queues}, &Messages.append_user(&2, &1))
        {steers, emit_queue(state)}
    end
  end

  # The steers of the turn that have no `user_message` or no answer yet,
  # and the open steer requests of the wait after it: they count in the 32
  # steers.
  def held(%State{activity: %{steers: steers}}), do: Steers.held(steers)
  def held(_state), do: 0

  # Sends a steer to the provider process with its own id and the steer
  # bound (see `Helyx.Session.ProviderProcess`).
  def send_steer(text, %State{activity: turn, conn: %ProviderConn{pid: pid}} = state) do
    steer_id = Id.new()
    from = ask(state, pid, {:steer, turn.id, steer_id, text}, :steer)
    %{state | activity: %{turn | steers: Steers.sent(turn.steers, from, steer_id, text)}}
  end

  # At the `:ok` of the turn, the steers that waited in `submitting` go to
  # the provider process, in order.
  def send_local_steers(%State{} = state) do
    case Queues.drain_steers(state.queues) do
      {[], _queues} ->
        state

      {steers, queues} ->
        emit_queue(Enum.reduce(steers, %{state | queues: queues}, &send_steer/2))
    end
  end

  # A confirmed rejection: the steer waits in the local queue for the next
  # turn. Its place in the limit was held, so it fits.
  defp requeue_steer(%State{} = state, text) do
    {:ok, queues} = Queues.push(state.queues, :steers, text, held(state))
    emit_queue(%{state | queues: queues})
  end

  # Applies the effects of the steer ledger (see `Helyx.Session.Steers`),
  # in order.
  def steer_effects(state, effects), do: Enum.reduce(effects, state, &steer_effect/2)

  defp steer_effect({:take, text}, state), do: Messages.take_steer(state, text)
  defp steer_effect({:requeue, text}, state), do: requeue_steer(state, text)

  defp steer_effect({:notice, turn_id, text}, state),
    do: emit(state, turn_id, :steer_unconfirmed, %{text: text})
end
