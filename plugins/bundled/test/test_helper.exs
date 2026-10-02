# `:real_claude` tests run the real program; include them by hand.
# `:slow` tests wait real seconds or scan large spaces: `HELYX_SLOW=1`
# includes them, as `/ship` and the merge gate do (#295).
# One cap for every wait that must happen, `assert_receive` and the support
# helpers alike (`Helyx.Test.Events.wait_ms/0`). Only a failing test waits
# this long, so it is far above any delay that load makes: the precommit
# runs every project with Dialyzer and Credo at once (#295). A wait that
# must not happen keeps its own stated margin.
slow? = System.get_env("HELYX_SLOW") == "1"
exclude = if slow?, do: [], else: [:slow]
# The fast tier checks each property with fewer cases than the default 100.
unless slow?, do: Application.put_env(:stream_data, :max_runs, 25)

ExUnit.start(
  exclude: [:real_claude | exclude],
  assert_receive_timeout: 30_000
)

# The harness tests run their own fake `claude` and `codex` from `../bin`
# of the session's working directory. PATH is global, so an async test must
# not change it: this one entry stays for the whole run. With no fake there,
# the program on the rest of PATH runs.
dispatch = Path.expand("../_build/test_dispatch", __DIR__)
File.mkdir_p!(dispatch)

for program <- ["claude", "codex"] do
  file = Path.join(dispatch, program)

  script = """
  #!/bin/sh
  [ -x ../bin/#{program} ] && exec ../bin/#{program} "$@"
  PATH=${PATH#*:} exec #{program} "$@"
  """

  # A second run in this checkout can run the script now. A rename
  # replaces it at once, so that run never reads a part of it.
  # The remote runs of precommit.sh each have their own pid namespace, so
  # an OS pid can repeat; a random suffix does not.
  tmp = "#{file}.#{Base.url_encode64(:crypto.strong_rand_bytes(9))}"
  File.write!(tmp, script)
  File.chmod!(tmp, 0o755)
  File.rename!(tmp, file)
end

System.put_env("PATH", dispatch <> ":" <> System.get_env("PATH"))

defmodule Helyx.Test.OSHelpers do
  @moduledoc false
  # OS-level polling assertions shared by the tests of the bash tool and
  # `Helyx.Watchdog`.
  import ExUnit.Assertions

  # Each poll sleeps this long.
  @poll_ms 10

  # Polls until the command has written its pid to `path`, for at least `ms`.
  def wait_for_pid(path, ms \\ Helyx.Test.Events.wait_ms()) do
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

  # The cap of a wait for a kill. It is far above the delay of a signal
  # under load, and far below the 30 s that the test programs sleep, so a
  # program that ends by itself does not pass as killed (#295).
  @gone_ms 10_000

  # Polls until the target is gone, for signal delivery that is not
  # instantaneous. False when it still lives `ms` after the call.
  def gone_within?(target, ms \\ @gone_ms),
    do: gone_by?(target, System.monotonic_time(:millisecond) + ms)

  def group_gone_within?(group, ms \\ @gone_ms), do: gone_within?("-#{group}", ms)

  defp gone_by?(target, deadline) do
    cond do
      not os_alive?(target) ->
        true

      System.monotonic_time(:millisecond) >= deadline ->
        false

      true ->
        Process.sleep(@poll_ms)
        gone_by?(target, deadline)
    end
  end

  # The one way a test signals a process group. procps-ng kill(1) reads a
  # "-<group>" with no "--" before it as options: `kill -STOP -122` sends
  # SIGSTOP to -1, every process the user may signal (seen with 4.0.4). A
  # group below 2 is never signalled, the same lock as `Helyx.Watchdog.Group`.
  def signal_group(signal, group) when is_integer(group) and group > 1,
    do: System.cmd("kill", ["-#{signal}", "--", "-#{group}"], stderr_to_stdout: true)
end
