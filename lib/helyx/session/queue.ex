defmodule Helyx.Session.Queue do
  @moduledoc false
  # The steer state of a session, for its whole life: the queued steers and
  # follow-ups, each in arrival order, and the ledger `sent` of the steers
  # that a turn sent to its provider process, in send order, as
  # `{from, steer_id, text, state}` (`from` is the ref of the request).
  # Each queue holds at most 32, and the queued steers and the ledger share
  # the 32 of the steers (docs/features/session-lifecycle.md, "Bounds").
  #
  # The states of a ledger entry:
  #
  # - `:sent`: no answer and no `user_message` yet, in the running turn.
  # - `{:ended, turn_id}`: as `:sent`, after the end of its turn `turn_id`.
  #   The next turn does not wait for its answer, and the answer
  #   decides alone: `:rejected` queues the steer again, any other answer
  #   gives its notice.
  # - `:answered`: an answer other than `:rejected` came in the turn, and
  #   the `user_message` is open.
  # - `:settled`: the `user_message` came, or the steer got its notice. Its
  #   answer only ends the request.
  #
  # The ledger functions return the struct with the effects for the
  # session, in order: `{:take, text}` (the text joins the transcript) and
  # `{:notice, turn_id, text}` (a `:steer_unconfirmed` event).

  @limit 32

  defstruct steers: [], follow_ups: [], sent: []

  @type entry ::
          {reference(), String.t(), String.t(),
           :sent | {:ended, String.t()} | :answered | :settled}
  @type t :: %__MODULE__{
          steers: [String.t()],
          follow_ups: [String.t()],
          sent: [entry()]
        }
  @type effect :: {:take, String.t()} | {:notice, String.t(), String.t()}

  @spec push(t(), :steers | :follow_ups, String.t()) :: {:ok, t()} | {:error, :queue_full}
  def push(%__MODULE__{} = queue, :steers, text) do
    if room?(queue),
      do: {:ok, %{queue | steers: queue.steers ++ [text]}},
      else: {:error, :queue_full}
  end

  def push(%__MODULE__{follow_ups: follow_ups} = queue, :follow_ups, text) do
    if length(follow_ups) < @limit,
      do: {:ok, %{queue | follow_ups: follow_ups ++ [text]}},
      else: {:error, :queue_full}
  end

  # Whether one more steer fits beside the queued and the sent steers.
  @spec room?(t()) :: boolean()
  def room?(%__MODULE__{steers: steers, sent: sent}), do: length(steers) + length(sent) < @limit

  @spec counts(t()) :: %{steers: non_neg_integer(), follow_ups: non_neg_integer()}
  def counts(%__MODULE__{steers: steers, follow_ups: follow_ups}),
    do: %{steers: length(steers), follow_ups: length(follow_ups)}

  # Empty queues; the ledger stays.
  @spec drop(t()) :: t()
  def drop(%__MODULE__{} = queue), do: %{queue | steers: [], follow_ups: []}

  # Every queued text, steers first, and the empty queues.
  @spec drain(t()) :: {[String.t()], t()}
  def drain(%__MODULE__{} = queue), do: {queue.steers ++ queue.follow_ups, drop(queue)}

  @spec drain_steers(t()) :: {[String.t()], t()}
  def drain_steers(%__MODULE__{steers: steers} = queue), do: {steers, %{queue | steers: []}}

  # The running turn sent the steer. It does not check the limit: the
  # caller holds the place of the steer.
  @spec sent(t(), reference(), String.t(), String.t()) :: t()
  def sent(%__MODULE__{sent: sent} = queue, from, steer_id, text),
    do: %{queue | sent: sent ++ [{from, steer_id, text, :sent}]}

  # The provider took the steer `steer_id`. An id that is not open, or that
  # is taken already, changes nothing.
  @spec take(t(), String.t()) :: {t(), [effect()]}
  def take(%__MODULE__{sent: sent} = queue, steer_id) do
    case List.keyfind(sent, steer_id, 1) do
      {from, _id, text, :sent} -> {put(queue, from, :settled), [{:take, text}]}
      {from, _id, text, :answered} -> {delete(queue, from), [{:take, text}]}
      _unknown_or_settled -> {queue, []}
    end
  end

  # The answer to the steer request `from`. A ref that is not open (a late
  # answer) changes nothing. A confirmed rejection queues the steer again:
  # its place in the limit was held, so it fits.
  @spec answer(t(), reference(), term()) :: {t(), [effect()]}
  def answer(%__MODULE__{sent: sent} = queue, from, reply) do
    case List.keyfind(sent, from, 0) do
      {^from, _id, text, open} when reply == :rejected and (open == :sent or is_tuple(open)) ->
        {%{delete(queue, from) | steers: queue.steers ++ [text]}, []}

      {^from, _id, _text, :sent} ->
        {put(queue, from, :answered), []}

      {^from, _id, text, {:ended, turn_id}} ->
        {delete(queue, from), [{:notice, turn_id, text}]}

      {^from, _id, _text, :settled} ->
        {delete(queue, from), []}

      nil ->
        {queue, []}
    end
  end

  # The turn `turn_id` ended. An answered steer with no `user_message` gets
  # its notice, and a steer with no answer is `{:ended, turn_id}`. At an
  # abort or a failure (`normal?` false) a steer with no answer gets its
  # notice too, as at an abort after the turn.
  @spec end_turn(t(), String.t(), boolean()) :: {t(), [effect()]}
  def end_turn(%__MODULE__{} = queue, turn_id, true) do
    map(queue, fn
      {_from, _id, text, :answered} -> {[], [{:notice, turn_id, text}]}
      {from, id, text, :sent} -> {[{from, id, text, {:ended, turn_id}}], []}
      entry -> {[entry], []}
    end)
  end

  def end_turn(%__MODULE__{} = queue, turn_id, false) do
    {queue, notices} = end_turn(queue, turn_id, true)
    {queue, more} = abort(queue)
    {queue, notices ++ more}
  end

  # An abort after the turn: each steer that a late `:rejected` could still
  # queue gets its notice now. Its request stays open until its answer.
  @spec abort(t()) :: {t(), [effect()]}
  def abort(%__MODULE__{} = queue) do
    map(queue, fn
      {from, id, text, {:ended, turn_id}} ->
        {[{from, id, text, :settled}], [{:notice, turn_id, text}]}

      entry ->
        {[entry], []}
    end)
  end

  # The provider process ended: no request is open any more, and the steers
  # with no notice yet get it.
  @spec provider_down(t()) :: {t(), [effect()]}
  def provider_down(%__MODULE__{} = queue) do
    {queue, effects} = abort(queue)
    {%{queue | sent: []}, effects}
  end

  defp put(%__MODULE__{sent: sent} = queue, from, state) do
    {^from, id, text, _state} = List.keyfind(sent, from, 0)
    %{queue | sent: List.keyreplace(sent, from, 0, {from, id, text, state})}
  end

  defp delete(queue, from), do: %{queue | sent: List.keydelete(queue.sent, from, 0)}

  # `fun` maps an entry to `{entries, effects}`: the entry, changed or not,
  # or none when it leaves.
  defp map(%__MODULE__{sent: sent} = queue, fun) do
    {sent, effects} =
      Enum.flat_map_reduce(sent, [], fn entry, effects ->
        {entries, new} = fun.(entry)
        {entries, effects ++ new}
      end)

    {%{queue | sent: sent}, effects}
  end
end
