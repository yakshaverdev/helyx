# `:real_claude` tests run the real program; include them by hand.
ExUnit.start(exclude: [:real_claude])

defmodule Helyx.Test.OSHelpers do
  @moduledoc false
  # OS-level polling assertions shared by the tests of the bash tool and
  # `Helyx.Watchdog`.
  import ExUnit.Assertions

  # Polls until the command has written its pid to `path`.
  def wait_for_pid(path, tries \\ 200) do
    with {:ok, content} <- File.read(path),
         [pid] <- Regex.run(~r/^\d+$/m, content) do
      pid
    else
      _ when tries > 0 ->
        Process.sleep(10)
        wait_for_pid(path, tries - 1)

      _ ->
        flunk("no pid in #{path}")
    end
  end

  # A pid, or a whole process group as "-<pgid>".
  def os_alive?(target) do
    match?({_, 0}, System.cmd("kill", ["-0", "--", to_string(target)], stderr_to_stdout: true))
  end

  # Polls until the target is gone, for signal delivery that is not
  # instantaneous.
  def gone_within?(target, tries) do
    cond do
      not os_alive?(target) ->
        true

      tries == 0 ->
        false

      true ->
        Process.sleep(10)
        gone_within?(target, tries - 1)
    end
  end

  def group_gone_within?(group, tries), do: gone_within?("-#{group}", tries)

  # The one way a test signals a process group. procps-ng kill(1) reads a
  # "-<group>" with no "--" before it as options: `kill -STOP -122` sends
  # SIGSTOP to -1, every process the user may signal (seen with 4.0.4). A
  # group below 2 is never signalled, the same lock as `Helyx.Watchdog.Group`.
  def signal_group(signal, group) when is_integer(group) and group > 1,
    do: System.cmd("kill", ["-#{signal}", "--", "-#{group}"], stderr_to_stdout: true)
end
