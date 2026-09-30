defmodule Helyx.Session.Transcript do
  @moduledoc false
  # Queries over a session transcript, a list of `Helyx.Message` in order.

  alias Helyx.{Message, ModelRef}

  # The tool calls in the transcript that have no tool result yet, in call
  # order. During a turn this is exactly the calls still to answer. A
  # resumed transcript has none (see `abort_unanswered/2`).
  # A result answers the first still-open earlier call with its id, so a
  # call id a provider reuses in a later turn stays open until its own
  # result arrives.
  @spec open_calls([Message.t()]) :: [Message.ToolCall.t()]
  def open_calls(transcript) do
    Enum.reduce(transcript, [], fn
      %Message{role: :assistant, content: content}, open ->
        open ++ for %Message.ToolCall{} = call <- content, do: call

      %Message{role: :tool_result} = result, open ->
        answer(open, result)

      _message, open ->
        open
    end)
  end

  # Deleting nil is a no-op, so a result with no open call changes nothing.
  defp answer(open, %Message{tool_call_id: id}),
    do: List.delete(open, Enum.find(open, &(&1.id == id)))

  # The transcript with an `aborted` error result for each tool call that
  # has no result among the tool results right after its message. The
  # results go after those tool results, in call order. A live abort puts
  # them there too. A result after a later message answers nothing here.
  # `open_calls/1` matches such a result, but the session never writes one.
  # After this pass no call is open, so the two rules agree. A resume
  # applies this to the transcript it reads, and it writes nothing. The file
  # keeps the open call, so every resume adds the same results at the same
  # place. A transcript with no open calls is unchanged.
  #
  # The file counts the messages before each harness session. That count
  # does not include the inserted results. The live session after a resume
  # counted them. So each count grows by the results inserted at or before
  # it. A count exactly at an insert point can also come from an entry
  # written before the crash, and then the live count was lower. Both give
  # the same `resumable/3` answer, because an inserted result is never an
  # assistant message.
  @spec abort_unanswered([Message.t()], %{String.t() => {String.t(), non_neg_integer()}}) ::
          {[Message.t()], %{String.t() => {String.t(), non_neg_integer()}}}
  def abort_unanswered(transcript, harness_sessions) do
    {transcript, inserts} = insert_aborted(transcript, 0, [], [])

    shifted =
      Map.new(harness_sessions, fn {provider, {id, before}} ->
        {provider, {id, before + Enum.count(inserts, &(&1 <= before))}}
      end)

    {transcript, shifted}
  end

  # Builds the transcript reversed, and one `at` for each inserted result:
  # the number of input messages before it.
  defp insert_aborted(
         [%Message{role: :assistant, content: content} = message | rest],
         at,
         out,
         inserts
       ) do
    {results, rest} = Enum.split_while(rest, &match?(%Message{role: :tool_result}, &1))
    calls = for %Message.ToolCall{} = call <- content, do: call
    aborted = Enum.map(Enum.reduce(results, calls, &answer(&2, &1)), &aborted/1)
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

  # The harness session to resume, or nil: the last harness session of
  # `provider` in `harness_sessions` (its id and the number of transcript
  # messages before it started), when the last assistant message of the
  # transcript came from this provider after that session started. A
  # message of the harness session shows that it read the replay and the
  # prompt. Otherwise the harness does not have the transcript's end
  # (another provider answered last, or a fresh session ended before its
  # first message), and a fresh session gets it from the provider.
  @spec resumable([Message.t()], %{String.t() => {String.t(), non_neg_integer()}}, String.t()) ::
          String.t() | nil
  def resumable(transcript, harness_sessions, provider) do
    with {:ok, {harness_id, before}} <- Map.fetch(harness_sessions, provider),
         # Enum.drop/2 shares the tail of the list; it does not copy it.
         %Message{model: model} when is_binary(model) <-
           last_assistant(Enum.drop(transcript, before)),
         {:ok, %ModelRef{provider: ^provider}} <- ModelRef.parse(model) do
      harness_id
    else
      _other -> nil
    end
  end
end
