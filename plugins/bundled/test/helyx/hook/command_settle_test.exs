defmodule Helyx.Hook.CommandSettleTest do
  # `Helyx.Hook.Command` at `before_settle` (docs/features/command-hook.md),
  # with a config that the test passes, run in fake hands.
  use ExUnit.Case, async: true

  alias Helyx.Hook.Command
  alias Helyx.Hook.Command.Error

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    Helyx.Test.Hands.fake(self())
    %{input: %{session_id: "s1", turn_id: "t1", stop_reason: :end_turn, cwd: dir}}
  end

  defp settle(input, command),
    do: Command.run(:before_settle, input, before_settle: [command: command])

  defp failure(fun) do
    error = assert_raise Error, fun
    error.message
  end

  describe "the input" do
    test "is the ended turn in the field names of a Stop hook", %{input: input, tmp_dir: dir} do
      assert settle(input, "cat > in.json") == :settle
      {:ok, json} = dir |> Path.join("in.json") |> File.read!() |> JSON.decode()

      assert json == %{
               "hook_event_name" => "Stop",
               "session_id" => "s1",
               "turn_id" => "t1",
               "cwd" => dir,
               "stop_reason" => "end_turn"
             }
    end

    test "the command runs in the session's folder, and its group is held", %{input: input} do
      assert settle(input, "pwd >&2; exit 2") == {:continue, input.cwd <> "\n"}
      assert_received {:held, {:watchdog, _, _}}
      assert_received {:held, {:command, _, _}}
    end
  end

  describe "exit codes" do
    test "exit 0 with no output or plain text settles", %{input: input} do
      assert settle(input, "exit 0") == :settle
      assert settle(input, "echo checked; echo noise >&2") == :settle
    end

    test "exit 2 continues with standard error", %{input: input} do
      assert settle(input, "echo out; echo the tests fail >&2; exit 2") ==
               {:continue, "the tests fail\n"}

      assert settle(input, "exit 2") == {:continue, "the command exited with status 2"}
      assert settle(input, ~S|printf 'a\377b' >&2; exit 2|) == {:continue, "a�b"}
    end

    test "another exit is a failure", %{input: input} do
      assert failure(fn -> settle(input, "echo boom >&2; exit 1") end) ==
               "the command exited with status 1: boom"
    end
  end

  describe "JSON answers" do
    for {stdout, answer} <- [
          {~S|{"decision":"block","reason":"the tests fail"}|, {:continue, "the tests fail"}},
          {~S|{"decision":"block"}|, {:continue, "the command asked for one more turn"}},
          {~S|{"decision":"block","reason":""}|,
           {:continue, "the command asked for one more turn"}},
          {~S|{"continue":false,"decision":"block","reason":"r"}|, :settle},
          {~S|{"continue":false,"stopReason":"done"}|, :settle},
          {~S|{"continue":true}|, :settle},
          {~S|{"reason":"r"}|, :settle},
          {~S|{"hookSpecificOutput":{"permissionDecision":"deny"},"suppressOutput":true}|,
           :settle}
        ] do
      test "#{stdout}", %{input: input} do
        assert settle(input, "printf '%s' '#{unquote(stdout)}'") == unquote(answer)
      end
    end

    for {stdout, why} <- [
          {~S|{"decision":"approve"}|, "decision has another value"},
          {~S|{"decision":"block","reason":7}|, "reason is not a string"},
          {~S|{"continue":"no"}|, "continue is not a boolean"},
          {~S|{"hookSpecificOutput":[]}|, "hookSpecificOutput is not an object"}
        ] do
      test "#{stdout} fails", %{input: input} do
        assert failure(fn -> settle(input, "printf '%s' '#{unquote(stdout)}'") end) ==
                 "its standard output is not an answer: " <> unquote(why)
      end
    end
  end

  test "a byte-order mark before an object is dropped", %{input: input, tmp_dir: dir} do
    File.write!(Path.join(dir, "out"), "\uFEFF" <> ~S|{"decision":"block","reason":"x"}|)
    assert settle(input, "cat out") == {:continue, "x"}
  end

  test "a U+FEFF that the output cut splits before an object fails", %{input: input, tmp_dir: dir} do
    max = Helyx.Hook.Command.Run.max_output_bytes()
    json = ~S|{"decision":"block","reason":"x"}|
    File.write!(Path.join(dir, "out"), String.duplicate(" ", max - 2) <> "\uFEFF" <> json)

    assert failure(fn -> settle(input, "cat out") end) ==
             "its standard output was over #{max} bytes"
  end

  test "an object with a repeated key fails", %{input: input} do
    stdout = ~S|{"decision":"block","reason":"x","decision":"approve"}|

    assert failure(fn -> settle(input, "printf '%s' '#{stdout}'") end) ==
             "its standard output repeats a key in an object"
  end

  describe "the config" do
    test "no entry settles with no run", %{input: input} do
      assert Command.run(:before_settle, input, nil) == :settle
      assert Command.run(:before_settle, input, before_tool: [command: "exit 2"]) == :settle
      refute_received {:held, _}
    end

    for {env, path} <- [
          {[before_settle: nil], [:command_hook, :before_settle]},
          {[before_settle: [command: "x", tools: ["bash"]]], [:command_hook, :before_settle]},
          {[before_settle: [command: "x", limit_ms: 0]],
           [:command_hook, :before_settle, :limit_ms]},
          {[before_settle: []], [:command_hook, :before_settle, :command]}
        ] do
      test "#{inspect(env)} fails", %{input: input} do
        assert failure(fn -> Command.run(:before_settle, input, unquote(Macro.escape(env))) end) ==
                 "its config :command_hook is invalid: #{inspect(unquote(path))}"
      end
    end
  end
end
