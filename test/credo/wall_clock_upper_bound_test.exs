# The check is no part of the compiled project: Credo loads it from .credo.exs.
Code.require_file("../../credo/wall_clock_upper_bound.ex", __DIR__)

defmodule Helyx.Credo.WallClockUpperBoundTest do
  use Credo.Test.Case

  alias Helyx.Credo.WallClockUpperBound

  # In `mix precommit`, `mix credo` has started the services of Credo in
  # this VM before the tests.
  setup_all do
    case Credo.Application.start(:normal, []) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
  end

  defp issues(body) do
    """
    defmodule SampleTest do
      #{body}
    end
    """
    |> to_source_file()
    |> run_check(WallClockUpperBound)
  end

  test "an upper bound on a monotonic time difference is an issue" do
    issues("""
    test "t" do
      start = System.monotonic_time(:millisecond)
      assert System.monotonic_time(:millisecond) - start < 340
    end
    """)
    |> assert_issue(fn issue -> assert issue.trigger == "<" end)
  end

  test "a bound that names its load margin is no issue" do
    issues("""
    @load_ms 250
    test "t" do
      start = System.monotonic_time(:millisecond)
      assert System.monotonic_time(:millisecond) - start < 300 + @load_ms
    end
    """)
    |> refute_issues()
  end

  test "a lower bound is no issue, in either order" do
    issues("""
    test "t" do
      {elapsed, :ok} = :timer.tc(fn -> :ok end, :millisecond)
      assert elapsed >= 2_000
      assert 2_000 <= elapsed
      refute elapsed < 2_000
    end
    """)
    |> refute_issues()
  end

  test "every form of an upper bound is an issue" do
    issues("""
    test "t" do
      {elapsed, :ok} = :timer.tc(fn -> :ok end, :millisecond)
      assert elapsed <= 3_000
      assert 3_000 > elapsed
      refute elapsed > 3_000
      assert elapsed in 2_000..3_000
      assert elapsed >= 2_000 and elapsed < 3_000
      assert elapsed < @slow_ms
      assert not (elapsed >= 3_000)
      refute not (elapsed < 3_000)
      assert elapsed < @loaded_ms
      assert_in_delta elapsed, 2_500, 500
      assert_in_delta 2_500, elapsed, 500
      assert Kernel.<(elapsed, 3_000)
    end
    """)
    |> assert_issues(fn issues -> assert length(issues) == 12 end)
  end

  test "a lower bound under a not, and a delta with a margin, are no issue" do
    issues("""
    test "t" do
      {elapsed, :ok} = :timer.tc(fn -> :ok end, :millisecond)
      assert not (elapsed < 2_000)
      assert_in_delta elapsed, 2_500, @load_ms
    end
    """)
    |> refute_issues()
  end

  test "an equality is a bound, with the time value on either side" do
    issues("""
    test "t" do
      {elapsed, :ok} = :timer.tc(fn -> :ok end, :millisecond)
      assert elapsed == 100
      assert 100 === elapsed
      refute elapsed != 100
      refute 100 !== elapsed
      assert not (elapsed != 100)
      refute not (elapsed == 100)
    end
    """)
    |> assert_issues(fn issues -> assert length(issues) == 6 end)
  end

  test "an inequality, a refuted equality, and an equality with a margin are no issue" do
    issues("""
    test "t" do
      {elapsed, :ok} = :timer.tc(fn -> :ok end, :millisecond)
      assert elapsed != 100
      refute elapsed == 100
      assert not (elapsed == 100)
      refute not (elapsed != 100)
      assert elapsed == @load_ms
      assert length([elapsed]) == 1
    end
    """)
    |> refute_issues()
  end

  test "a deadline made from a time value is a bound" do
    issues("""
    test "t" do
      start = System.monotonic_time(:millisecond)
      deadline = start + 300
      assert System.monotonic_time(:millisecond) < deadline
      assert System.monotonic_time(:millisecond) < start + 300
    end
    """)
    |> assert_issues(fn issues -> assert length(issues) == 2 end)
  end

  test "the result of :timer.tc is no time" do
    issues("""
    test "t" do
      {_elapsed, count} = :timer.tc(fn -> 1 end)
      assert count < 2

      with {_elapsed, n} <- :timer.tc(fn -> 1 end) do
        assert n < 2
      end
    end
    """)
    |> refute_issues()
  end

  test "the time flows through variables and local functions" do
    issues("""
    defp timed(fun) do
      start = System.monotonic_time(:millisecond)
      {fun.(), System.monotonic_time(:millisecond) - start}
    end

    test "t" do
      timed = for fun <- [], do: timed(fun)
      total = Enum.sum(for {_result, ms} <- timed, do: ms)
      assert total < 400
    end
    """)
    |> assert_issue()
  end

  test "a variable of the same name in another test is no time" do
    issues("""
    test "a" do
      start = System.monotonic_time(:millisecond)
      assert start > 0
    end

    test "b" do
      start = 1
      assert start < 2
    end
    """)
    |> refute_issues()
  end
end
