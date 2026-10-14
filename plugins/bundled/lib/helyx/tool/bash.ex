defmodule Helyx.Tool.Bash do
  @keep_bytes 4 * Helyx.Text.max_bytes()

  # The time limit of a call, in seconds: the default, and the most that the
  # `timeout` argument may ask, in the foreground and in the background.
  @default_timeout_s 120
  @max_timeout_s 600
  @default_background_s 3_600
  @max_background_s 86_400

  # The most bytes that a background run writes to its output file.
  @max_file_bytes 64 * 1_048_576
  # The most bytes of the command in the end of a background run.
  @max_command_bytes 200

  # The most bytes of the `workdir` argument.
  @max_workdir_bytes 4096
  @workdir_error "workdir must be a UTF-8 string of at most #{@max_workdir_bytes} bytes with no NUL byte"

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

  The optional `workdir` argument names the folder the command runs in. It
  is expanded against the session folder with `Path.expand/2`, as the file
  tools expand their paths, so `~` and `..` resolve; missing, `null`, or
  `""` is the session folder. It must be a
  UTF-8 string of at most #{@max_workdir_bytes} bytes with no NUL byte, else
  the result is an error and nothing runs. A folder that the watchdog cannot
  enter fails the start, as the session folder does (`docs/features/bash-workdir.md`).

  With `background: true` the call returns at once with the process group
  and the path of the output file (`Helyx.Tool.background/0`,
  `Helyx.Tool.started/1`). The command runs on; its output goes to the
  file, at most #{@max_file_bytes} bytes, and its end, with the first line of
  the command, the exit code, and the tail, is the end of the run. Its
  `timeout` is from 1 to #{@max_background_s} s, #{@default_background_s} by default.
  The agent stops it with `kill` on its group (`docs/features/background-bash.md`).

  The command runs in its own process group under a perl watchdog, started
  by `Helyx.Watchdog`, which holds the group with the hands before the
  command is allowed to execute. The watchdog ties the command's life to
  the port: when the port closes, because anything above the command died,
  the watchdog kills the group. perl is required; `check/0` reports a
  system without it when a session starts or resumes.
  """

  @behaviour Helyx.Tool

  defmodule Out do
    @moduledoc false
    # The output of a run: the kept tail, whether its head was cut, and for
    # a background run its file, the bytes that the command wrote, and the
    # error that ended the writes.
    defstruct tail: "", dropped?: false, file: nil, written: 0, error: nil
  end

  @impl true
  def name, do: "bash"

  @impl true
  def description do
    "Run a shell command in the working directory. Returns stdout and stderr, " <>
      "the last #{Helyx.Text.max_lines()} lines or #{div(Helyx.Text.max_bytes(), 1024)} KB, " <>
      "and the exit code when it is not zero. The command group is released after `timeout` " <>
      "seconds, #{@default_timeout_s} by default, at most #{@max_timeout_s}. " <>
      "`workdir` runs the command in another folder: relative to the working directory, " <>
      "absolute, or under `~/`, the home folder. " <>
      "`background: true` returns at once with the process group and an output file; " <>
      "the command runs on, and its end arrives later as a message, so do not poll. " <>
      "A background `timeout` is #{@default_background_s} seconds by default, " <>
      "at most #{@max_background_s}. Stop it with `kill -TERM -- -<group>`."
  end

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "command" => %{"type" => "string"},
        "timeout" => %{"type" => "integer", "minimum" => 1, "maximum" => @max_background_s},
        "workdir" => %{"type" => "string"},
        "background" => %{"type" => "boolean"}
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
  # model can send one. The session checks its folder at start; the
  # watchdog enters the folder of the call, so a bad `workdir` fails there.
  @impl true
  def run(%{"command" => command} = args, cwd) when is_binary(command) do
    with :ok <- no_nul(command),
         {:ok, background?} <- background(args["background"]),
         {:ok, timeout_s} <- timeout(args["timeout"], background?),
         {:ok, dir} <- workdir(args["workdir"], cwd) do
      if background?,
        do: run_background(command, dir, timeout_s * 1000),
        else: run_command(command, dir, timeout_s * 1000)
    end
  end

  def run(_args, _cwd), do: {:error, "bash needs a command"}

  defp no_nul(command) do
    if String.contains?(command, <<0>>),
      do: {:error, "the command contains a NUL byte"},
      else: :ok
  end

  defp background(nil), do: {:ok, false}
  defp background(value) when is_boolean(value), do: {:ok, value}
  defp background(_other), do: {:error, "background must be true or false"}

  # Missing or `null` is the default, as the read tool's `offset`.
  defp timeout(s, false), do: timeout(s, @default_timeout_s, @max_timeout_s, "timeout")

  defp timeout(s, true),
    do: timeout(s, @default_background_s, @max_background_s, "a background timeout")

  defp timeout(nil, default, _max, _name), do: {:ok, default}
  defp timeout(s, _default, max, _name) when is_integer(s) and s in 1..max//1, do: {:ok, s}

  defp timeout(_other, _default, max, name),
    do: {:error, "#{name} must be an integer from 1 to #{max} (seconds)"}

  # A NUL would cut the port argument, as in the command. The watchdog
  # enters the folder before the command runs, so a folder that is not
  # there fails the start.
  defp workdir(nil, cwd), do: {:ok, cwd}

  defp workdir(path, cwd)
       when is_binary(path) and byte_size(path) <= @max_workdir_bytes do
    if String.valid?(path) and not String.contains?(path, <<0>>),
      do: {:ok, Path.expand(path, cwd)},
      else: {:error, @workdir_error}
  end

  defp workdir(_other, _cwd), do: {:error, @workdir_error}

  @impl true
  defdelegate release(handles, mode, deadline), to: Helyx.Watchdog.Group

  @doc false
  # Public for the tests of the limit, which give it in ms. The limit
  # counts from before the start, so it counts the time of the hold and the
  # marker, but it cannot end those waits.
  def run_command(command, cwd, limit_ms) do
    deadline = System.monotonic_time(:millisecond) + limit_ms

    with {:started, port, pre, handles} <- start(command, cwd),
         do: result(port, add(%Out{}, pre), handles, deadline, limit_ms)
  end

  # A background run takes its place and makes its file before the start,
  # so a run over the limit, or with no file, starts nothing. The limit
  # counts from before the start, as in the foreground.
  defp run_background(command, cwd, limit_ms) do
    deadline = System.monotonic_time(:millisecond) + limit_ms

    with {:ok, %{id: id, dir: dir}} <- Helyx.Tool.background(),
         path = Path.join(dir, id <> ".out"),
         {:ok, file} <- open(path),
         {:started, port, pre, handles} <- start(command, cwd) do
      {:command, group} = List.keyfind(handles, :command, 0)

      :ok =
        Helyx.Tool.started(
          "Process group: #{group}\nOutput file: #{path}\n" <>
            "Stop it with `kill -TERM -- -#{group}`. Its end arrives as a message."
        )

      {status, text} = result(port, add(%Out{file: file}, pre), handles, deadline, limit_ms)
      {status, "Command: " <> first_line(command) <> "\n" <> text}
    end
  end

  # `:exclusive`: the file is new, so a link at its path is never followed.
  defp open(path) do
    case File.open(path, [:write, :exclusive, :raw, :binary]) do
      {:ok, file} ->
        {:ok, file}

      {:error, reason} ->
        {:error, "the output file could not be made: #{:file.format_error(reason)}"}
    end
  end

  defp first_line(command) do
    [line | _] = String.split(command, "\n", parts: 2)
    Helyx.Text.cap(line, @max_command_bytes, :head)
  end

  # `Helyx.Watchdog.start/4` cuts the reason of a failed start.
  defp start(command, cwd) do
    bash = System.find_executable("bash") || "/bin/bash"

    case Helyx.Watchdog.start([bash, "-c", command], cwd, nil) do
      {:error, reason} -> {:error, "the command did not start: " <> reason}
      started -> started
    end
  end

  # `out` holds `pre`, perl's own startup output, in front of the output.
  defp result(port, out, handles, deadline, limit_ms) do
    case collect(port, out, deadline) do
      {:timeout, out} ->
        out = stop(port, handles, out)

        {:error,
         render(out) <> "\nTimed out after #{duration(limit_ms)}: the command group was released."}

      {:exit, out, 0} ->
        {:ok, render(out)}

      {:exit, out, status} ->
        {:ok, render(out) <> "\nExit code: #{status}"}
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
  defp stop(port, handles, out) do
    deadline = System.monotonic_time(:millisecond) + Helyx.Watchdog.Group.max_cancel_ms()
    release = Task.async(fn -> release(handles, :cancel, deadline) end)

    out =
      case collect(port, out, deadline) do
        {:timeout, out} ->
          Helyx.Watchdog.close(port)
          out

        {:exit, out, _status} ->
          out
      end

    left = max(deadline - System.monotonic_time(:millisecond), 0)
    _held = Task.yield(release, left) || Task.shutdown(release, :brutal_kill)
    out
  end

  defp duration(ms) when rem(ms, 1000) == 0, do: "#{div(ms, 1000)} s"
  defp duration(ms), do: "#{ms} ms"

  @doc false
  # Public for the direct test of the file bound.
  def render(%Out{} = out) do
    text =
      case out.tail do
        "" -> "(no output)"
        tail -> Helyx.Text.truncate(tail, :tail)
      end

    notes = [
      out.dropped? && "[output cut: only the last #{@keep_bytes} bytes were kept]\n",
      out.written > @max_file_bytes &&
        "[the command wrote #{out.written} bytes; the output file holds the first #{@max_file_bytes}]\n",
      out.error && "[the output file could not be written: #{out.error}]\n"
    ]

    IO.iodata_to_binary([for(note <- notes, note, do: note), text])
  end

  # Reads until `{:exit, out, status}`, or `{:timeout, out}` at the
  # monotonic `deadline`. The deadline is checked before each receive: a
  # message in the mailbox wins over `after`, so a command that keeps
  # output queued would otherwise never reach the limit.
  defp collect(port, out, deadline) do
    case deadline - System.monotonic_time(:millisecond) do
      left when left <= 0 ->
        {:timeout, out}

      left ->
        receive do
          {^port, {:data, data}} -> collect(port, add(out, data), deadline)
          {^port, {:exit_status, status}} -> {:exit, out, status}
        after
          left -> {:timeout, out}
        end
    end
  end

  @doc false
  # Public for the direct test of the file bound. Keeps the tail in memory
  # and, for a background run, writes `data` to the file up to
  # `@max_file_bytes`; `written` counts every byte that the command wrote.
  # A write that fails ends the writes, and the end says why.
  def add(%Out{} = out, data) do
    {tail, cut?} = keep_tail(out.tail <> data)
    write(%{out | tail: tail, dropped?: out.dropped? or cut?}, data)
  end

  defp write(%Out{file: nil} = out, _data), do: out

  defp write(%Out{written: written} = out, data) when written >= @max_file_bytes,
    do: %{out | written: written + byte_size(data)}

  defp write(%Out{file: file, written: written} = out, data) do
    part = binary_part(data, 0, min(@max_file_bytes - written, byte_size(data)))

    case :file.write(file, part) do
      :ok -> %{out | written: written + byte_size(data)}
      {:error, reason} -> %{out | file: nil, error: to_string(:file.format_error(reason))}
    end
  end

  @doc false
  def max_file_bytes, do: @max_file_bytes

  # Cuts at twice the cap so the copy is amortised, not once per chunk.
  # The cut can land inside a character; the hands repair the partial
  # character at the start of the result.
  @doc false
  # Public for the direct test of the cut.
  def keep_tail(acc) when byte_size(acc) <= 2 * @keep_bytes, do: {acc, false}
  def keep_tail(acc), do: {binary_part(acc, byte_size(acc) - @keep_bytes, @keep_bytes), true}
end
