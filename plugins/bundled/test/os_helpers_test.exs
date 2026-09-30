defmodule Helyx.Test.OSHelpersTest do
  # procps-ng kill(1) reads a "-<group>" with no "--" before it as options:
  # `kill -STOP -122` sent SIGSTOP to -1, every process of the user, during
  # a precommit run. These tests send no signal.
  use ExUnit.Case, async: true

  import Helyx.Test.OSHelpers

  test "a group below 2 is never signalled" do
    for group <- [1, 0, -1] do
      assert_raise FunctionClauseError, fn -> signal_group("STOP", group) end
    end
  end

  test "no kill(1) call gives a negative target without \"--\" before it" do
    files = Path.wildcard("{lib,test}/**/*.{ex,exs}")

    raw =
      for file <- files,
          {line, n} <- file |> File.read!() |> String.split("\n") |> Enum.with_index(1),
          String.contains?(line, ~s[System.cmd("kill"]),
          String.contains?(line, ~s["-\#{]),
          not String.contains?(line, ~s["--"]),
          do: "#{file}:#{n}"

    assert raw == []
  end
end
