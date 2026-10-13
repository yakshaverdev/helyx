defmodule Helyx.UsageTest do
  use ExUnit.Case, async: true

  alias Helyx.Message
  alias Helyx.Session.File.Codec
  alias Helyx.Session.Stream, as: SessionStream
  alias Helyx.Usage

  @max_tokens 10 ** 15
  @max_cost 10 ** 12

  # The usage passes the check of a stream event and comes back unchanged
  # from a round trip of the session file.
  defp passes_check!(usage) do
    done = %{stop_reason: :end_turn, usage: usage}
    assert {:terminal, {:done, ^done}} = SessionStream.check({:done, done})

    message = %Message{role: :assistant, content: [], usage: usage}
    entry = message |> Codec.encode() |> JSON.encode!() |> JSON.decode!()
    assert Codec.decode(entry).usage == usage
    usage
  end

  test "the token fields add up and the context fields come from the later usage" do
    a = %Usage{input: 1, output: 2, cache_read: 3, cache_write: 4, context_tokens: 9}
    b = %Usage{input: 10, output: 20, cache_read: 30, cache_write: 40, context_window: 100}

    assert passes_check!(Usage.add(a, b)) ==
             %Usage{input: 11, output: 22, cache_read: 33, cache_write: 44, context_window: 100}
  end

  test "the kinds: :list when either is :list, else :billed" do
    list = %Usage{cost: 1, cost_kind: :list}
    billed = %Usage{cost: 0.5, cost_kind: :billed}

    assert %Usage{cost: 1.5, cost_kind: :list} = passes_check!(Usage.add(list, billed))
    assert %Usage{cost: 1.5, cost_kind: :list} = passes_check!(Usage.add(billed, list))
    assert %Usage{cost: 1.0, cost_kind: :billed} = passes_check!(Usage.add(billed, billed))
  end

  test "a known :list cost and an unknown cost give an unknown cost, in both orders" do
    known = %Usage{input: 5, cost: 2.5, cost_kind: :list}
    unknown = %Usage{input: 7}

    for {a, b} <- [{known, unknown}, {unknown, known}] do
      assert %Usage{input: 12, cost: nil, cost_kind: nil} = passes_check!(Usage.add(a, b))
    end
  end

  test "a token sum saturates at 10^15; over it the cost is unknown" do
    cost = %Usage{cost: 1, cost_kind: :list}

    at = Usage.add(%{cost | output: @max_tokens - 1}, %{cost | output: 1})
    assert %Usage{output: @max_tokens, cost: 2, cost_kind: :list} = passes_check!(at)

    over = Usage.add(%{cost | output: @max_tokens}, %{cost | output: 1})
    assert %Usage{output: @max_tokens, cost: nil, cost_kind: nil} = passes_check!(over)
  end

  test "a cost sum over 10^12 is unknown, with no ArithmeticError" do
    max = %Usage{cost: @max_cost, cost_kind: :list}
    assert %Usage{cost: nil, cost_kind: nil} = passes_check!(Usage.add(max, max))

    half = %Usage{cost: @max_cost / 2, cost_kind: :billed}
    assert %Usage{cost: 1.0e12, cost_kind: :billed} = passes_check!(Usage.add(half, half))
  end

  describe "valid?/1, the struct bound" do
    test "each token field and context_tokens: 0 to 10^15" do
      for field <- [:input, :output, :cache_read, :cache_write, :context_tokens] do
        assert Usage.valid?(struct(Usage, [{field, 0}]))
        assert Usage.valid?(struct(Usage, [{field, @max_tokens - 1}]))
        assert Usage.valid?(struct(Usage, [{field, @max_tokens}]))
        refute Usage.valid?(struct(Usage, [{field, @max_tokens + 1}]))
        refute Usage.valid?(struct(Usage, [{field, -1}]))
        refute Usage.valid?(struct(Usage, [{field, 1.0}]))
      end

      refute Usage.valid?(%Usage{input: nil})
    end

    test "a cost: 0 to 10^12, with a kind exactly when it is known" do
      assert Usage.valid?(%Usage{cost: @max_cost, cost_kind: :list})
      assert Usage.valid?(%Usage{cost: @max_cost - 0.01, cost_kind: :billed})
      assert Usage.valid?(%Usage{cost: 0, cost_kind: :list})
      refute Usage.valid?(%Usage{cost: @max_cost + 0.01, cost_kind: :list})
      refute Usage.valid?(%Usage{cost: -0.01, cost_kind: :list})
      refute Usage.valid?(%Usage{cost: 1, cost_kind: nil})
      refute Usage.valid?(%Usage{cost: nil, cost_kind: :list})
      refute Usage.valid?(%Usage{cost: 1, cost_kind: :other})
      refute Usage.valid?(%Usage{cost: "1", cost_kind: :list})
    end

    test "a window: 1 to 10^9" do
      assert Usage.valid?(%Usage{context_window: 1})
      assert Usage.valid?(%Usage{context_window: 10 ** 9})
      refute Usage.valid?(%Usage{context_window: 0})
      refute Usage.valid?(%Usage{context_window: 10 ** 9 + 1})
    end

    test "a map or a struct with another key set is not a usage" do
      refute Usage.valid?(%{input: 1})
      refute Usage.valid?(Map.put(%Usage{}, :extra, 1))
      refute Usage.valid?(Map.delete(%Usage{}, :cost))
      refute Usage.valid?(nil)
    end
  end
end
