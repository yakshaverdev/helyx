defmodule Helyx.Tool.MCP.Launch do
  @moduledoc false
  # The start and the stop of one MCP server program under
  # `Helyx.Watchdog` (`docs/features/mcp-client.md`, decision 12): stderr to
  # /dev/null, open input, and only the variables of `@keep` of the node
  # with the `env` of its config.

  # The variables of the node that a server gets (decision 12).
  @keep ~w(HOME LOGNAME PATH SHELL TERM USER TMPDIR LANG)
  # The wait for a server's exit after the end of its input, before the
  # signals, as `Helyx.HarnessIO` waits for a harness program.
  @end_wait_ms 1_000

  # `opts`: `:watchdog_exe`, for tests.
  def start(config, cwd, deadline, opts) do
    argv = ["/bin/sh", "-c", ~S(exec "$0" "$@" 2>/dev/null), config.command | config.args]
    # Every other variable of the node is unset, so no value of it goes
    # through an argument.
    unset = for {name, _value} <- System.get_env(), name not in @keep, do: name
    unset = Enum.reject(unset, &Map.has_key?(config.env, &1))
    exe = for {:watchdog_exe, exe} <- opts, do: {:watchdog_exe, exe}
    start_opts = [env: Map.to_list(config.env), unset: unset, deadline: deadline] ++ exe
    Helyx.Watchdog.start(argv, cwd, :open, start_opts)
  end

  # The shutdown of MCP over stdio: the end of the server's input, a wait
  # for its exit, then the signals, which the watchdog sends when the port
  # closes with the caller's end.
  def shutdown(port) do
    Helyx.Watchdog.write(port, <<0>>)

    receive do
      {^port, {:exit_status, _status}} -> :ok
    after
      @end_wait_ms -> :ok
    end
  end
end
