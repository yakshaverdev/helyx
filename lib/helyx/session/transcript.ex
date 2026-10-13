defmodule Helyx.Session.Transcript do
  @moduledoc false
  # Queries over a session transcript, a list of `Helyx.Message` in order.

  alias Helyx.{Message, ModelRef, Session}

  # The tool calls with no result yet, in call order: the calls of the last
  # assistant message that the tool results after it do not answer. No
  # message goes between a call and its result, so a call of an earlier
  # message is never open, and after any other message no call is. A
  # resumed transcript has none (see `repair/1`). O(n).
  @spec open_calls([Message.t()]) :: [Message.ToolCall.t()]
  def open_calls(transcript) do
    {results, rest} =
      transcript |> Enum.reverse() |> Enum.split_while(&match?(%Message{role: :tool_result}, &1))

    case rest do
      [%Message{role: :assistant} = message | _] ->
        {open, _kept} = pair(message, Enum.reverse(results))
        open

      _other ->
        []
    end
  end

  # Pairs the calls of `message` with `results`, the tool results right after
  # it. A result answers the first still-open call with its id. Gives the
  # calls left open and the results that answer a call, in order.
  defp pair(%Message{content: content}, results) do
    calls = for %Message.ToolCall{} = call <- content, do: call

    {open, kept} =
      Enum.reduce(results, {calls, []}, fn %Message{tool_call_id: id} = result, {open, kept} ->
        case Enum.find(open, &(&1.id == id)) do
          nil -> {open, kept}
          call -> {List.delete(open, call), [result | kept]}
        end
      end)

    {open, Enum.reverse(kept)}
  end

  # The read-time repair of a resume. It gives the transcript with an
  # `aborted` error result for each tool call that has no result among the
  # tool results right after its message. The results go after those tool
  # results, in call order. A live abort puts them there too. It also drops
  # each tool result that answers no open call at its place: a result with
  # no call of that id, a second result for one call, or a result after a
  # later message (the pairing of `open_calls/1`). Only that result goes.
  #
  # The invariant after the repair: each tool result answers one call of the
  # assistant message right before its run of tool results, and each call
  # has exactly one result in that run. `open_calls/1` and the clients that
  # fold the transcript assume it. A second pass changes nothing.
  #
  # A resume applies this to the transcript it reads, and it writes nothing
  # (ADR 0001: a repair never truncates). The file keeps the open call and
  # the stray result, so every resume makes the same repair. It adds and
  # drops only tool results, so `assistant_count/1` holds.
  @spec repair([Message.t()]) :: [Message.t()]
  def repair(transcript), do: walk(transcript, [])

  # Builds the transcript reversed.
  defp walk([%Message{role: :assistant} = message | rest], out) do
    {results, rest} = Enum.split_while(rest, &match?(%Message{role: :tool_result}, &1))
    {open, kept} = pair(message, results)
    walk(rest, Enum.reverse(Enum.map(open, &aborted/1), Enum.reverse(kept, [message | out])))
  end

  # A tool result here follows no assistant message, so it answers nothing.
  defp walk([%Message{role: :tool_result} | rest], out), do: walk(rest, out)
  defp walk([message | rest], out), do: walk(rest, [message | out])
  defp walk([], out), do: Enum.reverse(out)

  defp aborted(call), do: Message.tool_result(call, Session.aborted_result())

  # The count that a resume label stores: the assistant messages before it.
  @spec assistant_count([Message.t()]) :: non_neg_integer()
  def assistant_count(transcript),
    do: Enum.count(transcript, &match?(%Message{role: :assistant}, &1))

  # The label of a resume id: the id, the number of assistant messages
  # before the provider gave it, and the number at the last compaction of
  # the provider's own history under that id, or nil.
  @type label :: {String.t(), non_neg_integer(), non_neg_integer() | nil}

  # The resume id to resume, or nil: the last resume id of `provider` in
  # `resume_ids`, when the last assistant message of the transcript came
  # from this provider after that point and no abort or failure cut it. A
  # message under the resume id shows that the provider read the replay
  # and the prompt. Otherwise the provider does not have the transcript's
  # end (another provider answered last, the provider started fresh and
  # the turn ended before its first message, or the last message is a
  # partial reply that the session stored and the provider may not keep),
  # and the provider gets it when it starts fresh. After a compaction under
  # the id with no assistant message after it, two checks do not apply:
  # the message under the id, and the abort or failure. The last assistant
  # message must still come from this provider. The summary is now the
  # provider's whole history, though a cut reply may not be in it
  # (docs/features/harness-compaction.md). O(n).
  @spec resumable([Message.t()], %{String.t() => label()}, String.t()) :: String.t() | nil
  def resumable(transcript, resume_ids, provider) do
    with {:ok, {resume_id, before, at}} <- Map.fetch(resume_ids, provider),
         {count, %Message{model: model, stop_reason: stop}} when is_binary(model) <-
           count_and_last_assistant(transcript),
         {:ok, %ModelRef{provider: ^provider}} <- ModelRef.parse(model),
         true <- at == count or (count > before and stop not in [:aborted, :error]) do
      resume_id
    else
      _other -> nil
    end
  end

  # The resume id of `resumable/3`, and with an id the sum of the usages
  # of the assistant messages since the provider gave it, nil when none
  # has one. All of them are the provider's: another provider's message
  # makes the next one start fresh. A provider can use this sum to find
  # the usage it reported before the resume
  # (`docs/features/usage-and-limits.md`, "Per provider"). O(n).
  @spec resume([Message.t()], %{String.t() => label()}, String.t()) ::
          {String.t() | nil, Helyx.Usage.t() | nil}
  def resume(transcript, resume_ids, provider) do
    case resumable(transcript, resume_ids, provider) do
      nil ->
        {nil, nil}

      id ->
        {_id, before, _at} = Map.fetch!(resume_ids, provider)
        usages = for %Message{role: :assistant, usage: usage} <- transcript, do: usage
        {id, usages |> Enum.drop(before) |> Enum.reduce(nil, &add/2)}
    end
  end

  defp add(nil, sum), do: sum
  defp add(usage, nil), do: usage
  defp add(usage, sum), do: Helyx.Usage.add(sum, usage)

  # A compaction of `provider` under its resume id, at the number of
  # assistant messages `count` (`resumable/3`).
  @spec compacted(%{String.t() => label()}, String.t(), non_neg_integer()) ::
          %{String.t() => label()}
  def compacted(resume_ids, provider, count) do
    case resume_ids do
      %{^provider => label} -> Map.put(resume_ids, provider, put_elem(label, 2, count))
      _no_label -> resume_ids
    end
  end

  # The number of assistant messages and the last one, with no reversed
  # copy of the transcript.
  defp count_and_last_assistant(transcript) do
    Enum.reduce(transcript, {0, nil}, fn
      %Message{role: :assistant} = message, {count, _last} -> {count + 1, message}
      _message, acc -> acc
    end)
  end
end
