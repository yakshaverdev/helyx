defmodule Helyx.Compaction.SummaryTest do
  # docs/features/summary-compaction.md, the bundled plugin.
  use ExUnit.Case, async: true

  alias Helyx.Compaction.Summary
  alias Helyx.{Context, Message, ModelRef}
  alias Helyx.Summary.Plan

  # The provider "x" has no catalog entry: the window comes from the usage
  # of the messages only.
  @model %ModelRef{provider: "x", model: "m"}

  defp user(id, text), do: %{Message.user(text) | id: id}

  defp assistant(id, text, usage \\ nil) do
    %Message{
      role: :assistant,
      id: id,
      content: [%Message.Text{text: text}],
      model: "x/m",
      usage: usage
    }
  end

  defp usage(tokens, window), do: %Helyx.Usage{context_tokens: tokens, context_window: window}

  defp tool_result(id, text),
    do: %{
      Message.tool_result(%Message.ToolCall{id: "c", name: "bash", arguments: %{}}, {:ok, text})
      | id: id
    }

  # About `tokens` tokens of text: 4 bytes each.
  defp words(tokens), do: String.duplicate("abcd", tokens)

  defp compact(messages, opts) do
    context = %Context{system: "sys", messages: messages}
    Summary.compact(context, opts ++ [model: @model, instructions: ""])
  end

  defp texts(%Context{messages: messages}), do: Enum.map(messages, &Message.text/1)

  test "with no trigger the context is the summary and the messages it keeps" do
    messages = [user("u1", "one"), assistant("a1", "two"), user("u2", "three")]
    summary = %Helyx.Summary{text: "old", first_kept_id: "a1", tokens_before: 1}

    assert compact(messages, trigger: nil) == %Context{system: "sys", messages: messages}

    assert [framed, "two", "three"] = texts(compact(messages, trigger: nil, summary: summary))
    assert framed =~ "<summary>\nold\n</summary>"
  end

  test "an automatic summary starts over the window minus the reserve" do
    window = 100_000
    small = [user("u1", words(30_000)), assistant("a1", "x", usage(window - 16_384, window))]
    # At the threshold no summary; one token over it, a summary.
    assert %Context{} = compact(small ++ [user("u2", "hi")], trigger: :auto)

    assert {:summarize, %Plan{tokens_before: 83_617}} =
             compact(small ++ [user("u2", "abcd")], trigger: :auto)

    big = [user("u1", words(30_000)), assistant("a1", "x", usage(window - 16_384, window))]

    # The first message never starts the kept part: then nothing is left to
    # summarize.
    assert {:summarize, %Plan{first_kept_id: "u2", tokens_before: tokens}} =
             compact(big ++ [user("u2", words(30_000))], trigger: :auto)

    assert tokens == window - 16_384 + 30_000

    # A window under the reserve is clamped: any estimate over 0 starts it.
    tiny = [user("u1", words(30_000)), assistant("a1", "x", usage(10, 1_000)), user("u2", "hi")]
    assert {:summarize, %Plan{}} = compact(tiny, trigger: :auto)
  end

  # #698: the footer reads the context field of the snapshot, so it shows
  # the tokens that the trigger reads.
  test "the estimate equals the context estimate of the session totals" do
    call = %Message.ToolCall{id: "c", name: "bash", arguments: %{"cmd" => words(1_000)}}

    messages = [
      user("u1", words(30_000)),
      assistant("a1", "x", usage(5_000, 200_000)),
      Map.update!(assistant("a2", "ok", usage(nil, nil)), :content, &(&1 ++ [call])),
      tool_result("t1", words(25_000))
    ]

    assert {:summarize, %Plan{tokens_before: tokens}} = compact(messages, trigger: :overflow)
    {_totals, context} = Helyx.Session.Totals.of(messages)
    assert tokens == context.tokens + div(context.bytes, 4)
    # The usage with nil context tokens keeps the estimate of a1, and the
    # call counts its name and its JSON arguments.
    bytes = byte_size("ok") + byte_size("bash") + byte_size(JSON.encode!(call.arguments))
    assert tokens == 5_000 + div(bytes, 4) + 25_000

    # Before such a usage the footer has no estimate, and the trigger reads
    # a quarter of the bytes of the context to send: "sys", "x", and the text.
    early = [user("u1", words(30_000)), assistant("a1", "x", usage(nil, 1_000)), user("u2", "y")]
    assert {:summarize, %Plan{tokens_before: 30_001}} = compact(early, trigger: :overflow)
    assert {_totals, nil} = Helyx.Session.Totals.of(early)
  end

  test "an unknown window turns off the automatic summary, and fails a manual one" do
    messages = [user("u1", words(30_000)), assistant("a1", "x"), user("u2", words(30_000))]
    assert %Context{} = compact(messages, trigger: :auto)

    assert {:error, "no summary: the context window of the model is unknown" <> _} =
             compact(messages, trigger: :manual)

    # An overflow needs no window.
    assert {:summarize, %Plan{}} = compact(messages, trigger: :overflow)
  end

  test "the cut keeps about 20,000 tokens and starts at a user or assistant message" do
    messages = [
      user("u1", words(10_000)),
      assistant("a1", words(10_000), usage(1, 200_000)),
      tool_result("t1", String.duplicate("z", 20_000)),
      tool_result("t2", words(15_000)),
      user("u2", "go on")
    ]

    # The last 20,000 tokens start inside t2; no user or assistant message
    # is at or after it but u2.
    assert {:summarize, %Plan{first_kept_id: "u2", context: context}} =
             compact(messages, trigger: :manual)

    [prompt] = texts(context)
    assert prompt =~ "[User]: abcd"
    assert prompt =~ "[Assistant]: abcd"
    # Each tool result is cut to 2,000 bytes.
    assert prompt =~ "[Tool result]: " <> String.duplicate("z", 2_000) <> "\n"
    refute prompt =~ String.duplicate("z", 2_001)
    assert prompt =~ "## Goal\n## Constraints and preferences\n"
    refute prompt =~ "previous-summary"

    # A message with no id, as a ModelContext can add, never starts the
    # kept part.
    added = [
      user("u1", words(10_000)),
      assistant("a1", "x", usage(1, 200_000)),
      Message.user(words(20_000)),
      user("u2", "go on")
    ]

    assert {:summarize, %Plan{first_kept_id: "u2"}} = compact(added, trigger: :manual)

    # Under the keep there is nothing to summarize.
    small = [user("u1", "hi"), assistant("a1", "ok", usage(1, 200_000))]
    assert compact(small, trigger: :manual) == %Context{system: "sys", messages: small}
  end

  test "a later summary covers the messages since the last one and updates it" do
    messages = [
      user("u1", "early"),
      assistant("a1", "early answer", usage(1, 200_000)),
      user("u2", words(15_000)),
      assistant("a2", words(10_000)),
      user("u3", words(15_000))
    ]

    summary = %Helyx.Summary{text: "old summary", first_kept_id: "u2", tokens_before: 1}

    # The last 20,000 tokens start inside a2.
    assert {:summarize, %Plan{first_kept_id: "a2", context: context}} =
             compact(messages, trigger: :manual, summary: summary, instructions: "the plan")

    [prompt] = texts(context)
    refute prompt =~ "early"
    assert prompt =~ "<previous-summary>\nold summary\n</previous-summary>"
    assert prompt =~ "The user asks: the plan"
  end

  defmodule DropA1 do
    @moduledoc false
    # A ModelContext that removes the message "a1".
    @behaviour Helyx.ModelContext
    @impl true
    def build(context, _opts),
      do: %{context | messages: Enum.reject(context.messages, &(&1.id == "a1"))}
  end

  test "a first kept message that the ModelContext removed trims no message" do
    messages = [
      user("u1", words(15_000)),
      assistant("a1", "early answer"),
      assistant("a2", words(10_000), usage(1, 200_000)),
      user("u3", words(15_000))
    ]

    summary = %Helyx.Summary{text: "old summary", first_kept_id: "a1", tokens_before: 1}
    opts = [summary: summary, model: @model, instructions: ""]
    prepare = &Helyx.Session.Stream.prepare(DropA1, Summary, %Context{messages: messages}, &1)

    assert {:ok, context} = prepare.([trigger: nil] ++ opts)
    assert [framed, "abcd" <> _, "abcd" <> _, "abcd" <> _] = texts(context)
    assert framed =~ "<summary>\nold summary\n</summary>"

    # A summary covers the messages from the first one on, with the last
    # summary.
    assert {:summarize, %Plan{first_kept_id: "a2", context: context}} =
             prepare.([trigger: :manual] ++ opts)

    [prompt] = texts(context)
    assert prompt =~ "[User]: abcd"
    assert prompt =~ "<previous-summary>\nold summary\n</previous-summary>"
  end
end
