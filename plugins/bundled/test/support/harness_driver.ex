defmodule Helyx.Test.HarnessDriver do
  @moduledoc false
  # Drives a harness provider's `harness_info/2` from the test process's
  # mailbox, without a session.
  import ExUnit.Assertions

  # A program answers a line in milliseconds; only a failing test waits this
  # long.
  @line_ms 5_000

  # Gives messages to `provider.harness_info/2` until `done?` holds for the
  # actions so far. A stop is the last action, `{:stop, reason}`.
  def pump(provider, state, actions, done?) do
    if done?.(actions) do
      {actions, state}
    else
      receive do
        message ->
          case provider.harness_info(message, state) do
            {:ok, more, state} -> pump(provider, state, actions ++ more, done?)
            {:stop, reason, state} -> {actions ++ [{:stop, reason}], state}
          end
      after
        @line_ms -> flunk("no end; got #{inspect(actions)}")
      end
    end
  end

  # Gives messages to `provider.harness_info/2` until `done?` holds for the
  # state. `actions?` checks the actions of each message.
  def settle(provider, state, done?, actions? \\ fn _ -> true end) do
    if done?.(state) do
      state
    else
      receive do
        message ->
          {:ok, actions, state} = provider.harness_info(message, state)
          assert actions?.(actions), "unexpected actions: #{inspect(actions)}"
          settle(provider, state, done?, actions?)
      after
        @line_ms -> flunk("no such state; got #{inspect(state)}")
      end
    end
  end
end
