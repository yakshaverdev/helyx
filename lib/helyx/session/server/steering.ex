defmodule Helyx.Session.Server.Steering do
  @moduledoc false
  # Applies the steer state of a session (`Helyx.Session.Queue`, `queue` in
  # `Helyx.Session.Server.State`), its only writer: each change of the
  # queue counts emits `queue_update`, a taken steer joins the transcript,
  # a notice is a `:steer_unconfirmed` event, and the texts that an abort
  # drops go back to the client in one `:queue_dropped` event
  # (docs/features/session-lifecycle.md, "Steer" and "Turn end"). A
  # background end joins a turn as a steer, from a queue of its own
  # (docs/features/background-bash.md).

  import Helyx.Session.Server.State, only: [ask: 4]
  import Helyx.Session.Server.Events, only: [emit: 3, emit: 4]

  alias Helyx.Session.{Background, Hands, Id, Queue, Turn}
  alias Helyx.Session.Server.{ProviderConn, Records, State}

  # Returns the reply to the client and the state.
  def queue(%State{} = state, key, text) do
    case Queue.push(state.queue, key, text) do
      {:ok, queue} -> {:ok, put(state, {queue, []})}
      {:error, :queue_full} = error -> {error, state}
    end
  end

  # The texts of the next turn (`Queue.drain/1`), and the state without them.
  def drain(%State{} = state) do
    {texts, queue} = Queue.drain(state.queue)
    {texts, put(state, {queue, []})}
  end

  # The queued steers, then the waiting ends, join the transcript as user
  # messages, in order. Returns their texts.
  def append_steers(%State{} = state) do
    {steers, queue} = Queue.drain_steers(state.queue)
    {ends, queue} = Queue.drain_ends(queue)
    texts = steers ++ ends
    state = Enum.reduce(texts, state, &Records.append_user(&2, &1))
    Enum.each(ends, &taken(state, &1))
    {texts, put(state, {queue, []})}
  end

  # An end joined the transcript: its place among the background runs is
  # free in the hands (#587).
  defp taken(%State{hands: hands}, text), do: Hands.taken(hands, Background.id(text))

  # A background end goes to a submitted turn, or waits for a turn that
  # can take it (`send_ends/1`).
  def push_end(%State{} = state, text),
    do: send_ends(put(state, {Queue.ended(state.queue, text), []}))

  # A background run started; its end comes through `push_end/2`.
  def started(%State{} = state), do: put(state, {Queue.started(state.queue), []})

  # A turn that takes the ends opened, a prompt's or the provider's, not a
  # compaction: the ends no longer hold, and a submitted turn takes them.
  def open(%State{} = state), do: send_ends(put(state, {Queue.open(state.queue), []}))

  # In a submitted turn that is not a compaction, the waiting ends go to
  # the provider process as steers, in order, while the 32 steers have
  # room; the rest wait for the next turn. The end moves from the ends to
  # the ledger in one step, so `waiting` (`Queue.counts/1`) keeps it.
  def send_ends(%State{activity: %Turn{phase: :submitted, compact: nil}} = state) do
    case Queue.next_end(state.queue) do
      {text, queue} ->
        sent = send_steer({:end, text}, %{state | queue: queue})
        send_ends(put(state, {sent.queue, []}))

      nil ->
        state
    end
  end

  def send_ends(state), do: state

  # Accepts a client steer on a turn or a wait, in one step: it takes a
  # place in the 32 steers or is rejected with `:queue_full`. A steer on a
  # `submitted` turn, also with a context request open, goes to the
  # provider process; in `preparing` and `submitting` it stays in the local
  # queue ("Turn states"), and so it does in a wait. A sent steer counts in
  # the 32 steers until its `user_message` and its answer
  # (`Helyx.Session.Queue`). A compaction cannot be steered, so a steer on
  # its turn stays in the local queue for the next turn.
  # Returns the reply to the client and the state.
  def steer(%State{activity: %Turn{compact: compact}} = state, text) when compact != nil,
    do: queue(state, :steers, text)

  def steer(%State{activity: %Turn{phase: :submitted}} = state, text) do
    if Queue.room?(state.queue),
      do: {:ok, send_steer(text, state)},
      else: {{:error, :queue_full}, state}
  end

  def steer(state, text), do: queue(state, :steers, text)

  # At the `:ok` of the turn, the steers that waited in `submitting` go to
  # the provider process, in order, then the waiting ends. Each steer keeps
  # the place it took in the queue.
  def send_local_steers(%State{} = state) do
    {steers, queue} = Queue.drain_steers(state.queue)
    send_ends(Enum.reduce(steers, put(state, {queue, []}), &send_steer/2))
  end

  # Sends a steer, or an end `{:end, text}`, to the provider process with
  # its own id and the steer bound (see `Helyx.Session.ProviderProcess`).
  # The caller holds its place in the 32 steers.
  defp send_steer(entry, %State{activity: turn, conn: %ProviderConn{pid: pid}} = state) do
    steer_id = Id.new()
    from = ask(state, pid, {:steer, turn.id, steer_id, Queue.plain(entry)}, :reply)
    %{state | queue: Queue.sent(state.queue, from, steer_id, entry)}
  end

  # Each frees a place in the 32 steers, so a waiting end can go.
  def take(state, steer_id), do: send_ends(put(state, Queue.take(state.queue, steer_id)))

  def answer(state, from, reply),
    do: send_ends(put(state, Queue.answer(state.queue, from, reply, open?(state))))

  def abort(state), do: put(state, Queue.abort(state.queue))

  def end_turn(state, turn_id, normal?),
    do: put(state, Queue.end_turn(state.queue, turn_id, normal?))

  # The provider process ended: no steer request is open any more. Its
  # `provider_down` is the only caller (`TurnLoop`).
  def provider_down(state), do: put(state, Queue.provider_down(state.queue, open?(state)))

  # A turn that takes the ends is open (`open/1`): an end that goes back now
  # goes in it, and does not hold (#587).
  defp open?(%State{activity: activity}), do: match?(%Turn{compact: nil}, activity)

  defp put(%State{queue: old} = state, {queue, effects}) do
    state = Enum.reduce(effects, %{state | queue: queue}, &effect/2)
    counts = Queue.counts(queue)
    if counts == Queue.counts(old), do: state, else: emit(state, :queue_update, counts)
  end

  defp effect({:take, {:end, text}}, state) do
    taken(state, text)
    Records.take_steer(state, text)
  end

  defp effect({:take, text}, state), do: Records.take_steer(state, text)

  defp effect({:notice, turn_id, text}, state),
    do: emit(state, turn_id, :steer_unconfirmed, %{text: text})

  defp effect({:dropped, texts}, state), do: emit(state, :queue_dropped, %{texts: texts})
end
