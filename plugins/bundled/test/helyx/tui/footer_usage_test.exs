defmodule Helyx.TUI.FooterUsageTest do
  # The usage values of row 2 of the footer (#558,
  # `docs/features/usage-and-limits.md`, "The footer"): the session totals
  # and the context % that `ViewModel` folds, and the capped forms that
  # `Footer` writes. Each row comes from the live events and from a
  # snapshot of the same messages after a session file round trip, and
  # the two must agree.
  use ExUnit.Case, async: true

  import Helyx.Test.TUIRender, only: [view_model: 2]
  import Helyx.Test.ViewModelRule, only: [fold: 2]

  alias ExRatatui.Layout.Rect
  alias Helyx.{Event, Message, Usage}
  alias Helyx.Provider.ClaudeCode.Meter
  alias Helyx.Provider.Codex.Items
  alias Helyx.Provider.OpenAI.Events
  alias Helyx.Session.File.Codec
  alias Helyx.Session.Snapshot
  alias Helyx.TUI.{Footer, ViewModel}

  @model "m/x"

  defp event(type, data),
    do: %Event{
      type: type,
      session_id: "s",
      instance_id: "i",
      turn_id: "t",
      seq: seq(),
      data: data
    }

  # The fold applies each seq once, so each event gets a higher one.
  defp seq, do: System.unique_integer([:positive, :monotonic])

  # The live path: each message as the event that brings it to the TUI.
  defp live(messages, model) do
    fold(
      view_model([], model),
      for message <- messages do
        type = if message.role == :tool_result, do: :tool_execution_end, else: :message_end
        event(type, %{message: message})
      end
    )
  end

  # The path of a resume: each message through the session file, then the
  # snapshot.
  defp resumed(messages, model) do
    decoded =
      for m <- messages, do: %{m | id: "m1"} |> Codec.encode() |> JSON.encode!() |> JSON.decode!()

    snapshot(Enum.map(decoded, &Codec.decode/1), model)
  end

  # The totals of the snapshot come from the session's fold.
  defp snapshot(messages, model) do
    {usage, context} = Helyx.Session.Totals.of(messages)

    ViewModel.from_snapshot(%Snapshot{
      instance_id: "i",
      seq: 0,
      messages: messages,
      turn: nil,
      model: model,
      queue: %{steers: 0, follow_ups: 0, running: 0, held: 0, waiting: 0},
      persisting: true,
      more: false,
      usage: usage,
      context: context
    })
  end

  defp spans(vm) do
    %{text: [_row1, %{spans: spans}]} = Footer.widget("~", vm, nil, nil, nil)
    spans
  end

  defp text(vm), do: Enum.map_join(spans(vm), & &1.content)

  # Row 2 of `messages`, the same on both paths.
  defp row(messages, model \\ @model) do
    row = text(live(messages, model))
    assert text(resumed(messages, model)) == row
    row
  end

  defp assistant(usage, model \\ @model, content \\ [%Message.Text{text: "Hi."}]),
    do: %Message{role: :assistant, content: content, model: model, usage: usage}

  defp usage(fields), do: struct!(Usage, fields)

  describe "the values of a recorded stream of each provider" do
    # Two turns of one process (`claude` 2.1.296, `--model=opus`,
    # 2026-10-13); the values of `Helyx.Provider.ClaudeCode.MeterTest`.
    test "claude-code: two turns, the cost of both, the window of the serving side" do
      entry = %{"costBasis" => "list", "contextWindow" => 1_000_000, "costUSD" => 0.1}

      turn = fn meter, usage, total ->
        meter
        |> Meter.assistant(%{"model" => "claude-opus-5-5", "usage" => usage})
        |> Meter.result(%{
          "usage" => usage,
          "total_cost_usd" => total,
          "modelUsage" => %{"claude-opus-5-5" => entry}
        })
        |> Meter.done()
      end

      {first, meter} =
        turn.(
          %Meter{},
          %{
            "input_tokens" => 2,
            "cache_creation_input_tokens" => 17_836,
            "cache_read_input_tokens" => 10_960,
            "output_tokens" => 4
          },
          0.144968
        )

      {second, _meter} =
        turn.(
          meter,
          %{
            "input_tokens" => 2,
            "cache_creation_input_tokens" => 17_994,
            "cache_read_input_tokens" => 13_902,
            "output_tokens" => 4
          },
          0.2917884
        )

      model = "claude-code/opus"
      messages = [Message.user("one"), assistant(first, model), Message.user("two")]

      # Prompt tokens 60,696, of them 24,862 from the cache; the context of
      # the last call is 31,902 of 1,000,000.
      assert row(messages ++ [assistant(second, model)], model) ==
               "claude-code/opus · idle · in 60.6k out 8 · cache 40% · $0.29 list · 3%"
    end

    # `last` of two recorded notifications of one turn (codex-cli 0.162.1,
    # 2026-10-13). No price in config, so the cost is not known.
    test "codex: one turn of two calls, the window of the serving side, no cost" do
      notify = fn items, last ->
        usage = %{"last" => last, "modelContextWindow" => 475_000}
        params = %{"threadId" => "th", "turnId" => "tu", "tokenUsage" => usage}
        Items.usage(%{"params" => params}, "th", "tu", items)
      end

      items =
        %Items{}
        |> notify.(%{
          "totalTokens" => 24_444,
          "inputTokens" => 24_439,
          "cachedInputTokens" => 11_648,
          "cacheWriteInputTokens" => 0,
          "outputTokens" => 5
        })
        |> notify.(%{
          "totalTokens" => 27_912,
          "inputTokens" => 27_907,
          "cachedInputTokens" => 24_320,
          "cacheWriteInputTokens" => 0,
          "outputTokens" => 5
        })

      {:done, %{usage: usage}} = Items.terminal(%{"status" => "completed"}, items)
      model = "codex/gpt-6.1-sol"

      assert row([Message.user("one"), assistant(usage, model)], model) ==
               "codex/gpt-6.1-sol · idle · in 52.3k out 10 · cache 68% · $? · 5%"

      # A done with no notification: the unknown usage.
      {:done, %{usage: unknown}} = Items.terminal(%{"status" => "completed"}, %Items{})
      assert row([assistant(unknown, model)], model) == "codex/gpt-6.1-sol · idle · $?"
    end

    # No chunk of the gateway is recorded (`docs/research/opencode-usage.md`):
    # the chunk has the shape of the feature doc. No window and no price
    # source until #559, so neither the context % nor a cost shows.
    test "opencode-go/kimi-k2: one call, no window, no cost" do
      usage = %{
        prompt_tokens: 120,
        completion_tokens: 30,
        prompt_tokens_details: %{cached_tokens: 100}
      }

      body =
        Enum.map_join(
          [
            %{choices: [%{delta: %{content: "Hi."}, finish_reason: "stop"}]},
            %{choices: [], usage: usage}
          ],
          &"data: #{JSON.encode!(&1)}\n\n"
        ) <> "data: [DONE]\n\n"

      {:done, %{usage: usage}} =
        [body] |> Events.events(%Helyx.ModelInfo{}) |> Enum.to_list() |> List.last()

      model = "opencode-go/kimi-k2"

      assert row([Message.user("one"), assistant(usage, model)], model) ==
               "opencode-go/kimi-k2 · idle · in 120 out 30 · cache 83% · $?"
    end
  end

  describe "the cost field" do
    defp priced(cost, kind),
      do: assistant(usage(input: 100, output: 10, cost: cost, cost_kind: kind))

    # Each case also with messages of a nil usage in it: they add nothing.
    defp nils(messages), do: Enum.flat_map(messages, &[assistant(nil), &1, Message.user("go")])

    defp case_row(messages) do
      row = row(messages)
      assert row(nils(messages)) == row
      String.replace_prefix(row, "#{@model} · idle", "")
    end

    test "every usage has a cost: the sum, with list when a cost is a list price" do
      assert case_row([priced(0.5, :billed), priced(0.73, :billed)]) ==
               " · in 200 out 20 · cache 0% · $1.23"

      assert case_row([priced(0.5, :list), priced(0.73, :billed)]) ==
               " · in 200 out 20 · cache 0% · $1.23 list"
    end

    test "a usage with no cost and one with a cost: the known sum as a lower bound" do
      unknown = assistant(usage(input: 100, output: 10))

      assert case_row([unknown, priced(1.23, :billed)]) ==
               " · in 200 out 20 · cache 0% · ≥$1.23"

      assert case_row([unknown, priced(1.23, :list)]) ==
               " · in 200 out 20 · cache 0% · ≥$1.23 list"
    end

    test "no usage has a cost: $?, never with list, and no token field with no tokens" do
      assert case_row([assistant(%Usage{}), assistant(%Usage{})]) == " · $?"

      assert case_row([assistant(usage(input: 100, output: 10))]) ==
               " · in 100 out 10 · cache 0% · $?"

      # A usage in the format of a file from before #557 decodes as the
      # unknown usage.
      entry =
        %{assistant(nil) | id: "m1"} |> Codec.encode() |> Map.put("usage", %{"input_tokens" => 5})

      assert text(snapshot([Codec.decode(entry)], @model)) == "#{@model} · idle · $?"
    end

    test "no message, or only nil usages: no cost field and no token field" do
      assert row([]) == "#{@model} · idle"
      assert row([Message.user("one"), assistant(nil), Message.user("two")]) == "#{@model} · idle"
    end
  end

  describe "a tail snapshot (#658)" do
    # The totals come from the snapshot fields, which count every message
    # of the transcript; a snapshot message adds nothing to them.
    test "a tail without the usage shows the totals of the whole transcript" do
      costly =
        assistant(
          usage(
            input: 100,
            output: 10,
            cost: 0.5,
            cost_kind: :list,
            context_tokens: 40,
            context_window: 100
          )
        )

      messages = [Message.user("one"), costly, Message.user("two")]
      {usage, context} = Helyx.Session.Totals.of(messages)

      tail =
        ViewModel.from_snapshot(%Snapshot{
          instance_id: "i",
          seq: 0,
          messages: [Message.user("two")],
          more: true,
          turn: nil,
          model: @model,
          queue: %{steers: 0, follow_ups: 0, running: 0, held: 0, waiting: 0},
          persisting: true,
          usage: usage,
          context: context
        })

      assert text(tail) == row(messages)

      # A later message adds once, as on the live path.
      later = assistant(usage(input: 1, cost: 0.25, cost_kind: :list))
      live_row = text(live(messages ++ [later], @model))
      assert text(fold(tail, [event(:message_end, %{message: later})])) == live_row

      # The snapshot messages add nothing: a full snapshot with zero fields
      # shows no usage.
      empty = %Snapshot{
        instance_id: "i",
        seq: 0,
        messages: messages,
        more: false,
        turn: nil,
        model: @model,
        queue: %{steers: 0, follow_ups: 0, running: 0, held: 0, waiting: 0},
        persisting: true,
        usage: %Helyx.Session.Totals{},
        context: nil
      }

      assert text(ViewModel.from_snapshot(empty)) == "#{@model} · idle"
    end
  end

  describe "the context %" do
    defp at(tokens, window \\ 100),
      do: assistant(usage(input: 1, context_tokens: tokens, context_window: window))

    defp percent(vm), do: vm |> spans() |> List.last() |> then(&{&1.content, &1.style})

    test "dim to 70, yellow over 70, red over 90" do
      for {tokens, color} <- [{70, nil}, {71, :yellow}, {90, :yellow}, {91, :red}] do
        {content, style} = percent(live([at(tokens)], @model))
        assert content == "#{tokens}%"
        assert style.fg == color
        assert :dim in style.modifiers == (color == nil)
      end
    end

    test "the estimate adds a quarter of the bytes of the blocks after the last usage" do
      call = %Message.ToolCall{
        id: "c1",
        name: "read",
        arguments: %{"path" => String.duplicate("x", 400)}
      }

      calling =
        assistant(usage(input: 1, context_tokens: 50, context_window: 1_000), @model, [call])

      result = Message.tool_result(call, {:ok, String.duplicate("r", 400)})
      thinking = assistant(nil, @model, [%Message.Thinking{thinking: String.duplicate("t", 40)}])

      # 50 + (400 + 200 + 40) / 4 = 210 of 1,000; "é" is 2 bytes, and the
      # call is in the message of the usage, whose context tokens hold it.
      messages = [calling, result, Message.user(String.duplicate("é", 100)), thinking]
      assert row(messages) =~ ~r/ · 21%$/

      # A later call counts its name and its JSON arguments: 4 + 411 bytes.
      assert row(messages ++ [assistant(nil, @model, [%{call | id: "c2"}])]) =~ ~r/ · 31%$/

      # A new usage starts the estimate again.
      assert row(messages ++ [at(30, 1_000)]) =~ ~r/ · 3%$/
    end

    test "no % after a model change, and again after a usage of the new model" do
      old = assistant(usage(input: 1, context_tokens: 10, context_window: 100), "a/x")
      vm = live([old], "a/x")
      assert text(vm) == "a/x · idle · in 1 out 0 · cache 0% · $? · 10%"

      vm = fold(vm, [event(:model_change, %{model: "b/y"})])
      assert text(vm) == "b/y · idle · in 1 out 0 · cache 0% · $?"

      new = assistant(usage(input: 1, context_tokens: 20, context_window: 100), "b/y")
      assert text(fold(vm, [event(:message_end, %{message: new})])) =~ ~r/ · \$\? · 20%$/

      # A resume on the new model before its first usage.
      assert text(snapshot([old], "b/y")) == "b/y · idle · in 1 out 0 · cache 0% · $?"
    end

    # #697: the totals stay, the estimate takes the tokens after. A
    # compaction is an event, not a message, so this test folds the live
    # path only: a snapshot of the same messages with no compaction keeps
    # the last usage (the session applies its compaction, #712).
    test "a compaction sets the estimate to its tokens after, else hides the %" do
      row = "#{@model} · idle · in 1 out 0 · cache 0% · $?"
      vm = live([at(92)], @model)
      assert text(vm) == row <> " · 92%"

      compacted = fn vm, before, after_ ->
        data = %{trigger: :manual, tokens_before: before, tokens_after: after_}
        fold(vm, [event(:compaction, data)])
      end

      vm = compacted.(vm, 92, 4)
      assert text(vm) == row <> " · 4%"
      assert text(snapshot([at(92)], @model)) == row <> " · 92%"
      # The bytes after the compaction count again.
      vm = fold(vm, [event(:message_end, %{message: Message.user(String.duplicate("u", 40))})])
      assert text(vm) == row <> " · 14%"

      vm = compacted.(vm, 14, nil)
      assert text(vm) == row
      assert text(fold(vm, [event(:message_end, %{message: assistant(%Usage{})})])) == row

      fresh = fold(vm, [event(:message_end, %{message: at(20)})])
      assert text(fresh) == "#{@model} · idle · in 2 out 0 · cache 0% · $? · 20%"

      # Before any estimate a compaction leaves it nil.
      assert compacted.(view_model([], @model), 10, 4).context == nil
    end

    test "a usage with nil context tokens keeps the estimate and adds its bytes" do
      text = assistant(%Usage{}, @model, [%Message.Text{text: String.duplicate("t", 40)}])
      assert row([at(10), text]) == "#{@model} · idle · in 1 out 0 · cache 0% · $? · 20%"
      # Before a usage with context tokens there is no estimate.
      assert row([text]) == "#{@model} · idle · $?"
    end
  end

  describe "the capped forms" do
    defp value(fields), do: text(live([assistant(usage(fields))], @model))

    test "a token count in at most 6 columns" do
      for {n, shown} <- [
            {999, "999"},
            {1_000, "1.0k"},
            {999_999, "999.9k"},
            {1_000_000, "1.0M"},
            {999_999_999, "999.9M"},
            {1_000_000_000, "1.0B"},
            {999_999_999_999, "999.9B"},
            {1_000_000_000_000, ">999B"},
            {1_000_000_000_000_000, ">999B"}
          ] do
        assert value(input: n, output: n) =~ "in #{shown} out #{shown} ·"
        assert String.length(shown) <= 6
      end
    end

    test "a cost in at most 10 columns, then list" do
      for {cost, shown} <- [
            {0, "$0.0000"},
            {0.0042, "$0.0042"},
            {0.0099, "$0.0099"},
            {0.00999, "$0.01"},
            {0.01, "$0.01"},
            {12.34, "$12.34"},
            {99_999.99, "$99999.99"},
            {99_999.996, ">$99999"},
            {100_000, ">$99999"},
            {1.0e12, ">$99999"}
          ] do
        assert value(input: 1, cost: cost, cost_kind: :billed) =~ ~r/ · \Q#{shown}\E$/

        both = [assistant(%Usage{}), assistant(usage(input: 1, cost: cost, cost_kind: :list))]
        assert row(both) =~ ~r/ · ≥\Q#{shown}\E list$/
        assert String.length("≥" <> shown) <= 10
      end
    end

    test "a % in at most 5 columns" do
      for {tokens, shown} <- [{998, "998%"}, {999, "999%"}, {1_000, ">999%"}, {10 ** 15, ">999%"}] do
        assert value(input: 1, context_tokens: tokens, context_window: 100) =~ ~r/ · #{shown}$/
      end

      over =
        live([assistant(usage(input: 1, context_tokens: 1_000, context_window: 100))], @model)

      assert percent(over) == {">999%", %ExRatatui.Style{fg: :red}}
    end

    # The bound holds where the row is drawn: every value at its cap, and
    # the row cut at each width keeps whole characters.
    test "the row with each value at its cap, drawn and cut at the width" do
      capped = [
        assistant(%Usage{}),
        assistant(
          usage(
            input: 10 ** 15,
            output: 10 ** 15,
            cost: 1.0e12,
            cost_kind: :list,
            context_tokens: 10 ** 15,
            context_window: 1
          )
        )
      ]

      row = row(capped)
      assert row == "#{@model} · idle · in >999B out >999B · cache 0% · ≥>$99999 list · >999%"

      vm = live(capped, @model)

      for width <- 1..(String.length(row) + 2) do
        assert draw(vm, width) == row |> String.slice(0, width) |> String.trim_trailing()
      end
    end
  end

  defp draw(vm, width) do
    terminal = ExRatatui.init_test_terminal(width, 2)
    widget = Footer.widget("~", vm, nil, nil, nil)
    :ok = ExRatatui.draw(terminal, [{widget, %Rect{x: 0, y: 0, width: width, height: 2}}])

    terminal
    |> ExRatatui.get_buffer_content()
    |> String.split("\n")
    |> Enum.at(1)
    |> String.trim_trailing()
  end
end
