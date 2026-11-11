defmodule Helyx.Session.Transcript do
  @moduledoc false
  # Queries over a session transcript, a list of `Helyx.Message` in order, some
  # with the open assistant content of the running turn.

  alias Helyx.{Message, ModelRef}

  # The result of a call that a resume finds open: the session stopped while it
  # ran, so it may have run (docs/features/interrupted-calls.md). A live abort
  # writes `Helyx.Session.aborted_result/0` instead.
  @interrupted "The session stopped while this tool call ran, and its result was lost. " <>
                 "The call may have run in full, in part, or not at all. " <>
                 "Check its effects before you repeat it."

  # The calls of the last assistant message that the tool results after it do
  # not answer. No message goes between a call and its result, so a call of an
  # earlier message is never open, and after any other message no call is.
  @spec open_calls([Message.t()]) :: [Message.ToolCall.t()]
  def open_calls(transcript) do
    {results, rest} =
      transcript |> Enum.reverse() |> Enum.split_while(&match?(%Message{role: :tool_result}, &1))

    case rest do
      [%Message{role: :assistant} = message | _] ->
        {open, _kept} = pair(message, Enum.reverse(results))
        Enum.map(open, &elem(&1, 0))

      _other ->
        []
    end
  end

  # Whether `call_id` names an open call: a call of the open assistant content
  # `partial` (a reversed block list, or nil), or one of `open_calls/1`.
  @spec open_call?([Message.t()], [Message.block()] | nil, String.t()) :: boolean()
  def open_call?(transcript, partial, call_id) do
    Enum.any?(partial || [], &match?(%Message.ToolCall{id: ^call_id}, &1)) or
      Enum.any?(open_calls(transcript), &(&1.id == call_id))
  end

  # Whether the transcript holds a result of `call_id` and the call is not open
  # again: a request that names it runs once more (#369), but the call is
  # answered.
  @spec answered?([Message.t()], [Message.block()] | nil, String.t()) :: boolean()
  def answered?(transcript, partial, call_id) do
    Enum.any?(transcript, &match?(%Message{role: :tool_result, tool_call_id: ^call_id}, &1)) and
      not open_call?(transcript, partial, call_id)
  end

  # Pairs the calls of `message` with `results`, the tool results right after
  # it. A result answers the first still-open call with its id. Gives the calls
  # left open, each with its place among the calls of the message, and the
  # results that answer a call, in order.
  defp pair(%Message{content: content}, results) do
    calls = Enum.with_index(for %Message.ToolCall{} = call <- content, do: call)

    {open, kept} =
      Enum.reduce(results, {calls, []}, fn %Message{tool_call_id: id} = result, {open, kept} ->
        case Enum.find(open, &match?({%Message.ToolCall{id: ^id}, _place}, &1)) do
          nil -> {open, kept}
          call -> {List.delete(open, call), [result | kept]}
        end
      end)

    {open, Enum.reverse(kept)}
  end

  # The read-time repair of a resume: an `interrupted_result/0` for each tool
  # call that has no result among the tool results right after its message, and
  # no tool result that answers no open call at its place. Only that result
  # goes. The invariant after it: each tool result answers one call of the
  # assistant message right before its run, and each call has exactly one
  # result there. A resume writes nothing (ADR 0001), so every resume makes the
  # same repair (docs/features/interrupted-calls.md).
  @spec repair([Message.t()]) :: [Message.t()]
  def repair(transcript), do: walk(transcript, [])

  # Builds the transcript reversed.
  defp walk([%Message{role: :assistant} = message | rest], out) do
    {results, rest} = Enum.split_while(rest, &match?(%Message{role: :tool_result}, &1))
    {open, kept} = pair(message, results)
    results = Enum.map(open, &interrupted(message, &1))
    walk(rest, Enum.reverse(results, Enum.reverse(kept, [message | out])))
  end

  # A tool result here follows no assistant message, so it answers nothing.
  defp walk([%Message{role: :tool_result} | rest], out), do: walk(rest, out)
  defp walk([message | rest], out), do: walk(rest, [message | out])
  defp walk([], out), do: Enum.reverse(out)

  # The result is not written, so its id is derived, the same at each resume:
  # the id of the assistant message and the place of the call in it, as a
  # provider call id can repeat. `:` is not in the alphabet of
  # `Helyx.Session.Id.new/0` (docs/features/message-identity.md).
  defp interrupted(%Message{id: id}, {call, place}),
    do: %{Message.tool_result(call, interrupted_result()) | id: id <> ":" <> to_string(place)}

  # The result of a call that a resume finds open.
  @spec interrupted_result() :: {:error, String.t()}
  def interrupted_result, do: {:error, @interrupted}

  # The count that a resume label stores: the assistant messages before it.
  @spec assistant_count([Message.t()]) :: non_neg_integer()
  def assistant_count(transcript),
    do: Enum.count(transcript, &match?(%Message{role: :assistant}, &1))

  # The label of a resume id: the id, the number of assistant messages before
  # the provider gave it, and the number at the last compaction of the
  # provider's own history under that id, or nil.
  @type label :: {String.t(), non_neg_integer(), non_neg_integer() | nil}

  # The label of the resume id to resume, or nil: the last label of `provider`
  # in `resume_ids`, when the last assistant message came from this provider
  # after that point and no abort or failure cut it. Otherwise the provider
  # starts fresh. A compaction under the id after the last assistant message
  # makes the message check and the abort check unnecessary. An interrupted
  # result of the last assistant message makes the provider start fresh, when
  # the id came before that message (#584)
  # (docs/features/harness-compaction.md).
  @spec resumable([Message.t()], %{String.t() => label()}, String.t()) :: label() | nil
  def resumable(transcript, resume_ids, provider) do
    with {:ok, {_id, before, at} = label} <- Map.fetch(resume_ids, provider),
         {count, %Message{model: model, stop_reason: stop}, interrupted?} when is_binary(model) <-
           count_and_last_assistant(transcript),
         {:ok, %ModelRef{provider: ^provider}} <- ModelRef.parse(model),
         true <- at == count or (count > before and stop not in [:aborted, :error]),
         false <- interrupted? and count > before do
      label
    else
      _other -> nil
    end
  end

  # The usage sum of the assistant messages since the provider gave the id, for
  # a provider that finds its earlier usage by it
  # (docs/features/usage-and-limits.md). When the last message that is not a
  # tool result is not an assistant message with a usage, the last turn ended
  # with no `done`, and the sum's cost is nil.
  @spec resume([Message.t()], %{String.t() => label()}, String.t()) ::
          {String.t() | nil, Helyx.Usage.t() | nil}
  def resume(transcript, resume_ids, provider) do
    case resumable(transcript, resume_ids, provider) do
      nil ->
        {nil, nil}

      {id, before, _at} ->
        usages = for %Message{role: :assistant, usage: usage} <- transcript, do: usage
        sum = usages |> Enum.drop(before) |> Enum.reduce(nil, &add/2)
        {id, if(done_last?(transcript), do: sum, else: unknown(sum))}
    end
  end

  defp unknown(sum), do: %{(sum || %Helyx.Usage{}) | cost: nil, cost_kind: nil}

  defp done_last?(transcript) do
    last =
      Enum.reduce(transcript, nil, fn
        %Message{role: :tool_result}, last -> last
        message, _last -> message
      end)

    match?(%Message{role: :assistant, usage: %Helyx.Usage{}}, last)
  end

  defp add(nil, sum), do: sum
  defp add(usage, nil), do: usage
  defp add(usage, sum), do: Helyx.Usage.add(sum, usage)

  # A compaction of `provider` under its resume id, at the number of assistant
  # messages `count` (`resumable/3`).
  @spec compacted(%{String.t() => label()}, String.t(), non_neg_integer()) ::
          %{String.t() => label()}
  def compacted(resume_ids, provider, count) do
    case resume_ids do
      %{^provider => label} -> Map.put(resume_ids, provider, put_elem(label, 2, count))
      _no_label -> resume_ids
    end
  end

  # The number of assistant messages, the last one, and whether an interrupted
  # result follows it, with no reversed copy of the transcript.
  defp count_and_last_assistant(transcript) do
    Enum.reduce(transcript, {0, nil, false}, fn
      %Message{role: :assistant} = message, {count, _last, _interrupted} ->
        {count + 1, message, false}

      %Message{role: :tool_result, is_error: true} = result, {count, last, interrupted} ->
        {count, last, interrupted or Message.text(result) == @interrupted}

      _message, acc ->
        acc
    end)
  end
end
