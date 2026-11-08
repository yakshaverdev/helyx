defmodule Helyx.Hook.Command.AnswerTest do
  # The JSON answers on standard output of `Helyx.Hook.Command`
  # (docs/features/command-hook.md), run in fake hands.
  use ExUnit.Case, async: true

  alias Helyx.Hook.Command
  alias Helyx.Hook.Command.Error

  @moduletag :tmp_dir

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

  defp env(point, command), do: [{point, [command: command]}]

  defp before(input, command), do: Command.run(:before_tool, input, env(:before_tool, command))

  defp after_tool(input, command), do: Command.run(:after_tool, input, env(:after_tool, command))

  defp failure(fun) do
    error = assert_raise Error, fun
    error.message
  end

  describe "JSON answers at before_tool" do
    for {stdout, answer} <- [
          {~S|{"hookSpecificOutput":{"permissionDecision":"deny","permissionDecisionReason":"no"}}|,
           {:deny, "no"}},
          {~S|{"hookSpecificOutput":{"permissionDecision":"deny"}}|,
           {:deny, "the command denied the call"}},
          {~S|{"hookSpecificOutput":{"permissionDecision":"allow","permissionDecisionReason":"ok"}}|,
           {:allow, "ok"}},
          {~S|{"hookSpecificOutput":{"permissionDecision":"allow","permissionDecisionReason":""}}|,
           :allow},
          {~S|{"decision":"block","reason":"old"}|, {:deny, "old"}},
          {~S|{"decision":"approve","reason":"fine"}|, {:allow, "fine"}},
          {~S|{"decision":"approve","hookSpecificOutput":{"permissionDecision":"deny"}}|,
           {:deny, "the command denied the call"}},
          {~S|{"decision":"block","hookSpecificOutput":{"permissionDecision":"allow"}}|,
           {:deny, "the command denied the call"}},
          {~S|{"decision":"block","reason":"r","hookSpecificOutput":{"permissionDecision":"deny"}}|,
           {:deny, "r"}},
          {~S|{"decision":"block","reason":"r","hookSpecificOutput":{"permissionDecision":"deny","permissionDecisionReason":"p"}}|,
           {:deny, "p"}},
          {~S|{"decision":"approve","reason":"fine","hookSpecificOutput":{"permissionDecision":"deny"}}|,
           {:deny, "the command denied the call"}},
          {~S|{"continue":true,"systemMessage":"x","decision":null}|, :allow},
          {~S|  {"suppressOutput":true}|, :allow}
        ] do
      test "#{stdout}", %{input: input} do
        assert before(input, "printf '%s' '#{unquote(stdout)}'") == unquote(answer)
      end
    end

    for {stdout, why} <- [
          {~S|{"hookSpecificOutput":{"permissionDecision":"ask"}}|,
           "permissionDecision has another value"},
          {~S|{"hookSpecificOutput":{"permissionDecision":"defer"}}|,
           "permissionDecision has another value"},
          {~S|{"hookSpecificOutput":{"updatedInput":{"command":"ls"}}}|,
           "updatedInput asks for what a Helyx hook does not do"},
          {~S|{"continue":false}|, "continue false asks to stop the agent, which a hook cannot"},
          {~S|{"continue":"no"}|, "continue is not a boolean"},
          {~S|{"hookSpecificOutput":[]}|, "hookSpecificOutput is not an object"},
          {~S|{"decision":"block","reason":7}|, "reason is not a string"},
          {~S|{"decision":"allow"}|, "decision has another value"},
          {~S|{"hookSpecificOutput":{"permissionDecision":"deny","permissionDecisionReason":[]}}|,
           "permissionDecisionReason is not a string"}
        ] do
      test "#{stdout} fails", %{input: input} do
        assert failure(fn -> before(input, "printf '%s' '#{unquote(stdout)}'") end) ==
                 "its standard output is not an answer: " <> unquote(why)
      end
    end

    # What JavaScript's `trim()` drops before the `{`, as Claude Code reads
    # its hook output: the byte-order mark, form feed, vertical tab, a
    # no-break space, the line separator. NUL is not dropped: plain text.
    test "white space of JavaScript's trim() around an object is dropped", %{input: input} do
      json = ~S|{"decision":"block","reason":"no"}|

      for space <- ["\uFEFF", "\f", "\v", "\u00A0", "\u2028", " \n"] do
        File.write!(Path.join(input.cwd, "out"), space <> json <> space)
        assert before(input, "cat out") == {:deny, "no"}
      end

      File.write!(Path.join(input.cwd, "out"), <<0>> <> json)
      assert before(input, "cat out") == :allow
    end

    test "an object with a repeated key fails, whichever value it repeats", %{input: input} do
      for stdout <- [
            ~S|{"decision":"approve","decision":"block","reason":"no"}|,
            ~S|{"hookSpecificOutput":{"permissionDecision":"deny","permissionDecision":"allow"}}|
          ] do
        assert failure(fn -> before(input, "printf '%s' '#{stdout}'") end) ==
                 "its standard output repeats a key in an object"
      end
    end

    test "an object that does not decode fails", %{input: input} do
      assert failure(fn -> before(input, "echo '{\"a\":'") end) ==
               "its standard output is not a JSON object"
    end
  end

  describe "JSON answers at after_tool" do
    test "a block reason and a context are added, the reason first", %{after: input} do
      stdout =
        ~S|{"decision":"block","reason":"r","hookSpecificOutput":{"additionalContext":"c"}}|

      assert after_tool(input, "printf '%s' '#{stdout}'") ==
               {:replace,
                {:ok,
                 "out\n\nThe hook Helyx.Hook.Command added: r" <>
                   "\n\nThe hook Helyx.Hook.Command added: c"}}
    end

    test "a reason with no block, and a block with no reason, keep", %{after: input} do
      assert after_tool(input, ~S|echo '{"reason":"r"}'|) == :keep
      assert after_tool(input, ~S|echo '{"decision":"block"}'|) == :keep
    end

    for {stdout, why} <- [
          {~S|{"decision":"block","reason":7}|, "reason is not a string"},
          {~S|{"hookSpecificOutput":{"additionalContext":{}}}|,
           "additionalContext is not a string"},
          {~S|{"hookSpecificOutput":"x"}|, "hookSpecificOutput is not an object"},
          {~S|{"continue":false,"decision":"block","reason":"r"}|,
           "continue false asks to stop the agent, which a hook cannot"},
          {~S|{"continue":0}|, "continue is not a boolean"}
        ] do
      test "#{stdout} fails", %{after: input} do
        assert failure(fn -> after_tool(input, "printf '%s' '#{unquote(stdout)}'") end) ==
                 "its standard output is not an answer: " <> unquote(why)
      end
    end

    test "fields of before_tool are ignored", %{after: input} do
      stdout = ~S|{"hookSpecificOutput":{"permissionDecision":"deny","updatedInput":{}}}|
      assert after_tool(input, "printf '%s' '#{stdout}'") == :keep
    end

    test "an output replace and another decision fail", %{after: input} do
      assert failure(fn ->
               after_tool(input, ~S|echo '{"hookSpecificOutput":{"updatedMCPToolOutput":"x"}}'|)
             end) =~ "updatedMCPToolOutput"

      assert failure(fn -> after_tool(input, ~S|echo '{"decision":"approve"}'|) end) =~
               "decision has another value"
    end

    test "invalid bytes of the result become valid before the addition", %{after: input} do
      input = %{input | result: {:ok, <<"a", 0xFF>>}}

      assert after_tool(input, "echo x >&2; exit 2") ==
               {:replace, {:ok, "a�\n\nThe hook Helyx.Hook.Command added: x\n"}}
    end
  end
end
