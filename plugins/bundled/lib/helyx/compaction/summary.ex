defmodule Helyx.Compaction.Summary do
  # The recent tokens that a summary keeps, and the reserve under the
  # window that starts an automatic summary.
  @keep_tokens 20_000
  @reserve_tokens 16_384
  # The bytes of one tool result in the input of the summary call.
  @max_result_bytes 2_000

  @moduledoc """
  A compaction plugin that summarizes the older part of the transcript
  (`docs/features/summary-compaction.md`).

  Every build puts the stored summary (`opts[:summary]`) in front of the
  messages from its first kept message on, or of all messages when the
  ModelContext removed that message. With trigger `:auto` it asks for a
  summary when the estimate is over the window minus #{@reserve_tokens}
  tokens, clamped to the window; with `:manual` it asks at once. The
  estimate, the keep, and the input of the summary call are in the doc.
  """

  @behaviour Helyx.Compaction

  @unknown_window "no summary: the context window of the model is unknown; " <>
                    "set it in the :models config of :helyx_plugins"

  alias Helyx.{Context, Message, ModelRef}
  alias Helyx.Session.Totals

  @system "You write the summary of a conversation between a user and a coding agent. " <>
            "The agent continues the work from your summary alone, without the messages. " <>
            "Do not continue the conversation and do not answer it. Write only the summary."

  @sections """
  Use these sections, in this order:

  ## Goal
  ## Constraints and preferences
  ## Progress
  ### Done
  ### In progress
  ### Blocked
  ## Key decisions
  ## Next steps
  ## Critical context

  Keep exact names, values, paths, and error texts that the work needs. Be brief.
  """

  @impl true
  def compact(context, opts) do
    summary = opts[:summary]
    sent = with_summary(context, summary)

    case opts[:trigger] do
      nil -> sent
      trigger -> triggered(trigger, context, sent, summary, opts)
    end
  end

  defp triggered(trigger, context, sent, summary, opts) do
    tokens = estimate(context, sent, summary)

    case {trigger, window(context.messages, opts[:model])} do
      {:manual, nil} -> {:error, @unknown_window}
      {:auto, nil} -> sent
      {:auto, window} when tokens <= window - min(@reserve_tokens, window) -> sent
      _over_or_manual -> plan(context.messages, sent, summary, tokens, opts)
    end
  end

  # The summary, then the messages from its first kept message on, or all
  # of them when the ModelContext removed that message.
  defp with_summary(context, nil), do: context

  defp with_summary(context, summary) do
    framed =
      "The earlier part of this conversation was compacted into this summary:\n\n" <>
        "<summary>\n#{summary.text}\n</summary>"

    {before, kept} = Enum.split(context.messages, start(context.messages, summary))

    # A message that the ModelContext added has no id: the summary does not
    # cover it, so it stays after the summary.
    added = Enum.filter(before, &is_nil(&1.id))
    %{context | messages: [Message.user(framed) | added ++ kept]}
  end

  defp start(messages, summary),
    do: length(messages) - length(Helyx.Summary.kept(messages, summary))

  defp plan(messages, sent, summary, tokens, opts) do
    start = start(messages, summary)

    case cut(messages, start) do
      nil ->
        sent

      cut ->
        span = Enum.slice(messages, start, cut - start)
        prompt = Message.user(prompt(span, summary, opts))

        {:summarize,
         %Helyx.Summary.Plan{
           context: %Context{system: @system, messages: [prompt]},
           first_kept_id: Enum.at(messages, cut).id,
           tokens_before: tokens
         }}
    end
  end

  # The index of the first kept message: the first user or assistant
  # message with an id after `start`, at or after the last index from which the
  # messages to the end hold the keep, else the last such message. Nil
  # when the messages from `start` on hold less than the keep, or no
  # message can start the kept part.
  defp cut(messages, start) do
    # Only the messages from `start` on count: the part before it is
    # summarized already (#838). `keep_from` counts down from the last
    # index of `messages`, so `from` stays an index into `messages`.
    sizes = messages |> Enum.drop(start) |> Enum.map(&div(Message.bytes(&1), 4))

    with from when from != nil <- keep_from(Enum.reverse(sizes), length(messages) - 1, 0) do
      cuts =
        for {%Message{role: role, id: id}, index} <- Enum.with_index(messages),
            index > start and role in [:user, :assistant] and is_binary(id),
            do: index

      Enum.find(cuts, &(&1 >= from)) || List.last(cuts)
    end
  end

  defp keep_from([], _index, _sum), do: nil

  defp keep_from([size | rest], index, sum) do
    if sum + size >= @keep_tokens, do: index, else: keep_from(rest, index - 1, sum + size)
  end

  defp prompt(span, summary, opts) do
    previous =
      if summary,
        do:
          "\n<previous-summary>\n#{summary.text}\n</previous-summary>\n\n" <>
            "Update the previous summary with the new messages above. Keep what still holds, " <>
            "and move work that is now done to Done.\n",
        else: "\nSummarize the conversation above.\n"

    instructions =
      case opts[:instructions] do
        "" -> ""
        text -> "\nThe user asks: #{text}\n"
      end

    "<conversation>\n" <>
      Enum.map_join(span, "\n\n", &serialize/1) <>
      "\n</conversation>\n" <> previous <> instructions <> "\n" <> @sections
  end

  defp serialize(%Message{role: :tool_result} = message),
    do: "[Tool result]: " <> Helyx.Text.cap(Message.text(message), @max_result_bytes, :head)

  defp serialize(%Message{role: role, content: content}) do
    label = if role == :user, do: "[User]", else: "[Assistant]"
    Enum.map_join(content, "\n", &block(label, &1))
  end

  defp block(label, %Message.Text{text: text}), do: "#{label}: #{text}"
  defp block(_label, %Message.Thinking{thinking: text}), do: "[Assistant thinking]: #{text}"

  defp block(_label, %Message.ToolCall{name: name, arguments: args}),
    do: "[Assistant tool call]: #{name} #{JSON.encode!(args)}"

  # The estimate of #488 with no summary; with one, the usages in the
  # kept messages count the context from before it. The rule is
  # `Helyx.Session.Totals`, which the snapshot carries.
  defp estimate(context, sent, nil) do
    case Totals.of(context.messages) do
      {_totals, nil} -> size(sent)
      {_totals, %{tokens: tokens, bytes: bytes}} -> tokens + div(bytes, 4)
    end
  end

  defp estimate(_context, sent, _summary), do: size(sent)

  defp size(%Context{system: system, messages: messages}),
    do: div(byte_size(system || "") + Enum.sum_by(messages, &Message.bytes/1), 4)

  # The window of the last usage of this model, which the provider fills
  # from the serving side or `Helyx.ModelInfo`; else of config, as only the
  # provider names its catalog; nil when no source has it.
  defp window(messages, %ModelRef{} = model) do
    ref = ModelRef.to_string(model)

    Enum.find_value(Enum.reverse(messages), fn
      %Message{model: ^ref, usage: %Helyx.Usage{context_window: window}} -> window
      _message -> nil
    end) || catalog_window(model)
  end

  defp catalog_window(model) do
    case Helyx.ModelInfo.lookup(model.provider, nil, model.model) do
      {:ok, info} -> info.context_window
      {:error, _reason} -> nil
    end
  end
end
