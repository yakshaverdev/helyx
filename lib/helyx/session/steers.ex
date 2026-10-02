defmodule Helyx.Session.Steers do
  @moduledoc false
  # The steer ledger: each steer that a turn sent to its provider
  # process and that has no answer or no `user_message` yet, in send order,
  # as `{from, steer_id, text, state}`. `from` is the ref of the request
  # (see `Helyx.Session.ProviderProcess`). After the turn, the ledger goes to the
  # wait with the requests that are still open: no turn starts while the
  # armed kill of a steer can fire. Every entry counts in the 32 steers
  # (`docs/features/long-lived-harness.md`, "Steer").
  #
  # The states of an entry:
  #
  # - `:sent`: no answer and no `user_message` yet.
  # - `:taken`: the `user_message` came, and the answer is still open.
  # - `:answered`: an answer other than `:rejected` came, and the
  #   `user_message` is still open. Only in a turn.
  # - `:ended`: the turn ended normally with neither. `:rejected` queues the
  #   steer for the next turn; any other answer gives its notice. Only in a
  #   wait.
  # - `:noticed`: the steer got its notice at an abort or a failure, and its
  #   answer only ends the request. Only in a wait.
  #
  # The functions that change the ledger return it with the effects for the
  # session to apply, in order: `{:take, text}` (the text joins the
  # transcript), `{:requeue, text}` (the steer waits in the local queue),
  # and `{:notice, turn_id, text}` (a `:steer_unconfirmed` event).
  # `turn_id` is set at the turn end, the first time that a notice can go
  # out.

  defstruct [:turn_id, open: []]

  @type state :: :sent | :taken | :answered | :ended | :noticed
  @type t :: %__MODULE__{
          turn_id: String.t() | nil,
          open: [{reference(), String.t(), String.t(), state()}]
        }
  @type effect ::
          {:take, String.t()} | {:requeue, String.t()} | {:notice, String.t(), String.t()}

  @spec held(t()) :: non_neg_integer()
  def held(%__MODULE__{open: open}), do: length(open)

  @spec sent(t(), reference(), String.t(), String.t()) :: t()
  def sent(%__MODULE__{open: open} = ledger, from, steer_id, text),
    do: %{ledger | open: open ++ [{from, steer_id, text, :sent}]}

  # The provider took the steer `steer_id`. An id that is not open (unknown,
  # or taken already) changes nothing.
  @spec take(t(), String.t()) :: {t(), [effect()]}
  def take(%__MODULE__{open: open} = ledger, steer_id) do
    case List.keyfind(open, steer_id, 1) do
      {_from, ^steer_id, text, :sent} = entry -> {put(ledger, entry, :taken), [{:take, text}]}
      {from, ^steer_id, text, :answered} -> {delete(ledger, from), [{:take, text}]}
      _unknown_or_taken -> {ledger, []}
    end
  end

  # The answer to the steer request `from`. A ref that is not open (a late
  # answer) changes nothing.
  @spec answer(t(), reference(), term()) :: {t(), [effect()]}
  def answer(%__MODULE__{open: open} = ledger, from, reply) do
    case List.keyfind(open, from, 0) do
      {^from, _id, text, state} when state in [:sent, :ended] and reply == :rejected ->
        {delete(ledger, from), [{:requeue, text}]}

      {^from, _id, _text, :sent} = entry ->
        {put(ledger, entry, :answered), []}

      {^from, _id, text, :ended} ->
        {delete(ledger, from), [{:notice, ledger.turn_id, text}]}

      {^from, _id, _text, state} when state in [:taken, :noticed] ->
        {delete(ledger, from), []}

      nil ->
        {ledger, []}
    end
  end

  # The turn `turn_id` ended. Each steer with no `user_message` gets its
  # notice, except, at a normal end (`normal?`), one with no answer yet.
  # The entries with an open request stay for the wait.
  @spec end_turn(t(), String.t(), boolean()) :: {t(), [effect()]}
  def end_turn(%__MODULE__{} = ledger, turn_id, normal?) do
    map(%{ledger | turn_id: turn_id}, fn
      {_from, _id, text, :answered} -> {[], [{:notice, turn_id, text}]}
      {from, id, text, :sent} when normal? -> {[{from, id, text, :ended}], []}
      {from, id, text, :sent} -> {[{from, id, text, :noticed}], [{:notice, turn_id, text}]}
      taken -> {[taken], []}
    end)
  end

  # An abort in the wait: each steer that a late `:rejected` could still
  # queue gets its notice now. Its request stays open until its answer.
  @spec abort(t()) :: {t(), [effect()]}
  def abort(%__MODULE__{turn_id: turn_id} = ledger) do
    map(ledger, fn
      {from, id, text, :ended} -> {[{from, id, text, :noticed}], [{:notice, turn_id, text}]}
      entry -> {[entry], []}
    end)
  end

  # The provider process ended: no request is open any more, and the steers
  # with no notice yet get it.
  @spec provider_down(t()) :: {t(), [effect()]}
  def provider_down(%__MODULE__{} = ledger) do
    {ledger, effects} = abort(ledger)
    {%{ledger | open: []}, effects}
  end

  defp put(ledger, {from, id, text, _state}, state),
    do: %{ledger | open: List.keyreplace(ledger.open, from, 0, {from, id, text, state})}

  defp delete(ledger, from), do: %{ledger | open: List.keydelete(ledger.open, from, 0)}

  # `fun` maps an entry to `{entries, effects}`: the entry, changed or
  # not, or none when it leaves.
  defp map(%__MODULE__{open: open} = ledger, fun) do
    {open, effects} = Enum.flat_map_reduce(open, [], &collect(fun.(&1), &2))
    {%{ledger | open: open}, effects}
  end

  defp collect({entries, new}, effects), do: {entries, effects ++ new}
end
