defmodule Helyx.Session.Queue do
  @moduledoc false
  # The steer state of a session, for its whole life: the queued steers and
  # follow-ups, each in arrival order, and the ledger `sent` of the steers
  # that a turn sent to its provider process, in send order, as
  # `{from, steer_id, item, state}` (`from` is the ref of the request). An
  # item is a user message that the session made at its admission; the
  # queue does not look into it, so the message keeps its id and origin
  # (docs/features/message-identity.md).
  # Each queue holds at most 32, and the queued steers and the ledger share
  # the 32 of the steers (docs/features/session-lifecycle.md, "Bounds").
  #
  # `running` counts the background runs from their start answer to their
  # end, which then waits in `ends`; a resume starts it at 0, as its lost
  # runs are not live.
  # `ends` are the background ends that wait, in arrival order, and `hold`
  # is true from an abort, a failed turn, a resume, or an end given back
  # with no turn open (`open?`, from the session) until a turn that is not
  # a compaction opens: the ends then wait and wake nothing
  # (docs/features/background-bash.md). An end given back while such a
  # turn is open does not hold, as the open turn takes it (#587). An
  # end that a turn sent is in the ledger as `{:end, message}`, so a
  # `:rejected` puts it back with the ends and sets `rejected`: as a
  # rejected steer, no end goes as a steer again until the next turn that
  # is not a compaction opens.
  # No path drops an end: one that a turn sent and no `user_message` took
  # goes back to the front of the ends, once, and holds (`give_back/3`);
  # only a rejected one goes to the back with `rejected`.
  #
  # The states of a ledger entry:
  #
  # - `:sent`: no answer and no `user_message` yet, in the running turn.
  # - `{:ended, turn_id}`: as `:sent`, after the end of its turn `turn_id`.
  #   The next turn does not wait for its answer, and the answer
  #   decides alone: `:rejected` queues the steer again, any other answer
  #   gives its notice, or gives an end back.
  # - `:answered`: an answer other than `:rejected` came in the turn, and
  #   the `user_message` is open.
  # - `:settled`: the `user_message` came, or the steer got its notice. Its
  #   answer only ends the request.
  #
  # The ledger functions return the struct with the effects for the
  # session, in order: `{:take, item}` (the steer or the end `{:end, item}`
  # joins the transcript),
  # `{:notice, turn_id, item}` (a `:steer_unconfirmed` event), and
  # `{:dropped, items}` (the queued items that an abort gives back to the
  # client).

  @limit 32

  defstruct steers: [],
            follow_ups: [],
            sent: [],
            ends: [],
            hold: false,
            rejected: false,
            running: 0

  @type item :: Helyx.Message.t()
  @type text :: item() | {:end, item()}
  @type entry ::
          {reference(), String.t(), text(), :sent | {:ended, String.t()} | :answered | :settled}
  @type t :: %__MODULE__{
          steers: [item()],
          follow_ups: [item()],
          sent: [entry()],
          ends: [item()],
          hold: boolean(),
          rejected: boolean(),
          running: non_neg_integer()
        }
  @type effect ::
          {:take, text()} | {:notice, String.t(), item()} | {:dropped, [item()]}

  @spec push(t(), :steers | :follow_ups, item()) :: {:ok, t()} | {:error, :queue_full}
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

  @spec started(t()) :: t()
  def started(%__MODULE__{running: running} = queue), do: %{queue | running: running + 1}

  # Each end follows one start (`Helyx.Session.Hands`), so `running` is
  # above 0 here.
  @spec ended(t(), item()) :: t()
  def ended(%__MODULE__{running: running} = queue, text) when running > 0,
    do: push_end(%{queue | running: running - 1}, text)

  @spec push_end(t(), item()) :: t()
  def push_end(%__MODULE__{ends: ends} = queue, text), do: %{queue | ends: ends ++ [text]}

  @spec drain_ends(t()) :: {[item()], t()}
  def drain_ends(%__MODULE__{ends: ends} = queue), do: {ends, %{queue | ends: []}}

  # The first waiting end, when one more steer fits beside the steers and
  # no end was rejected since the last turn opened, or nil.
  @spec next_end(t()) :: {item(), t()} | nil
  def next_end(%__MODULE__{rejected: true}), do: nil

  def next_end(%__MODULE__{ends: [text | rest]} = queue) do
    if room?(queue), do: {text, %{queue | ends: rest}}
  end

  def next_end(%__MODULE__{ends: []}), do: nil

  # Whether the waiting ends start a turn of their own.
  @spec wake?(t()) :: boolean()
  def wake?(%__MODULE__{ends: ends, hold: hold}), do: ends != [] and not hold

  # A turn opened: the ends that arrive from now on wake the session again,
  # and go to the turn as steers.
  @spec open(t()) :: t()
  def open(%__MODULE__{} = queue), do: %{queue | hold: false, rejected: false}

  # The counts that a client sees (`queue_update`, the snapshot): the
  # queued steers and follow-ups, the running background runs, and the ends
  # that no turn took yet, split into the ends that hold, which open no
  # turn by themselves, and the others (`waiting`): the ends that wait for
  # a turn, and the ends that a turn sent and no `user_message` took or
  # gave back.
  @spec counts(t()) :: %{
          steers: non_neg_integer(),
          follow_ups: non_neg_integer(),
          running: non_neg_integer(),
          held: non_neg_integer(),
          waiting: non_neg_integer()
        }
  def counts(%__MODULE__{ends: ends} = queue) do
    {held, waiting} = if queue.hold, do: {length(ends), 0}, else: {0, length(ends)}
    sent = Enum.count(queue.sent, &match?({_from, _id, {:end, _text}, s} when s != :settled, &1))

    %{
      steers: length(queue.steers),
      follow_ups: length(queue.follow_ups),
      running: queue.running,
      held: held,
      waiting: waiting + sent
    }
  end

  # The items of the next turn: every queued steer, or with none the first
  # follow-up. Each follow-up is a turn of its own.
  @spec drain(t()) :: {[item()], t()}
  def drain(%__MODULE__{steers: [], follow_ups: [next | rest]} = queue),
    do: {[next], %{queue | follow_ups: rest}}

  def drain(%__MODULE__{} = queue), do: drain_steers(queue)

  @spec drain_steers(t()) :: {[item()], t()}
  def drain_steers(%__MODULE__{steers: steers} = queue), do: {steers, %{queue | steers: []}}

  # The running turn sent the steer, or the end `{:end, item}`. It does
  # not check the limit: the caller holds the place of the steer.
  @spec sent(t(), reference(), String.t(), text()) :: t()
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
  # its place in the limit was held, so it fits. An end goes back to the
  # ends; after its turn, any answer gives it back. `open?` is true while
  # a turn that is not a compaction is open.
  @spec answer(t(), reference(), term(), boolean()) :: {t(), [effect()]}
  def answer(%__MODULE__{sent: sent} = queue, from, reply, open?) do
    case List.keyfind(sent, from, 0) do
      {^from, _id, text, open} when reply == :rejected and (open == :sent or is_tuple(open)) ->
        {requeue(delete(queue, from), text), []}

      {^from, _id, _text, :sent} ->
        {put(queue, from, :answered), []}

      {^from, _id, {:end, text}, {:ended, _turn_id}} ->
        {give_back(delete(queue, from), [text], open?), []}

      {^from, _id, text, {:ended, turn_id}} ->
        {delete(queue, from), [{:notice, turn_id, text}]}

      {^from, _id, _text, :settled} ->
        {delete(queue, from), []}

      nil ->
        {queue, []}
    end
  end

  # The turn `turn_id` ended. An answered steer with no `user_message` gets
  # its notice, an answered end goes back, and a steer with no answer is
  # `{:ended, turn_id}`. An abort or a failure (`normal?` false) is
  # `abort/1` after that.
  @spec end_turn(t(), String.t(), boolean()) :: {t(), [effect()]}
  def end_turn(%__MODULE__{} = queue, turn_id, true) do
    map(return_ends(queue, :answered, false), fn
      {_from, _id, text, :answered} -> {[], [{:notice, turn_id, text}]}
      {from, id, text, :sent} -> {[{from, id, text, {:ended, turn_id}}], []}
      entry -> {[entry], []}
    end)
  end

  # Every end goes back first, so the `return_ends/2` of `abort/1` then
  # finds none.
  def end_turn(%__MODULE__{} = queue, turn_id, false) do
    {queue, notices} = end_turn(return_ends(queue, :all, false), turn_id, true)
    {queue, more} = abort(queue)
    {queue, notices ++ more}
  end

  # An abort, in or after a turn, or a failed turn: both queues empty, and
  # their texts, steers first, are one `{:dropped, texts}` after the
  # notices of `settle/1`, when a text was queued. The ends stay, and hold.
  @spec abort(t()) :: {t(), [effect()]}
  def abort(%__MODULE__{} = queue) do
    {queue, notices} = settle(return_ends(queue, :all, false))
    dropped = queue.steers ++ queue.follow_ups
    effects = if dropped == [], do: notices, else: notices ++ [{:dropped, dropped}]
    {%{queue | steers: [], follow_ups: [], hold: true}, effects}
  end

  # The provider process ended: no request is open any more, and the steers
  # with no notice yet get it. The queues stay, also in a turn that
  # prepares: it connects a new provider process and sends them. `open?`
  # as in `answer/4`.
  @spec provider_down(t(), boolean()) :: {t(), [effect()]}
  def provider_down(%__MODULE__{} = queue, open?) do
    {queue, effects} = settle(return_ends(queue, :all, open?))
    {%{queue | sent: []}, effects}
  end

  # Each sent end that no `user_message` took goes back, with no notice:
  # the answered ones, or with `:all` every one; a request that is still
  # open stays `:settled` until its answer. A provider that took it with no
  # `user_message` can get it twice.
  defp return_ends(%__MODULE__{} = queue, which, open?) do
    {queue, texts} =
      map(queue, fn
        {_from, _id, {:end, text}, :answered} ->
          {[], [text]}

        {from, id, {:end, text} = e, s} when which == :all and s != :settled ->
          {[{from, id, e, :settled}], [text]}

        entry ->
          {[entry], []}
      end)

    give_back(queue, texts, open?)
  end

  # Ends that a turn did not deliver go to the front of the ends, in send
  # order among them. With no turn open they hold: they wait for the next
  # prompt, so a provider that fails them again starts no turn by itself.
  # An open turn takes them, so they do not hold past it.
  defp give_back(queue, [], _open?), do: queue

  defp give_back(queue, texts, open?),
    do: %{queue | ends: texts ++ queue.ends, hold: queue.hold or not open?}

  # Each steer that a late `:rejected` could still queue gets its notice
  # now. Its request stays open until its answer.
  defp settle(queue) do
    map(queue, fn
      {from, id, text, {:ended, turn_id}} ->
        {[{from, id, text, :settled}], [{:notice, turn_id, text}]}

      entry ->
        {[entry], []}
    end)
  end

  defp put(%__MODULE__{sent: sent} = queue, from, state) do
    {^from, id, text, _state} = List.keyfind(sent, from, 0)
    %{queue | sent: List.keyreplace(sent, from, 0, {from, id, text, state})}
  end

  defp requeue(queue, {:end, text}), do: %{queue | ends: queue.ends ++ [text], rejected: true}
  defp requeue(queue, text), do: %{queue | steers: queue.steers ++ [text]}

  # The item of a ledger entry: a steer, or an end `{:end, item}`.
  @spec plain(text()) :: item()
  def plain({:end, text}), do: text
  def plain(text), do: text

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
