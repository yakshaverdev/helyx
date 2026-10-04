defmodule Helyx.Session.Transcript do
  @moduledoc false
  # Queries over a session transcript, a list of `Helyx.Message` in order.

  alias Helyx.{Message, ModelRef, Session}

  # The tool calls with no result yet, in call order: the calls of the last
  # assistant message that the tool results after it do not answer. No
  # message goes between a call and its result, so a call of an earlier
  # message is never open, and after any other message no call is. A
  # resumed transcript has none (see `repair/2`). O(n).
  @spec open_calls([Message.t()]) :: [Message.ToolCall.t()]
  def open_calls(transcript) do
    {results, rest} =
      transcript |> Enum.reverse() |> Enum.split_while(&match?(%Message{role: :tool_result}, &1))

    case rest do
      [%Message{role: :assistant} = message | _] ->
        {open, _kept, _stray} = pair(message, Enum.reverse(results))
        open

      _other ->
        []
    end
  end

  # Pairs the calls of `message` with `results`, the tool results right after
  # it. A result answers the first still-open call with its id. Gives the
  # calls left open, the results that answer a call, in order, and the
  # offset in `results` of each result that answers none.
  defp pair(%Message{content: content}, results) do
    calls = for %Message.ToolCall{} = call <- content, do: call

    {open, kept, stray} =
      results
      |> Enum.with_index()
      |> Enum.reduce({calls, [], []}, fn {%Message{tool_call_id: id} = result, offset},
                                         {open, kept, stray} ->
        case Enum.find(open, &(&1.id == id)) do
          nil -> {open, kept, [offset | stray]}
          call -> {List.delete(open, call), [result | kept], stray}
        end
      end)

    {open, Enum.reverse(kept), stray}
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
  # the stray result, so every resume makes the same repair.
  #
  # The file counts the messages before each resume id. That count does not
  # include the inserted results, and it includes the dropped ones. The live
  # session after a resume counted the repaired transcript. So each count
  # grows by the results inserted at or before it and shrinks by the results
  # dropped before it. A count exactly at an insert point can also come from
  # an entry written before the crash, and then the live count was lower.
  # Both give the same `resumable/3` answer, because an inserted or a
  # dropped result is never an assistant message.
  @spec repair([Message.t()], %{String.t() => {String.t(), non_neg_integer()}}) ::
          {[Message.t()], %{String.t() => {String.t(), non_neg_integer()}}}
  def repair(transcript, resume_ids) do
    {transcript, inserts, drops} = walk(transcript, 0, [], [], [])

    shifted =
      Map.new(resume_ids, fn {provider, {id, before}} ->
        {provider,
         {id, before + Enum.count(inserts, &(&1 <= before)) - Enum.count(drops, &(&1 < before))}}
      end)

    {transcript, shifted}
  end

  # Builds the transcript reversed. `at` is the number of input messages
  # read. Gives one `at` for each inserted result (the input messages before
  # it), and the input index of each dropped result.
  defp walk([%Message{role: :assistant} = message | rest], at, out, inserts, drops) do
    {results, rest} = Enum.split_while(rest, &match?(%Message{role: :tool_result}, &1))
    {open, kept, stray} = pair(message, results)
    drops = Enum.map(stray, &(&1 + at + 1)) ++ drops
    at = at + 1 + length(results)
    out = Enum.reverse(Enum.map(open, &aborted/1), Enum.reverse(kept, [message | out]))
    inserts = List.duplicate(at, length(open)) ++ inserts
    walk(rest, at, out, inserts, drops)
  end

  # A tool result here follows no assistant message, so it answers nothing.
  defp walk([%Message{role: :tool_result} | rest], at, out, inserts, drops),
    do: walk(rest, at + 1, out, inserts, [at | drops])

  defp walk([message | rest], at, out, inserts, drops),
    do: walk(rest, at + 1, [message | out], inserts, drops)

  defp walk([], _at, out, inserts, drops), do: {Enum.reverse(out), inserts, drops}

  defp aborted(call), do: Message.tool_result(call, Session.aborted_result())

  # The last assistant message, with no reversed copy of the transcript.
  @spec last_assistant([Message.t()]) :: Message.t() | nil
  def last_assistant(transcript) do
    Enum.reduce(transcript, nil, fn
      %Message{role: :assistant} = message, _last -> message
      _message, last -> last
    end)
  end

  # The resume id to resume, or nil: the last resume id of `provider` in
  # `resume_ids` (the id and the number of transcript messages before the
  # provider gave it), when the last assistant message of the transcript
  # came from this provider after that point and no abort or failure cut
  # it. A message under the resume id shows that the provider read the
  # replay and the prompt. Otherwise the provider does not have the
  # transcript's end (another provider answered last, the provider started
  # fresh and the turn ended before its first message, or the last message
  # is a partial reply that the session stored and the provider may not
  # keep), and the provider gets it when it starts fresh.
  @spec resumable([Message.t()], %{String.t() => {String.t(), non_neg_integer()}}, String.t()) ::
          String.t() | nil
  def resumable(transcript, resume_ids, provider) do
    with {:ok, {resume_id, before}} <- Map.fetch(resume_ids, provider),
         # Enum.drop/2 shares the tail of the list; it does not copy it.
         %Message{model: model, stop_reason: stop}
         when is_binary(model) and stop not in [:aborted, :error] <-
           last_assistant(Enum.drop(transcript, before)),
         {:ok, %ModelRef{provider: ^provider}} <- ModelRef.parse(model) do
      resume_id
    else
      _other -> nil
    end
  end
end
