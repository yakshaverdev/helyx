defmodule Helyx.Hook.CommandTest do
  # The runs of `Helyx.Hook.Command` with a config that the test passes,
  # in fake hands (docs/features/command-hook.md).
  use ExUnit.Case, async: true

  alias Helyx.Hook.Command
  alias Helyx.Hook.Command.{Error, Run}

  @moduletag :tmp_dir

  @max Run.max_output_bytes()

  setup %{tmp_dir: dir} do
    Helyx.Test.Hands.fake(self())

    input = %{
      tool: "bash",
      arguments: %{"command" => "ls é"},
      cwd: dir,
      session_id: "s1",
      turn_id: "t1",
      call_id: "c1",
      provider: nil
    }

    %{input: input, after: Map.put(input, :result, {:ok, "out"})}
  end

  defp env(point, command, opts \\ []), do: [{point, [command: command] ++ opts}]

  defp before(input, command, opts \\ []),
    do: Command.run(:before_tool, input, env(:before_tool, command, opts))

  defp after_tool(input, command, opts \\ []),
    do: Command.run(:after_tool, input, env(:after_tool, command, opts))

  defp failure(fun) do
    error = assert_raise Error, fun
    error.message
  end

  describe "no command" do
    test "no config and a point with no entry run nothing", %{input: input, after: after_input} do
      assert Command.run(:before_tool, input, nil) == :allow
      assert Command.run(:after_tool, after_input, nil) == :keep
      assert Command.run(:before_tool, input, env(:after_tool, "exit 1")) == :allow
      refute_received {:held, _}
    end

    test "a tool not in tools runs nothing", %{input: input, tmp_dir: dir} do
      assert before(input, "touch ran; exit 2", tools: ["read"]) == :allow
      refute File.exists?(Path.join(dir, "ran"))
      assert {:deny, _} = before(input, "touch ran; exit 2", tools: ["read", "bash"])
      assert File.exists?(Path.join(dir, "ran"))
    end
  end

  describe "the input" do
    test "before_tool gets the call in the Claude Code field names", %{input: input, tmp_dir: dir} do
      assert before(input, "cat > in.json") == :allow
      {:ok, json} = dir |> Path.join("in.json") |> File.read!() |> JSON.decode()

      assert json == %{
               "hook_event_name" => "PreToolUse",
               "session_id" => "s1",
               "turn_id" => "t1",
               "cwd" => dir,
               "tool_name" => "bash",
               "tool_input" => %{"command" => "ls é"},
               "tool_use_id" => "c1",
               "provider" => nil
             }
    end

    test "after_tool gets the result cut as the hands cut it", %{after: input, tmp_dir: dir} do
      text = String.duplicate("é", 40_000) <> <<0xFF>>
      input = %{input | result: {:error, text}}
      assert after_tool(input, "cat > in.json") == :keep
      {:ok, json} = dir |> Path.join("in.json") |> File.read!() |> JSON.decode()
      assert json["hook_event_name"] == "PostToolUse"

      assert json["tool_response"] == %{
               "status" => "error",
               "text" => Helyx.Message.cut_result(text)
             }
    end

    test "the command runs in the call's folder, and its group is held", %{input: input} do
      assert {:allow, reason} =
               before(input, ~S|printf '{"decision":"approve","reason":"%s"}' "$(pwd)"|)

      assert reason == input.cwd
      assert_received {:held, {:watchdog, _}}
      assert_received {:held, {:command, _}}
    end
  end

  describe "exit codes" do
    test "exit 0 with no output or plain text is the default", %{input: input, after: after_input} do
      assert before(input, "exit 0") == :allow
      assert before(input, "echo checked; echo noise >&2") == :allow
      assert after_tool(after_input, "echo '  [1]'") == :keep
    end

    test "exit 2 denies with standard error, and only it", %{input: input} do
      assert before(input, "echo out; echo no >&2; exit 2") == {:deny, "no\n"}
      assert before(input, "exit 2") == {:deny, "the command exited with status 2"}
      assert before(input, "echo ' ' >&2; exit 2") == {:deny, "the command exited with status 2"}
    end

    test "exit 2 at after_tool adds standard error to the result", %{after: input} do
      assert after_tool(%{input | result: {:error, "out"}}, "echo fix it >&2; exit 2") ==
               {:replace, {:error, "out\n\nThe hook Helyx.Hook.Command added: fix it\n"}}
    end

    test "another exit, a signal, and a start that failed are failures", %{input: input} do
      assert failure(fn -> before(input, "echo boom >&2; exit 1") end) ==
               "the command exited with status 1: boom"

      assert failure(fn -> before(input, "exit 3") end) == "the command exited with status 3"

      assert failure(fn -> before(input, "kill -9 $$") end) ==
               "the command exited with status 137"

      gone = %{input | cwd: Path.join(input.cwd, "gone")}
      assert failure(fn -> before(gone, "exit 0") end) =~ "the command did not start: "
    end

    test "invalid bytes of standard error become valid text", %{input: input} do
      assert before(input, ~S|printf 'a\377b' >&2; exit 2|) == {:deny, "a�b"}
    end

    test "a child that keeps the pipes open does not hold the hook", %{input: input} do
      assert before(input, "sleep 30 & exit 2") == {:deny, "the command exited with status 2"}
      assert_received {:held, {:command, group}}

      try do
        # The child still runs: the hook did not wait for it.
        assert {_, 0} = System.cmd("kill", ["-0", "--", "-#{group}"], stderr_to_stdout: true)
      after
        deadline = System.monotonic_time(:millisecond) + 5_000
        assert Command.release([{:command, group}], :deliver, deadline) == []
      end
    end
  end

  describe "the output bound" do
    # A JSON answer with `reason`, padded in front with spaces to `size` bytes.
    defp padded(size, reason) do
      json = ~s|{"decision":"block","reason":"#{reason}"}|
      "head -c #{size - byte_size(json)} /dev/zero | tr '\\0' ' '; printf '%s' '#{json}'"
    end

    defp bytes(size, char), do: "head -c #{size} /dev/zero | tr '\\0' #{char}"

    test "standard output at the bound is read, one byte over fails", %{input: input} do
      assert before(input, padded(@max - 1, "r")) == {:deny, "r"}
      assert before(input, padded(@max, "r")) == {:deny, "r"}
      assert before(input, padded(@max, "é")) == {:deny, "é"}

      for reason <- ["r", "é"] do
        assert failure(fn -> before(input, padded(@max + 1, reason)) end) ==
                 "its standard output was over #{@max} bytes"
      end
    end

    test "plain text over the bound is the default, white space over it fails", %{input: input} do
      assert before(input, bytes(@max + 1, "a")) == :allow
      assert before(input, bytes(@max, "' '")) == :allow

      assert failure(fn -> before(input, bytes(@max + 1, "' '")) end) ==
               "its standard output was over #{@max} bytes"
    end

    test "standard error keeps its head at the bound", %{input: input} do
      for size <- [@max - 1, @max] do
        assert before(input, bytes(size, "a") <> " >&2; exit 2") ==
                 {:deny, String.duplicate("a", size)}
      end

      for size <- [@max + 1, @max + 100_000] do
        assert before(input, bytes(size, "a") <> " >&2; exit 2") ==
                 {:deny, String.duplicate("a", @max)}
      end
    end

    test "a character that the bound splits becomes U+FFFD", %{input: input} do
      # `é` is two bytes: one at the bound and one over it.
      command = bytes(@max - 1, "a") <> " >&2; printf 'éb' >&2; exit 2"
      assert before(input, command) == {:deny, String.duplicate("a", @max - 1) <> "\uFFFD"}
    end
  end

  describe "the config" do
    # The other point of `point`, its input, and its answer to a command that
    # writes `ran` to standard error and exits 2.
    defp other_point(:before_tool, _input, after_input),
      do:
        {:after_tool, after_input,
         {:replace, {:ok, "out\n\nThe hook Helyx.Hook.Command added: ran\n"}}}

    defp other_point(:after_tool, input, _after_input),
      do: {:before_tool, input, {:deny, "ran\n"}}

    for {env, path} <- [
          {:bad, [:command_hook]},
          {[before_compact: [command: "x"]], [:command_hook]},
          {[{nil, [command: "x"]}], [:command_hook]},
          {[before_tool: [{false, 1}, command: "x"]], [:command_hook, :before_tool]},
          {[before_tool: [command: "x"], before_tool: [command: "y"]], [:command_hook]},
          {[before_tool: [command: "x", matcher: "bash"]], [:command_hook, :before_tool]},
          {[before_tool: "x"], [:command_hook, :before_tool]},
          {[before_tool: []], [:command_hook, :before_tool, :command]},
          {[before_tool: [command: ""]], [:command_hook, :before_tool, :command]},
          {[before_tool: [command: "a\0b"]], [:command_hook, :before_tool, :command]},
          {[before_tool: [command: <<0xFF>>]], [:command_hook, :before_tool, :command]},
          {[before_tool: [command: "x", limit_ms: 0]], [:command_hook, :before_tool, :limit_ms]},
          {[before_tool: [command: "x", limit_ms: 600_001]],
           [:command_hook, :before_tool, :limit_ms]},
          {[before_tool: [command: "x", tools: "bash"]], [:command_hook, :before_tool, :tools]},
          {[before_tool: [command: "x", tools: [:bash]]], [:command_hook, :before_tool, :tools]},
          {[after_tool: [command: "x", tools: ["a" | "b"]]],
           [:command_hook, :after_tool, :tools]},
          {[before_tool: nil], [:command_hook, :before_tool]},
          {[after_tool: nil], [:command_hook, :after_tool]},
          {[before_tool: [command: nil]], [:command_hook, :before_tool, :command]},
          {[before_tool: [command: "x", limit_ms: nil]],
           [:command_hook, :before_tool, :limit_ms]},
          {[after_tool: [command: "x", tools: nil]], [:command_hook, :after_tool, :tools]}
        ] do
      test "#{inspect(env)} fails at its point", %{input: input, after: after_input} do
        path = unquote(path)
        why = "its config :command_hook is invalid: #{inspect(path)}"
        env = unquote(Macro.escape(env))

        for {point, input, default} <- [
              {:before_tool, input, :allow},
              {:after_tool, after_input, :keep}
            ] do
          if path == [:command_hook] or Enum.at(path, 1) == point,
            do: assert(failure(fn -> Command.run(point, input, env) end) == why),
            else: assert(Command.run(point, input, env) == default)
        end
      end

      # A bad entry fails its point only: a valid entry of the other point
      # runs its command.
      if match?([_, _ | _], path) do
        test "#{inspect(env)} beside a valid entry of the other point runs it",
             %{input: input, after: after_input} do
          env = unquote(Macro.escape(env))
          {point, input, ran} = other_point(unquote(Enum.at(path, 1)), input, after_input)
          env = env ++ [{point, [command: "echo ran >&2; exit 2"]}]
          assert Command.run(point, input, env) == ran
        end
      end
    end

    test "the limits at the bound pass", %{input: input} do
      for ms <- [1, 600_000] do
        env = [before_tool: [command: "exit 2", limit_ms: ms]]
        assert {:deny, _} = Command.run(:before_tool, input, env)
      end
    end
  end
end
