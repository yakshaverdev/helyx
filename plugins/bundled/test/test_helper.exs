# `:real_claude` tests run the real program; include them by hand.
# One `assert_receive` timeout for every test: the 100 ms default fails on a
# loaded machine. A wait that must not happen keeps its own stated margin.
ExUnit.start(exclude: [:real_claude], assert_receive_timeout: 1_000)

defmodule Helyx.Test.OSHelpers do
  @moduledoc false
  # OS-level polling assertions shared by the tests of the bash tool and
  # `Helyx.Watchdog`.
  import ExUnit.Assertions

  # Each poll sleeps this long, so a wait of `ms` lasts at least `ms`.
  @poll_ms 10

  # Polls until the command has written its pid to `path`, for at least `ms`.
  def wait_for_pid(path, ms \\ 2_000) do
    with {:ok, content} <- File.read(path),
         [pid] <- Regex.run(~r/^\d+$/m, content) do
      pid
    else
      _ when ms > 0 ->
        Process.sleep(@poll_ms)
        wait_for_pid(path, ms - @poll_ms)

      _ ->
        flunk("no pid in #{path}")
    end
  end

  # A pid, or a whole process group as "-<pgid>".
  def os_alive?(target) do
    match?({_, 0}, System.cmd("kill", ["-0", "--", to_string(target)], stderr_to_stdout: true))
  end

  # Polls until the target is gone, for signal delivery that is not
  # instantaneous. False when it still lives after at least `ms`.
  def gone_within?(target, ms) do
    cond do
      not os_alive?(target) ->
        true

      ms <= 0 ->
        false

      true ->
        Process.sleep(@poll_ms)
        gone_within?(target, ms - @poll_ms)
    end
  end

  def group_gone_within?(group, ms), do: gone_within?("-#{group}", ms)

  # The one way a test signals a process group. procps-ng kill(1) reads a
  # "-<group>" with no "--" before it as options: `kill -STOP -122` sends
  # SIGSTOP to -1, every process the user may signal (seen with 4.0.4). A
  # group below 2 is never signalled, the same lock as `Helyx.Watchdog.Group`.
  def signal_group(signal, group) when is_integer(group) and group > 1,
    do: System.cmd("kill", ["-#{signal}", "--", "-#{group}"], stderr_to_stdout: true)
end
