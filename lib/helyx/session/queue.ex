defmodule Helyx.Session.Queue do
  @moduledoc false
  # The steer state of a session, for its whole life: the queued steers and
  # follow-ups, each in arrival order, and the ledger `sent` of the steers
  # that a turn sent to its provider process, in send order, each as a
  # `%Helyx.Session.Queue.Sent{}`. An item is a user message that the
  # session made at its admission; the queue does not look into it, so the
  # message keeps its id and origin
  # (docs/features/message-identity.md).
  # Each queue holds at most 32, and the queued steers and the ledger share
  # the 32 of the steers (docs/features/session-lifecycle.md, "Bounds").
  #
  # `%Helyx.Session.Queue.Ends{}` holds the background ends that wait, in
  # arrival order, in `items`, and counts the runs from their start answer
  # to their end in `running`; a resume starts it at 0, as its lost runs are
  # not live. `wake` is `:off` from an abort, a failed turn, a resume, or an
  # end given back with no turn open (`open?`, from the session) until a turn
  # that is not a compaction opens: the ends then wait and wake nothing
  # (docs/features/background-bash.md). An end given back while such a turn
  # is open does not hold, as the open turn takes it (#587).
  # An end that a turn sent is in the ledger as `{:end, item}`, so a
  # `:rejected` puts it back with the ends and closes `steer`: as a rejected
  # steer, no end goes as a steer again until the next turn that is not a
  # compaction opens.
  # No path drops an end: one that a turn sent and no `user_message` took
  # goes back to the front of the ends, once, and holds (`give_back/3`);
  # only a rejected one goes to the back with `steer` closed.
  #
  # The ledger states are the `status` of a `%Sent{}`.
  #
  # `continue` is the user message of a hook's continue, which starts the
  # next turn ahead of the queues, and `hook_turns` the turns in a row that
  # a continue started (docs/features/before-settle.md). An abort or a
  # failed turn drops the continue with the queues; it is no client text,
  # so it does not go back.
  #
  # The ledger functions return the struct with the effects for the
  # session, in order: `{:take, item}` (the steer or the end `{:end, item}`
  # joins the transcript),
  # `{:notice, turn_id, item}` (a `:steer_unconfirmed` event), and
  # `{:dropped, items}` (the queued items that an abort gives back to the
  # client).

  alias __MODULE__.{Ends, Sent}

  @limit 32

  defstruct steers: [], follow_ups: [], sent: [], ends: %Ends{}, continue: nil, hook_turns: 0

  @type item :: Helyx.Message.t()
  @type text :: item() | {:end, item()}
  @type t :: %__MODULE__{
          steers: [item()],
          follow_ups: [item()],
          sent: [Sent.t()],
          ends: Ends.t(),
          continue: item() | nil,
          hook_turns: non_neg_integer()
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
  def room?(%__MODULE__{steers: steers, sent: sent}),
    do: length(steers) + length(sent) < @limit

  @spec started(t()) :: t()
  def started(%__MODULE__{ends: ends} = queue),
    do: %{queue | ends: %{ends | running: ends.running + 1}}

  # Each end follows one start (`Helyx.Session.Hands`), so `running` is
  # above 0 here.
  @spec ended(t(), item()) :: t()
  def ended(%__MODULE__{ends: %Ends{running: running}} = queue, text) when running > 0,
    do: push_end(%{queue | ends: %{queue.ends | running: running - 1}}, text)

  # The runs that an abort or a failure revoked delivered no end
  # (`Helyx.Session.Hands.request_revoke/2`, ADR 0014, invariant 4): their
  # count goes and nothing is queued. Each id is a counted run, so more ids
  # than `running` is a contract violation and crashes.
  @spec revoked(t(), [String.t()]) :: t()
  def revoked(%__MODULE__{ends: %Ends{running: running} = ends} = queue, ids)
      when length(ids) <= running,
      do: %{queue | ends: %{ends | running: running - length(ids)}}

  @spec push_end(t(), item()) :: t()
  def push_end(%__MODULE__{ends: ends} = queue, text),
    do: %{queue | ends: %{ends | items: ends.items ++ [text]}}

  @spec drain_ends(t()) :: {[item()], t()}
  def drain_ends(%__MODULE__{ends: ends} = queue),
    do: {ends.items, %{queue | ends: %{ends | items: []}}}

  # The first waiting end, when one more steer fits beside the steers and
  # no end was rejected since the last turn opened, or nil.
  @spec next_end(t()) :: {item(), t()} | nil
  def next_end(%__MODULE__{ends: %Ends{steer: :closed}}), do: nil

  def next_end(%__MODULE__{ends: %Ends{items: [text | rest]} = ends} = queue) do
    if room?(queue), do: {text, %{queue | ends: %{ends | items: rest}}}
  end

  def next_end(%__MODULE__{ends: %Ends{items: []}}), do: nil

  # Whether the waiting ends start a turn of their own.
  @spec wake?(t()) :: boolean()
  def wake?(%__MODULE__{ends: %Ends{items: items, wake: wake}}),
    do: items != [] and wake == :on

  # A turn opened: the ends that arrive from now on wake the session again,
  # and go to the turn as steers.
  @spec open(t()) :: t()
  def open(%__MODULE__{ends: ends} = queue),
    do: %{queue | ends: %{ends | wake: :on, steer: :open}}

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
  def counts(%__MODULE__{ends: %Ends{items: items, running: running, wake: wake}} = queue) do
    {held, waiting} = if wake == :off, do: {length(items), 0}, else: {0, length(items)}

    sent =
      Enum.count(queue.sent, fn
        %Sent{item: {:end, _item}, status: status} when status not in [:taken, :resolved] -> true
        _other -> false
      end)

    %{
      steers: length(queue.steers),
      follow_ups: length(queue.follow_ups),
      running: running,
      held: held,
      waiting: waiting + sent
    }
  end

  # The items of the next turn: a waiting continue, else every queued
  # steer, or with none the first follow-up. Each follow-up is a turn of
  # its own; the steers join a continue turn at its send.
  @spec drain(t()) :: {[item()], t()}
  def drain(%__MODULE__{continue: %Helyx.Message{} = continue} = queue),
    do: {[continue], %{queue | continue: nil}}

  def drain(%__MODULE__{steers: [], follow_ups: [next | rest]} = queue),
    do: {[next], %{queue | follow_ups: rest}}

  def drain(%__MODULE__{} = queue), do: drain_steers(queue)

  @spec drain_steers(t()) :: {[item()], t()}
  def drain_steers(%__MODULE__{steers: steers} = queue), do: {steers, %{queue | steers: []}}

  # The running turn sent the steer, or the end `{:end, item}`. It does
  # not check the limit: the caller holds the place of the steer.
  @spec sent(t(), reference(), String.t(), text()) :: t()
  def sent(%__MODULE__{sent: sent} = queue, from, steer_id, {:end, item}),
    do: %{queue | sent: sent ++ [%Sent{from: from, id: steer_id, item: {:end, item}}]}

  def sent(%__MODULE__{sent: sent} = queue, from, steer_id, item),
    do: %{queue | sent: sent ++ [%Sent{from: from, id: steer_id, item: {:steer, item}}]}

  # The provider took the steer `steer_id`. An id that is not open, or that
  # is taken already, changes nothing.
  @spec take(t(), String.t()) :: {t(), [effect()]}
  def take(%__MODULE__{} = queue, steer_id) do
    case Enum.find(queue.sent, &(&1.id == steer_id)) do
      %Sent{from: from, status: :pending} = entry ->
        {put(queue, from, %{entry | status: :taken}), [{:take, text(entry.item)}]}

      %Sent{from: from, status: :accepted} = entry ->
        {delete(queue, from), [{:take, text(entry.item)}]}

      _unknown_or_ended ->
        {queue, []}
    end
  end

  # The answer to the steer request `from`. A ref that is not open (a late
  # answer) changes nothing. A confirmed rejection queues the steer again:
  # its place in the limit was held, so it fits. An end goes back to the
  # ends; after its turn, any answer gives it back. `open?` is true while
  # a turn that is not a compaction is open.
  @spec answer(t(), reference(), term(), boolean()) :: {t(), [effect()]}
  def answer(%__MODULE__{} = queue, from, reply, open?) do
    case Enum.find(queue.sent, &(&1.from == from)) do
      %Sent{status: status} = entry
      when reply == :rejected and status not in [:accepted, :taken, :resolved] ->
        {requeue(delete(queue, from), entry.item), []}

      %Sent{status: :pending} = entry ->
        {put(queue, from, %{entry | status: :accepted}), []}

      %Sent{status: {:ended, _turn}, item: {:end, text}} ->
        {give_back(delete(queue, from), [text], open?), []}

      %Sent{status: {:ended, turn}, item: {:steer, text}} ->
        {delete(queue, from), [{:notice, turn, text}]}

      %Sent{status: status} when status in [:taken, :resolved] ->
        {delete(queue, from), []}

      nil ->
        {queue, []}
    end
  end

  # The turn `turn_id` ended. An answered steer with no `user_message` gets
  # its notice, an answered end goes back, and a steer with no answer takes
  # `turn_id`. An abort or a failure (`normal?` false) is `abort/1` after
  # that.
  @spec end_turn(t(), String.t(), boolean()) :: {t(), [effect()]}
  def end_turn(%__MODULE__{} = queue, turn_id, true) do
    map(return_ends(queue, :answered, false), fn
      %Sent{status: :accepted} = entry ->
        {[], [{:notice, turn_id, text(entry.item)}]}

      %Sent{status: :pending} = entry ->
        {[%{entry | status: {:ended, turn_id}}], []}

      entry ->
        {[entry], []}
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

    {%{queue | steers: [], follow_ups: [], ends: %{queue.ends | wake: :off}, continue: nil},
     effects}
  end

  # A hook's continue waits for the next turn.
  @spec continue(t(), item()) :: t()
  def continue(%__MODULE__{} = queue, message), do: %{queue | continue: message}

  # The count at the start of a turn with the user messages `users`: a
  # continue counts one more; a client message, the origin `:user` or
  # `:product` of every queued text, sets it to 0; a turn with no user
  # message (background ends) leaves it.
  @spec count(t(), [item()]) :: t()
  def count(queue, []), do: queue

  def count(queue, [%Helyx.Message{origin: %{kind: :hook}}]),
    do: %{queue | hook_turns: queue.hook_turns + 1}

  def count(queue, _client), do: %{queue | hook_turns: 0}

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
  # open stays `:resolved` until its answer. A provider that took it with
  # no `user_message` can get it twice.
  defp return_ends(%__MODULE__{} = queue, which, open?) do
    {queue, texts} =
      map(queue, fn
        %Sent{status: :accepted, item: {:end, text}} ->
          {[], [text]}

        %Sent{status: status, item: {:end, text}} = entry
        when which == :all and (status == :pending or is_tuple(status)) ->
          {[%{entry | status: :resolved}], [text]}

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

  defp give_back(%__MODULE__{ends: ends} = queue, texts, open?),
    do: %{
      queue
      | ends: %{ends | items: texts ++ ends.items, wake: if(open?, do: ends.wake, else: :off)}
    }

  # Each steer that a late `:rejected` could still queue gets its notice
  # now. Its request stays open until its answer.
  defp settle(queue) do
    map(queue, fn
      %Sent{status: {:ended, turn}} = entry ->
        {[%{entry | status: :resolved}], [{:notice, turn, text(entry.item)}]}

      entry ->
        {[entry], []}
    end)
  end

  # Replaces the entry of `from`. It is in the ledger, from `sent/4` or a
  # change of it.
  defp put(%__MODULE__{sent: sent} = queue, from, %Sent{} = entry),
    do: %{queue | sent: Enum.map(sent, &if(&1.from == from, do: entry, else: &1))}

  defp requeue(%__MODULE__{ends: ends} = queue, {:end, text}),
    do: %{queue | ends: %{ends | items: ends.items ++ [text], steer: :closed}}

  defp requeue(%__MODULE__{steers: steers} = queue, {:steer, text}),
    do: %{queue | steers: steers ++ [text]}

  # The item of a ledger entry: a steer, or an end `{:end, item}`.
  @spec plain(text()) :: item()
  def plain({:end, text}), do: text
  def plain(text), do: text

  defp text({:steer, item}), do: item
  defp text({:end, item}), do: {:end, item}

  defp delete(%__MODULE__{sent: sent} = queue, from),
    do: %{queue | sent: Enum.reject(sent, &(&1.from == from))}

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
