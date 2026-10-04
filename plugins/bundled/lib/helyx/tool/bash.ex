defmodule Helyx.Tool.Bash do
  @keep_bytes 4 * Helyx.Text.max_bytes()

  # The time limit of a call, in seconds: the default, and the most that the
  # `timeout` argument may ask.
  @default_timeout_s 120
  @max_timeout_s 600

  @moduledoc """
  Runs a shell command in the working directory with `bash -c`.

  stdout and stderr are merged. Long output is cut from the head end and the
  result says which lines it shows. Only the last #{@keep_bytes} bytes are
  kept while the command runs, so a command that never stops writing does
  not grow the buffer; the result then says so, and its line count is of
  the kept part. A non-zero exit code is reported in the text; the result
  is an error only when the command could not start or timed out. stdin is
  `/dev/null`. The call returns when stdout closes, so a background child
  that keeps stdout open holds the call until it exits, or until the
  release deadline after the limit.

  Each call has a time limit: the optional `timeout` argument, in seconds
  from 1 to #{@max_timeout_s}; missing or `null` is #{@default_timeout_s} s. At the limit the
  tool releases the command group as an abort does (TERM, a grace, KILL),
  and the result is an error with the output so far
  (`docs/features/bash-timeout.md`).

  The command runs in its own process group under a perl watchdog, started
  by `Helyx.Watchdog`, which holds the group with the hands before the
  command is allowed to execute. The watchdog ties the command's life to
  the port: when the port closes, because anything above the command died,
  the watchdog kills the group. perl is required; `check/0` reports a
  system without it when a session starts or resumes.
  """

  @behaviour Helyx.Tool

  @impl true
  def name, do: "bash"

  @impl true
  def description do
    "Run a shell command in the working directory. Returns stdout and stderr, " <>
      "the last #{Helyx.Text.max_lines()} lines or #{div(Helyx.Text.max_bytes(), 1024)} KB, " <>
      "and the exit code when it is not zero. The command group is released after `timeout` " <>
      "seconds, #{@default_timeout_s} by default, at most #{@max_timeout_s}."
  end

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "command" => %{"type" => "string"},
        "timeout" => %{"type" => "integer", "minimum" => 1, "maximum" => @max_timeout_s}
      },
      "required" => ["command"]
    }
  end

  @impl true
  def check, do: check(&System.find_executable/1)

  @doc false
  def check(find) do
    if find.("perl") do
      :ok
    else
      {:error, "perl not found: the bash tool needs perl to watch its commands"}
    end
  end

  # Port arguments are NUL-terminated C strings: a command with a NUL would
  # be cut there silently and the result would report success for something
  # that did not run as given. JSON strings can carry an escaped NUL, so the
  # model can send one. The session checks the working directory at start.
  @impl true
  def run(%{"command" => command} = args, cwd) when is_binary(command) do
    with :ok <- no_nul(command),
         {:ok, timeout_s} <- timeout(args["timeout"]),
         do: run_command(command, cwd, timeout_s * 1000)
  end

  def run(_args, _cwd), do: {:error, "bash needs a command"}

  defp no_nul(command) do
    if String.contains?(command, <<0>>),
      do: {:error, "the command contains a NUL byte"},
      else: :ok
  end

  # Missing or `null` is the default, as the read tool's `offset`.
  defp timeout(nil), do: {:ok, @default_timeout_s}
  defp timeout(s) when is_integer(s) and s in 1..@max_timeout_s, do: {:ok, s}

  defp timeout(_other),
    do: {:error, "timeout must be an integer from 1 to #{@max_timeout_s} (seconds)"}

  @impl true
  defdelegate release(handles, mode, deadline), to: Helyx.Watchdog.Group

  @doc false
  # Public for the tests of the limit, which give it in ms. The limit
  # counts from before the start, so it counts the time of the hold and the
  # marker, but it cannot end those waits.
  def run_command(command, cwd, limit_ms) do
    bash = System.find_executable("bash") || "/bin/bash"
    deadline = System.monotonic_time(:millisecond) + limit_ms

    result(Helyx.Watchdog.start([bash, "-c", command], cwd, nil), deadline, limit_ms)
  end

  # `Helyx.Watchdog.start/4` cuts the reason of a failed start.
  defp result({:error, reason}, _deadline, _limit_ms),
    do: {:error, "the command did not start: " <> reason}

  # `pre`, perl's own startup output, stays in front of the output.
  defp result({:started, port, pre, handles}, deadline, limit_ms) do
    case collect(port, pre, false, deadline) do
      {:timeout, output, dropped?} ->
        {output, dropped?} = stop(port, handles, output, dropped?)

        {:error,
         render(output, dropped?) <>
           "\nTimed out after #{duration(limit_ms)}: the command group was released."}

      {:exit, output, dropped?, 0} ->
        {:ok, render(output, dropped?)}

      {:exit, output, dropped?, status} ->
        {:ok, render(output, dropped?) <> "\nExit code: #{status}"}
    end
  end

  # The release of an abort, and beside it the read of what the command
  # writes while it stops (a TERM trap), so that output still goes through
  # `keep_tail/1` and not into the mailbox unread. The read ends at the exit
  # status, which needs stdout closed, or at the one deadline of the longest
  # release. The one deadline bounds every wait here: at it the port closes,
  # so no more output arrives, and a release still running is killed, as
  # the hands do, since a kill(1) run has no timeout of its own. The hands
  # release again at delivery what is still held.
  defp stop(port, handles, output, dropped?) do
    deadline = System.monotonic_time(:millisecond) + Helyx.Watchdog.Group.max_cancel_ms()
    release = Task.async(fn -> release(handles, :cancel, deadline) end)

    {output, dropped?} =
      case collect(port, output, dropped?, deadline) do
        {:timeout, output, dropped?} ->
          Helyx.Watchdog.close(port)
          {output, dropped?}

        {:exit, output, dropped?, _status} ->
          {output, dropped?}
      end

    left = max(deadline - System.monotonic_time(:millisecond), 0)
    _held = Task.yield(release, left) || Task.shutdown(release, :brutal_kill)
    {output, dropped?}
  end

  defp duration(ms) when rem(ms, 1000) == 0, do: "#{div(ms, 1000)} s"
  defp duration(ms), do: "#{ms} ms"

  defp render(output, dropped?) do
    text =
      case output do
        "" -> "(no output)"
        out -> Helyx.Text.truncate(out, :tail)
      end

    if dropped?,
      do: "[output cut: only the last #{@keep_bytes} bytes were kept]\n" <> text,
      else: text
  end

  # Reads until `{:exit, acc, dropped?, status}`, or `{:timeout, acc,
  # dropped?}` at the monotonic `deadline`. The deadline is checked before
  # each receive: a message in the mailbox wins over `after`, so a command
  # that keeps output queued would otherwise never reach the limit.
  defp collect(port, acc, dropped?, deadline) do
    case deadline - System.monotonic_time(:millisecond) do
      left when left <= 0 ->
        {:timeout, acc, dropped?}

      left ->
        receive do
          {^port, {:data, data}} ->
            {acc, cut?} = keep_tail(acc <> data)
            collect(port, acc, dropped? or cut?, deadline)

          {^port, {:exit_status, status}} ->
            {:exit, acc, dropped?, status}
        after
          left -> {:timeout, acc, dropped?}
        end
    end
  end

  # Cuts at twice the cap so the copy is amortised, not once per chunk.
  # The cut can land inside a character; the hands repair the partial
  # character at the start of the result.
  @doc false
  # Public for the direct test of the cut.
  def keep_tail(acc) when byte_size(acc) <= 2 * @keep_bytes, do: {acc, false}
  def keep_tail(acc), do: {binary_part(acc, byte_size(acc) - @keep_bytes, @keep_bytes), true}
end
