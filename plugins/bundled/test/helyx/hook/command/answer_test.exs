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
          {~S|{"decision":"block","reason":7}|, "reason is not a string"}
        ] do
      test "#{stdout} fails", %{input: input} do
        assert failure(fn -> before(input, "printf '%s' '#{unquote(stdout)}'") end) ==
                 "its standard output is not an answer: " <> unquote(why)
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
