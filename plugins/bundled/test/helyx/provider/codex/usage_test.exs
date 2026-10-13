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

  defp notify(items, last, window \\ 475_000) do
    {[], items} = Items.notification("thread/tokenUsage/updated", params(last, window), items)
    items
  end

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

  test "a turn with no done keeps the sum; a done starts a new one" do
    items = notify(%Items{}, @call1)
    kept = Items.next({:error, {:codex, "interrupted", ""}}, items)
    assert kept.usage == items.usage
    assert Items.next({:done, %{}}, items) == %Items{}
  end

  # The wire bound: a value at the bound is mapped, one over adds nothing.
  test "a count over 10^9, a window outside 1 to 10^9, or more cached than input add nothing" do
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
      assert notify(items, last, window) == items
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
