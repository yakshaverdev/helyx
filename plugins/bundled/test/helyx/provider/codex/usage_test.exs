defmodule Helyx.Provider.Codex.UsageTest do
  # The usage of a Codex `done` (`docs/features/usage-and-limits.md`, "Per
  # provider"): the sum of `tokenUsage.last` since the last `done`.
  use ExUnit.Case, async: true

  import Helyx.Test.CodexFake
  import Helyx.Test.Events

  alias Helyx.Message
  alias Helyx.Provider.Codex.Items

  # `last` of two recorded notifications (codex-cli 0.162.1, 2026-10-13).
  @call1 %{
    "totalTokens" => 24_444,
    "inputTokens" => 24_439,
    "cachedInputTokens" => 11_648,
    "cacheWriteInputTokens" => 0,
    "outputTokens" => 5,
    "reasoningOutputTokens" => 0
  }
  @call2 %{
    "totalTokens" => 27_912,
    "inputTokens" => 27_907,
    "cachedInputTokens" => 24_320,
    "cacheWriteInputTokens" => 0,
    "outputTokens" => 5,
    "reasoningOutputTokens" => 0
  }

  defp params(last, window \\ 475_000),
    do: %{"tokenUsage" => %{"last" => last, "total" => last, "modelContextWindow" => window}}

  # A line of the running turn "tu" of the thread "th".
  defp line(params), do: %{"params" => Map.merge(%{"threadId" => "th", "turnId" => "tu"}, params)}

  defp notify(items, last, window \\ 475_000),
    do: Items.usage(line(params(last, window)), "th", "tu", items)

  defp done_usage(items) do
    {:done, %{usage: usage}} = Items.terminal(%{"status" => "completed"}, items)
    usage
  end

  test "two notifications give the sum, with the context of the last" do
    items = %Items{} |> notify(@call1) |> notify(@call2, 400_000)

    assert done_usage(items) == %Helyx.Usage{
             input: 24_439 - 11_648 + 27_907 - 24_320,
             output: 10,
             cache_read: 11_648 + 24_320,
             cache_write: 0,
             context_tokens: 27_912,
             context_window: 400_000
           }
  end

  test "a done with no notification has the unknown usage" do
    assert done_usage(%Items{}) == %Helyx.Usage{}
  end

  test "a turn with no done keeps the sum and sets the flag; a done starts a new one" do
    items = notify(%Items{}, @call1)
    kept = Items.next({:error, {:codex, "interrupted", ""}}, items)
    assert %Items{usage: usage, lost?: true} = kept
    assert usage == items.usage
    assert Items.next({:done, %{}}, items) == %Items{}
  end

  # Prices in USD per million tokens; `info` as `Helyx.ModelInfo.lookup/3`
  # gives it.
  @prices %{input: 2.0, output: 10.0, cache_read: 0.5, cache_write: 4.0}
  @priced %Items{info: %Helyx.ModelInfo{context_window: 400_000, prices: @prices}}

  defp call_cost(last),
    do:
      (last["inputTokens"] - last["cachedInputTokens"]) * 2.0e-6 + last["outputTokens"] * 1.0e-5 +
        last["cachedInputTokens"] * 5.0e-7

  test "two priced calls give the sum of the two costs, kind :list" do
    usage = @priced |> notify(@call1) |> notify(@call2) |> done_usage()
    assert %Helyx.Usage{cost_kind: :list, cost: cost} = usage
    assert_in_delta cost, call_cost(@call1) + call_cost(@call2), 1.0e-12
  end

  # docs/features/harness-compaction.md: the compaction call goes into the
  # next `done`, once, priced as any call.
  test "a priced compaction call goes into the cost of the next done, once" do
    compact = notify(%{@priced | compact?: true}, @call1)
    assert done_usage(compact) == nil

    items = notify(Items.next({:done, %{}}, compact), @call2)
    assert %Helyx.Usage{cost_kind: :list, cost: cost} = done_usage(items)
    assert_in_delta cost, call_cost(@call1) + call_cost(@call2), 1.0e-12

    after_done = Items.next({:done, %{}}, items)
    assert %Helyx.Usage{cost: cost} = after_done |> notify(@call2) |> done_usage()
    assert_in_delta cost, call_cost(@call2), 1.0e-12
  end

  test "the serving side window wins over config; config gives a window the serving side lacks" do
    assert %Helyx.Usage{context_window: 475_000} = @priced |> notify(@call1) |> done_usage()

    assert %Helyx.Usage{context_window: 400_000} = @priced |> notify(@call1, nil) |> done_usage()

    assert %Helyx.Usage{context_window: nil, cost: nil} =
             done_usage(notify(%Items{}, @call1, nil))
  end

  # The bad-shape path of a usage notification: it adds nothing and sets
  # the flag, as a value outside the wire bound does.
  test "a usage notification with a bad shape sets the flag" do
    items = notify(@priced, @call1)

    for params <- [
          %{"tokenUsage" => %{"last" => nil}},
          %{"tokenUsage" => %{"last" => [1]}},
          %{"tokenUsage" => %{"total" => @call1}},
          %{"tokenUsage" => "x"},
          %{},
          %{"tokenUsage" => %{"last" => %{}}},
          %{"tokenUsage" => %{"last" => %{"inputTokens" => 1000}}},
          %{"tokenUsage" => %{"last" => %{"outputTokens" => 5}}}
        ] do
      lost = Items.usage(line(params), "th", "tu", items)
      assert lost == %{items | lost?: true}
      assert %Helyx.Usage{cost: nil} = done_usage(lost)
    end
  end

  test "a line of another turn, or with no turn, sets the flag; a good line of another thread adds nothing" do
    items = notify(@priced, @call1)
    good = params(@call2)
    assert Items.usage(line(good), "th", "other turn", items) == %{items | lost?: true}
    assert Items.usage(line(good), "th", nil, items) == %{items | lost?: true}
    assert Items.usage(line(Map.put(good, "threadId", "child")), "th", "tu", items) == items
  end

  # The probes of #557 saw `cacheWriteInputTokens` only at 0: whether
  # `inputTokens` holds it is not known (research note).
  test "a call with cache writes has no cost, so the done has none" do
    items = @priced |> notify(@call1) |> notify(%{@call2 | "cacheWriteInputTokens" => 1})
    assert %Helyx.Usage{cache_write: 1, cost: nil, cost_kind: nil} = done_usage(items)
  end

  test "the flag makes the cost of the next done nil, and the done clears it" do
    bad = %{@call1 | "inputTokens" => -1}
    lost = @priced |> notify(@call1) |> notify(bad) |> notify(@call2)
    assert %Helyx.Usage{cost: nil, output: 10} = done_usage(lost)

    interrupted = Items.next({:error, {:codex, "interrupted", ""}}, notify(@priced, @call1))
    assert %Helyx.Usage{cost: nil} = interrupted |> notify(@call2) |> done_usage()

    next = Items.next({:done, %{}}, lost)
    assert %Helyx.Usage{cost: cost} = next |> notify(@call2) |> done_usage()
    assert_in_delta cost, call_cost(@call2), 1.0e-12
  end

  # The wire bound: a value at the bound is mapped, one over adds nothing.
  test "a count over 10^9, a window outside 1 to 10^9, or more cached than input add nothing and set the flag" do
    at = %{"inputTokens" => 10 ** 9, "outputTokens" => 10 ** 9, "totalTokens" => 10 ** 9}
    items = notify(%Items{}, at, 10 ** 9)
    assert %Helyx.Usage{input: 1_000_000_000, context_window: 1_000_000_000} = done_usage(items)

    for {last, window} <- [
          {%{at | "inputTokens" => 10 ** 9 + 1}, 1},
          {%{at | "outputTokens" => 10 ** 9 + 1}, 1},
          {%{at | "totalTokens" => 10 ** 9 + 1}, 1},
          {Map.put(at, "cacheWriteInputTokens", 10 ** 9 + 1), 1},
          {%{"inputTokens" => 5, "cachedInputTokens" => 6}, 1},
          {%{"inputTokens" => "5"}, 1},
          {at, 10 ** 9 + 1},
          {at, 0}
        ] do
      assert notify(items, last, window) == %{items | lost?: true}
    end
  end

  describe "through the provider process" do
    @describetag :tmp_dir
    setup {Helyx.Test.CodexFake, :setup_fake}

    defp usage_note(last), do: usage(tid(), params(last)["tokenUsage"])

    test "an interrupted turn, then a completed turn: the done holds both", %{bin: bin} = ctx do
      fresh(bin, 1, tid(), [usage_note(@call1), turn_end(tid(), "interrupted")])

      on(
        bin,
        1,
        "turn/start",
        as_turn(turn(tid(), message(tid(), "m", "Hi.") ++ [usage_note(@call2)]), "turn2") ++
          [hd(as_turn([turn_end(tid(), "completed")], "turn2"))],
        "",
        2
      )

      session = start(ctx)
      assert [%{outcome: :error}] = of_type(prompt(session, "one"), :turn_end)
      events = prompt(session, "two")

      assert [%Message{role: :user}, %Message{role: :assistant, usage: usage}] = messages(events)
      assert usage.input == 24_439 - 11_648 + 27_907 - 24_320
      assert %Helyx.Usage{context_tokens: 27_912, context_window: 475_000, cost: nil} = usage
    end
  end
end
