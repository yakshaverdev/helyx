defmodule Helyx.HarnessIO.StreamTest do
  use ExUnit.Case, async: true

  alias Helyx.HarnessIO.Stream
  alias Helyx.Provider.ClaudeCode.State, as: ClaudeState
  alias Helyx.Provider.Codex.State, as: CodexState

  # The shape that `Helyx.HarnessIO` reads and writes. Both provider states
  # embed it, so a rename is a compile error at the call site and a failure
  # here.
  @fields [:port, :buffer, :size, :terminal, :closing, :handles, :env]

  test "both provider states embed the same stream" do
    for state <- [
          %CodexState{exe: "codex", model: "m", cwd: "."},
          %ClaudeState{exe: "claude", model: "m", cwd: "."}
        ] do
      assert %Stream{} = state.stream
    end

    assert Stream.__struct__() |> Map.from_struct() |> Map.keys() |> Enum.sort() ==
             Enum.sort(@fields)
  end

  test "the inspect of the stream leaves the env out" do
    stream = %Stream{env: [{"HELYX_TEST_PRIVATE", "value"}]}
    refute inspect(stream) =~ "HELYX_TEST_PRIVATE"
  end
end
