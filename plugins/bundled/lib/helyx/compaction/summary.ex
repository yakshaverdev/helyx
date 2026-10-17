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
  ModelContext removed that message. With trigger `:auto` it asks
  for a summary when the estimate is over the window minus
  #{@reserve_tokens} tokens (clamped to the window); with `:manual` and
  `:overflow` it asks at once. It asks only when a cut keeps a part
  after the summary. The estimate is the `context_tokens` of the
  last usage plus a quarter of the bytes after it, or with a summary a
  quarter of the bytes of the context to send. The window is the
  `context_window` of the last usage of the same model, else the
  `:models` config. An unknown window turns off `:auto`, and `:manual`
  returns an error.

  The summary keeps about #{@keep_tokens} recent tokens, cut only at a user
  or assistant message, so a call keeps its results. Its input is the
  messages since the last summary, as text with each tool result cut to
  #{@max_result_bytes} bytes, and the last summary, which it updates.
  """

  @behaviour Helyx.Compaction

  @unknown_window "no summary: the context window of the model is unknown; " <>
                    "set it in the :models config of :helyx_plugins"

  alias Helyx.{Context, Message, ModelRef}

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

  # An overflow needs no window: the serving side said the context is over it.
  defp triggered(:overflow, context, sent, summary, opts),
    do: plan(context.messages, sent, summary, estimate(context, sent, summary), opts)

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

    kept = Enum.drop(context.messages, start(context.messages, summary))
    %{context | messages: [Message.user(framed) | kept]}
  end

  # The index of the first kept message of the summary. It is 0 with no
  # summary, and when the ModelContext removed that message: then no
  # message is trimmed, so none that the summary does not cover is lost.
  defp start(_messages, nil), do: 0

  defp start(messages, summary),
    do: Enum.find_index(messages, &(&1.id == summary.first_kept_id)) || 0

  # A plan for the messages from the last cut up to the new cut, or the
  # context to send when there is nothing new to summarize.
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
  # when the messages hold less than the keep, or no message can start
  # the kept part.
  defp cut(messages, start) do
    sizes = Enum.map(messages, &div(bytes(&1), 4))

    with from when from != nil <- keep_from(Enum.reverse(sizes), length(sizes) - 1, 0) do
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
  # kept messages count the context from before it.
  defp estimate(context, sent, nil) do
    {after_usage, usage} =
      context.messages
      |> Enum.reverse()
      |> Enum.split_while(&(not context_tokens?(&1)))

    case usage do
      [%Message{usage: %Helyx.Usage{context_tokens: tokens}} | _] ->
        tokens + div(Enum.sum_by(after_usage, &bytes/1), 4)

      [] ->
        size(sent)
    end
  end

  defp estimate(_context, sent, _summary), do: size(sent)

  defp context_tokens?(%Message{usage: %Helyx.Usage{context_tokens: n}}), do: is_integer(n)
  defp context_tokens?(_message), do: false

  defp size(%Context{system: system, messages: messages}),
    do: div(byte_size(system || "") + Enum.sum_by(messages, &bytes/1), 4)

  defp bytes(%Message{content: content}), do: Enum.sum_by(content, &block_bytes/1)

  defp block_bytes(%Message.Text{text: text}), do: byte_size(text)
  defp block_bytes(%Message.Thinking{thinking: text}), do: byte_size(text)

  defp block_bytes(%Message.ToolCall{name: name, arguments: args}),
    do: byte_size(name) + byte_size(JSON.encode!(args))

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
