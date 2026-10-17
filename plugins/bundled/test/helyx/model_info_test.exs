defmodule Helyx.ModelInfoTest do
  # `docs/features/usage-and-limits.md`, "`Helyx.ModelInfo`" and "Config".
  use ExUnit.Case, async: true

  alias Helyx.ModelInfo

  @ref "codex/m"
  @prices [input: 2.0, output: 10, cache_read: 0.5, cache_write: 4.0]

  defp lookup(entry, ref \\ @ref), do: ModelInfo.lookup("codex", "openai", "m", %{ref => entry})

  defp counts(fields), do: struct!(Helyx.Usage, fields)

  defp cost(fields, prices), do: ModelInfo.cost(counts(fields), Map.new(prices))

  describe "lookup/4" do
    test "config gives the window and the prices; with no entry there is nothing" do
      assert {:ok, %ModelInfo{context_window: 475_000, prices: prices}} =
               lookup(context_window: 475_000, prices: @prices)

      assert prices == Map.new(@prices)
      assert {:ok, %{context_window: nil, prices: nil}} = lookup([])

      assert {:ok, %{context_window: nil, prices: nil}} =
               ModelInfo.lookup("codex", "openai", "m", %{})

      assert {:ok, %{context_window: nil, prices: nil}} = ModelInfo.lookup("codex", "openai", "m")
    end

    test "the window from 1 to 10^9" do
      assert {:ok, %{context_window: 1}} = lookup(context_window: 1)
      assert {:ok, %{context_window: 1_000_000_000}} = lookup(context_window: 1_000_000_000)

      for bad <- [0, 1_000_000_001, 1.0, "1", nil] do
        assert lookup(context_window: bad) ==
                 {:error, {:bad_config, [:models, @ref, :context_window]}}
      end
    end

    test "each price a number from 0 to 10^6" do
      for key <- [:input, :output, :cache_read, :cache_write] do
        for good <- [0, 0.0, 1_000_000, 1_000_000.0] do
          assert {:ok, %{prices: %{^key => ^good}}} =
                   lookup(prices: Keyword.put(@prices, key, good))
        end

        for bad <- [-1, -0.01, 1_000_000.01, 1_000_001, "1", nil] do
          assert lookup(prices: Keyword.put(@prices, key, bad)) ==
                   {:error, {:bad_config, [:models, @ref, :prices, key]}}
        end
      end
    end

    test "prices need input and output; the cache prices are optional" do
      assert {:ok, %{prices: %{input: 1, output: 2}}} = lookup(prices: [input: 1, output: 2])

      for key <- [:input, :output] do
        assert lookup(prices: Keyword.delete(@prices, key)) ==
                 {:error, {:bad_config, [:models, @ref, :prices, key]}}
      end
    end

    test "tiers: at most 8, each a size from 1 to 10^9 and a whole price set" do
      tier = fn size -> {size, [input: 1, output: 2]} end
      tiers = for size <- 1..8, do: tier.(size * 1000)

      assert {:ok, %{prices: %{tiers: kept}}} = lookup(prices: @prices ++ [tiers: tiers])
      assert length(kept) == 8
      assert {:ok, _} = lookup(prices: @prices ++ [tiers: [tier.(1), tier.(1_000_000_000)]])

      for bad <- [
            tiers ++ [tier.(9000)],
            [tier.(0)],
            [tier.(1_000_000_001)],
            [{1000, [input: 1]}],
            [{1000, [input: 1, output: 2, tiers: []]}],
            [{1000, [input: -1, output: 2]}],
            [:tier],
            %{}
          ] do
        assert lookup(prices: @prices ++ [tiers: bad]) ==
                 {:error, {:bad_config, [:models, @ref, :prices, :tiers]}}
      end
    end

    test "an unknown key, or a value that is not a keyword list, names its place" do
      assert lookup(max_output: 1) == {:error, {:bad_config, [:models, @ref, :max_output]}}

      assert lookup(prices: @prices ++ [extra: 1]) ==
               {:error, {:bad_config, [:models, @ref, :prices, :extra]}}

      assert lookup(prices: %{input: 1, output: 2}) ==
               {:error, {:bad_config, [:models, @ref, :prices]}}

      assert lookup(%{context_window: 1}) == {:error, {:bad_config, [:models, @ref]}}
      assert ModelInfo.lookup("codex", "openai", "m", [:x]) == {:error, {:bad_config, [:models]}}
    end

    test "an entry of another ref is not checked" do
      assert {:ok, %{context_window: nil}} = lookup([context_window: 0], "codex/other")
    end
  end

  describe "cost/2" do
    test "each count times its price, per million tokens" do
      assert {cost, :list} = cost([input: 1_000_000], @prices)
      assert_in_delta cost, 2.0, 1.0e-9
      assert {cost, :list} = cost([output: 1_000_000], @prices)
      assert_in_delta cost, 10.0, 1.0e-9
      assert {cost, :list} = cost([cache_read: 1_000_000], @prices)
      assert_in_delta cost, 0.5, 1.0e-9
      assert {cost, :list} = cost([cache_write: 1_000_000], @prices)
      assert_in_delta cost, 4.0, 1.0e-9

      assert {cost, :list} =
               cost([input: 1000, output: 100, cache_read: 2000, cache_write: 10], @prices)

      assert_in_delta cost, (2000 + 1000 + 1000 + 40) / 1_000_000, 1.0e-12
    end

    test "a count above 0 with no price gives nil; a count of 0 needs no price" do
      prices = [input: 2.0, output: 10.0]
      assert cost([cache_read: 1], prices) == nil
      assert cost([cache_write: 1], prices) == nil
      assert {cost, :list} = cost([input: 1], prices)
      assert_in_delta cost, 2.0e-6, 1.0e-15
      assert ModelInfo.cost(counts(input: 1), nil) == nil
    end

    test "a tier applies when the prompt is over its size; the largest such size wins" do
      tiers = [tiers: [{200, %{input: 3.0, output: 20.0}}, {100, %{input: 5.0, output: 7.0}}]]

      # The prompt is input + cache_read + cache_write; output is not in it.
      # The order of the tiers does not matter.
      for tiers <- [tiers, [tiers: Enum.reverse(tiers[:tiers])]],
          {prompt, input, output} <- [
            {99, 2.0, 10.0},
            {100, 2.0, 10.0},
            {101, 5.0, 7.0},
            {200, 5.0, 7.0},
            {201, 3.0, 20.0}
          ] do
        assert {cost, :list} = cost([input: prompt, output: 1_000_000], @prices ++ tiers)
        assert_in_delta cost, prompt * input / 1_000_000 + output, 1.0e-9
      end

      assert {cost, :list} = cost([cache_read: 60, cache_write: 40], @prices ++ tiers)
      assert_in_delta cost, (60 * 0.5 + 40 * 4.0) / 1_000_000, 1.0e-12
    end

    test "a tier's price set is whole: a price it lacks is not taken from the base set" do
      prices = @prices ++ [tiers: [{10, %{input: 3.0, output: 20.0}}]]
      assert {_cost, :list} = cost([input: 1, cache_read: 9], prices)
      assert cost([input: 1, cache_read: 10], prices) == nil
    end
  end
end
