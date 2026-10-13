defmodule Helyx.Provider.HarnessConfigTest do
  # The config of `docs/features/usage-and-limits.md`, "Config", in the
  # harness providers. Not async: the tests set the `:models` app env.
  use ExUnit.Case, async: false

  import Helyx.Test.CodexFake
  import Helyx.Test.Events

  alias Helyx.Message
  alias Helyx.Provider.{ClaudeCode, Codex}

  @moduletag :tmp_dir

  defp models(config) do
    Application.put_env(:helyx_plugins, :models, config)
    on_exit(fn -> Application.delete_env(:helyx_plugins, :models) end)
  end

  test "a bad entry fails the start of the session with its key", %{tmp_dir: tmp} do
    models(%{"codex/m" => [context_window: 0], "claude-code/m" => [prices: [input: 1]]})

    assert Codex.init("m", [], cwd: tmp) ==
             {:error, {:bad_config, [:models, "codex/m", :context_window]}}

    assert ClaudeCode.init("m", [], cwd: tmp) ==
             {:error, {:bad_config, [:models, "claude-code/m", :prices, :output]}}
  end

  describe "a Codex session" do
    setup {Helyx.Test.CodexFake, :setup_fake}

    # The fake's notification has no `modelContextWindow`: 12 input and 7
    # output tokens.
    test "with config, the usage of the message has the window and the cost, kind :list",
         %{bin: bin} = ctx do
      prices = [input: 2.0, output: 10.0]
      models(%{"codex/gpt-6-luna" => [context_window: 475_000, prices: prices]})
      fresh(bin, 1, tid(), reply(tid(), "Hi."))

      [%Message{role: :user}, %Message{role: :assistant, usage: usage}] =
        messages(prompt(start(ctx), "go"))

      assert %Helyx.Usage{input: 12, output: 7, context_window: 475_000, cost_kind: :list} =
               usage

      assert_in_delta usage.cost, (12 * 2.0 + 7 * 10.0) / 1_000_000, 1.0e-12
    end

    # Each notification has a map `params` with a string thread id
    # (research note). A usage line of any other shape is a call in no sum.
    test "a usage line with no readable thread id makes the cost nil", %{bin: bin} = ctx do
      models(%{"codex/gpt-6-luna" => [prices: [input: 2.0, output: 10.0]]})
      usage = %{turnId: "turn1", tokenUsage: %{last: %{inputTokens: 1000, outputTokens: 5}}}
      method = "thread/tokenUsage/updated"

      lines = [
        %{method: method, params: usage},
        %{method: method, params: Map.put(usage, :threadId, nil)},
        %{method: method, params: Map.put(usage, :threadId, 42)},
        %{method: method, params: Map.put(usage, :threadId, "")},
        %{method: method},
        %{method: method, params: nil},
        %{method: method, params: [usage]}
      ]

      for {line, n} <- Enum.with_index(lines, 1) do
        fresh(bin, n, tid(), [j(line) | reply(tid(), "Hi.")])

        [_user, %Message{role: :assistant, usage: usage}] = messages(prompt(start(ctx), "go"))
        assert %Helyx.Usage{input: 12, output: 7, cost: nil, cost_kind: nil} = usage
      end
    end

    # Each usage notification has the running turn's id (research note).
    test "a usage notification with no running turn id makes the cost nil",
         %{bin: bin} = ctx do
      models(%{"codex/gpt-6-luna" => [prices: [input: 2.0, output: 10.0]]})
      last = %{inputTokens: 1000, outputTokens: 5}

      for {turn_id, n} <- Enum.with_index([nil, 7, "turnX"], 1) do
        stray =
          note(tid(), "thread/tokenUsage/updated", %{turnId: turn_id, tokenUsage: %{last: last}})

        fresh(bin, n, tid(), [stray | reply(tid(), "Hi.")])

        [_user, %Message{role: :assistant, usage: usage}] = messages(prompt(start(ctx), "go"))
        assert %Helyx.Usage{input: 12, output: 7, cost: nil, cost_kind: nil} = usage
      end
    end
  end
end
