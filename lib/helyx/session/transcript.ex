defmodule Helyx.Session.Transcript do
  @moduledoc false
  # Queries over a session transcript, a list of `Helyx.Message` in order.

  alias Helyx.{Message, ModelRef}

  # The tool calls with no result yet, in call order: the calls of the last
  # assistant message that the tool results after it do not answer. No
  # message goes between a call and its result, so a call of an earlier
  # message is never open, and after any other message no call is. A
  # resumed transcript has none (see `abort_unanswered/2`). O(n).
  @spec open_calls([Message.t()]) :: [Message.ToolCall.t()]
  def open_calls(transcript) do
    {results, rest} =
      transcript |> Enum.reverse() |> Enum.split_while(&match?(%Message{role: :tool_result}, &1))

    case rest do
      [%Message{role: :assistant} = message | _] -> unanswered(message, Enum.reverse(results))
      _other -> []
    end
  end

  # The calls of `message` that `results` do not answer. A result answers
  # the first still-open call with its id; deleting nil is a no-op, so a
  # result with no open call changes nothing.
  defp unanswered(%Message{content: content}, results) do
    calls = for %Message.ToolCall{} = call <- content, do: call

    Enum.reduce(results, calls, fn %Message{tool_call_id: id}, open ->
      List.delete(open, Enum.find(open, &(&1.id == id)))
    end)
  end

  # The transcript with an `aborted` error result for each tool call that
  # has no result among the tool results right after its message. The
  # results go after those tool results, in call order. A live abort puts
  # them there too. A result after a later message answers nothing, the
  # rule of `open_calls/1` at the end of the transcript. A resume
  # applies this to the transcript it reads, and it writes nothing. The file
  # keeps the open call, so every resume adds the same results at the same
  # place. A transcript with no open calls is unchanged.
  #
  # The file counts the messages before each resume id. That count
  # does not include the inserted results. The live session after a resume
  # counted them. So each count grows by the results inserted at or before
  # it. A count exactly at an insert point can also come from an entry
  # written before the crash, and then the live count was lower. Both give
  # the same `resumable/3` answer, because an inserted result is never an
  # assistant message.
  @spec abort_unanswered([Message.t()], %{String.t() => {String.t(), non_neg_integer()}}) ::
          {[Message.t()], %{String.t() => {String.t(), non_neg_integer()}}}
  def abort_unanswered(transcript, resume_ids) do
    {transcript, inserts} = insert_aborted(transcript, 0, [], [])

    shifted =
      Map.new(resume_ids, fn {provider, {id, before}} ->
        {provider, {id, before + Enum.count(inserts, &(&1 <= before))}}
      end)

    {transcript, shifted}
  end

  # Builds the transcript reversed, and one `at` for each inserted result:
  # the number of input messages before it.
  defp insert_aborted(
         [%Message{role: :assistant} = message | rest],
         at,
         out,
         inserts
       ) do
    {results, rest} = Enum.split_while(rest, &match?(%Message{role: :tool_result}, &1))
    aborted = Enum.map(unanswered(message, results), &aborted/1)
    at = at + 1 + length(results)
    out = Enum.reverse(aborted, Enum.reverse(results, [message | out]))
    inserts = List.duplicate(at, length(aborted)) ++ inserts
    insert_aborted(rest, at, out, inserts)
  end

  defp insert_aborted([message | rest], at, out, inserts),
    do: insert_aborted(rest, at + 1, [message | out], inserts)

  defp insert_aborted([], _at, out, inserts), do: {Enum.reverse(out), inserts}

  defp aborted(call), do: Message.tool_result(call, {:error, "aborted"})

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
  # came from this provider after that point. A message under the resume
  # id shows that the provider read the replay and the prompt. Otherwise
  # the provider does not have the transcript's end (another provider
  # answered last, or the provider started fresh and the turn ended before
  # its first message), and the provider gets it when it starts fresh.
  @spec resumable([Message.t()], %{String.t() => {String.t(), non_neg_integer()}}, String.t()) ::
          String.t() | nil
  def resumable(transcript, resume_ids, provider) do
    with {:ok, {resume_id, before}} <- Map.fetch(resume_ids, provider),
         # Enum.drop/2 shares the tail of the list; it does not copy it.
         %Message{model: model} when is_binary(model) <-
           last_assistant(Enum.drop(transcript, before)),
         {:ok, %ModelRef{provider: ^provider}} <- ModelRef.parse(model) do
      resume_id
    else
      _other -> nil
    end
  end
end
