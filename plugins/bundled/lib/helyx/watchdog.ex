defmodule Helyx.Watchdog do
  @moduledoc false
  # Runs a program in its own process group under a perl watchdog, and
  # releases the groups. The bash tool and, through `Helyx.HarnessIO`, the
  # harness providers share it; it is not a plugin, and no plugin calls
  # another (ADR 0005).
  #
  # `start/4` opens the port, holds the watchdog with the hands, reads the
  # group marker, holds the command group, and only then sends the go-ahead,
  # so either the hands hold the group before the program runs, or it never
  # ran (ADR 0004). `Helyx.Watchdog.Group.release/4` is the `release/3` of
  # the plugin that holds the handles. perl is required.

  # The watchdog forks the command into its own process group and stays in
  # the launcher's own group, so the port's OS process is the watchdog. It
  # writes the command's group id as the stdout marker and holds the command
  # until the go-ahead byte arrives on stdin, so either the hands hold the
  # group id before the command runs, or the command never ran. Then it
  # watches: when its stdin ends, because the port closed, it TERMs the
  # group, waits the grace period (its fourth argument, in ms), KILLs it,
  # and reaps the command before it exits (a read that fails gives undef,
  # which is also false, so a read error kills the group too). The wait
  # ends when its direct child exits, not when the group is empty. When
  # the command ends first, the watchdog exits with the command's status
  # (128 plus the signal for a signal death). The watchdog ignores TERM in
  # the parent only, after the fork, so a release can TERM every held
  # group without cutting the cleanup short; ignored dispositions survive
  # exec, so the child must not inherit one. The 50 ms select tick is the
  # poll for both stdin and the child.
  #
  # The input (#10). The second argument is the input mode: -1 for none or
  # -2 for open. With none, the command's stdin is /dev/null. With open
  # (#11), it is a pipe: the watchdog forwards everything that follows the
  # go-ahead byte on its own stdin up to the first NUL byte, then closes the
  # pipe and sets the mode to 0, the mark of a closed input. A protocol of
  # JSON lines never holds a raw NUL, so a NUL ends the input and the
  # command reads end of file while the watch of stdin goes on. The
  # go-ahead is read as one byte, so no buffer takes input bytes from the
  # loop. The pipe is non-blocking and the loop writes it only when select
  # reports it writable, so a command that does not read cannot stop the
  # watch of stdin. A write that fails for any other reason than a full
  # pipe (the command closed its stdin) drops the rest of the input.
  # SIGPIPE is ignored in the parent only, after the fork, like TERM. Open
  # input has a cap (#196), the fifth argument: when the input that the
  # command has not read is over it, after a read of stdin, the command is
  # stuck. The watchdog stops the group as at the end of its stdin, then
  # exits as at the command's own end, with its status. The watchdog reads
  # stdin at every tick, so a closed port is seen at once; a cap on the
  # read would hold a stuck command past the close.
  #
  # The watchdog enters the working directory itself, before the fork. The
  # port's cd option has no failure signal: the emulator's child exits with
  # status 2, which a real command can also do. A chdir, pipe, or fork that
  # fails writes the marker with `0`, which is never a group id, then the
  # reason, and no command exists. A held child whose `exec` fails writes
  # "cannot run <program>: <reason>" and exits with 127, as a shell does.
  #
  # A marker line is "<nonce> <number>". The nonce is random for each call
  # and reaches the watchdog in its arguments only. The command is held
  # until the go-ahead, so no command output can come before the marker.
  # perl's own startup output can, because stderr is merged: a bad locale
  # warning prints environment values, which can hold any line. It cannot
  # hold the nonce, so no text can pass for a marker; `read_marker/4` reads
  # past the rest.
  @watchdog_path Path.join(__DIR__, "watchdog/watchdog.pl")
  @external_resource @watchdog_path
  @watchdog File.read!(@watchdog_path)

  # The TERM grace when the port closes, and of a cancel in
  # `Helyx.Watchdog.Group`, unless the caller gives one.
  @grace_ms 500

  @doc false
  def grace_ms, do: @grace_ms

  # The most open input that the command has not read, in the watchdog
  # (#196). Public for the tests.
  @stdin_max_bytes 16 * 1024 * 1024

  @doc false
  def stdin_max_bytes, do: @stdin_max_bytes

  # The longest reason of a start that failed: it goes into a notice of the
  # harness providers and into the bash tool's error. perl's warnings quote
  # the environment as raw bytes, so the cut also drops invalid bytes.
  @reason_max_bytes Helyx.Provider.max_notice_bytes()

  @doc false
  # Opens the port for `argv` in `cwd` and runs the handshake. With `input`
  # nil the command's stdin is /dev/null. With `:open` the command reads
  # what `write/2` sends until `write(port, <<0>>)` or the close. The
  # callers check for perl first (the bash tool's `check/0`,
  # `Helyx.HarnessIO.find/1`). Returns:
  #
  #   * `{:started, port, pre}`: the go-ahead is sent. `pre` is what came
  #     before the marker, perl's own startup output.
  #   * `{:error, reason}`: no command ran, and the port is closed. Either
  #     the watchdog did not fork, and `reason` is the tail of the rest of
  #     the stream up to the exit status, read here; or it gave no marker,
  #     and `reason` is a head that names perl. `reason` is valid UTF-8 of
  #     at most `@reason_max_bytes`.
  #
  # Only a group marker leads to the go-ahead, after the group is held: a
  # command never runs without its group in the hands. With no marker, the
  # closed port is the watchdog's signal to kill the child it holds, if it
  # got that far.
  #
  # The option `:grace_ms` (default #{@grace_ms}) is the wait between the
  # TERM and the KILL of the command group when the port closes, or when
  # open input that the command has not read is over
  # `@stdin_max_bytes`.
  def start(argv, cwd, input, opts \\ []) do
    nonce = random_word()
    grace = Keyword.get(opts, :grace_ms, @grace_ms)
    {exe, options} = launcher(argv, cwd, nonce, feed(input), grace)
    handshake(Port.open({:spawn_executable, exe}, options), nonce)
  end

  defp handshake(port, nonce) do
    # The runtime detaches port programs into their own process group, so
    # the port's OS pid is the watchdog's group. Held as :watchdog: the
    # release waits for it, so an abort cannot return while the command is
    # a zombie, and KILLs it only after the command group is gone, so a
    # KILL can never cut the reap short.
    case Port.info(port, :os_pid) do
      {:os_pid, os_pid} -> Helyx.Tool.hold({:watchdog, os_pid})
      nil -> :ok
    end

    case read_marker(port, nonce, "", "") do
      {:not_started, acc} ->
        {:error, port |> read_to_exit(acc) |> Helyx.Text.cap(@reason_max_bytes, :tail)}

      # Names the watchdog, not a cause: perl may be gone, fail to compile
      # the watchdog, or never run (an argv over the OS limit).
      {:no_marker, text} ->
        close(port)
        reason = "the perl watchdog gave no marker: " <> text
        {:error, Helyx.Text.cap(reason, @reason_max_bytes, :head)}

      {group, pre} ->
        Helyx.Tool.hold({:command, group})
        # A port that closed already drops the write; its exit status is in
        # the mailbox for the caller's read.
        write(port, "\n")
        {:started, port, pre}
    end
  end

  # The marker's chunk can hold only the head of the reason: the port cuts
  # the stream where a pipe read ends, on macOS at 512 bytes (#340). The
  # watchdog writes the reason in one write, at most an error text with
  # `cwd` in it, and exits right after it, so the exit status ends the read.
  defp read_to_exit(port, acc) do
    receive do
      {^port, {:data, data}} -> read_to_exit(port, acc <> data)
      {^port, {:exit_status, _status}} -> acc
    end
  end

  @doc false
  # Public for the watchdog's direct tests. `feed` is the input mode, -1
  # for none or -2 for open input (see the watchdog). `grace_ms` is the
  # TERM grace when the port closes.
  def launcher(argv, cwd, nonce, feed, grace_ms \\ @grace_ms) do
    # No cd option: the watchdog enters `cwd`, so a failure has a signal.
    {System.find_executable("perl"),
     [
       :binary,
       :exit_status,
       :stderr_to_stdout,
       {:args,
        [
          "-e",
          @watchdog,
          "--",
          nonce,
          Integer.to_string(feed),
          cwd,
          Integer.to_string(grace_ms),
          Integer.to_string(@stdin_max_bytes)
        ] ++ argv}
     ]}
  end

  defp random_word, do: Base.encode16(:crypto.strong_rand_bytes(8))

  defp feed(nil), do: -1
  defp feed(:open), do: -2

  @doc false
  # Writes to the watchdog's stdin. A port whose watchdog already died is
  # closed and the write raises; the exit status is still in the mailbox for
  # the caller's read. A watchdog that died while the port is open makes
  # the write close the port with `:epipe`; the harness providers' read
  # loops take that as the end of the run (#167).
  def write(port, data) do
    Port.command(port, data)
  rescue
    ArgumentError -> false
  end

  # A close of a port that may be closed already: after an exit it is.
  @doc false
  def close(port) do
    Port.close(port)
  rescue
    ArgumentError -> false
  end

  # The marker line must end within this many bytes of the stream. Lines
  # that perl itself may write before it take the room; a locale warning is
  # about 400 bytes.
  @max_preamble_bytes 4096

  # Finds the marker line (see the watchdog). Lines that are not a marker
  # are read past, within `@max_preamble_bytes`, and kept in front of the
  # output. The marker exists however fast the command exited, because the
  # watchdog writes it before the command may run. Returns the group
  # (or `:not_started`, see the watchdog) and the output so far. A stream
  # that ends, or reaches the limit, with no marker is `:no_marker` with its
  # text: perl did not get as far as the watchdog, or wrote too much. Only
  # a line that ends within the limit counts, marker or not, so which
  # marker is found, if any, does not depend on how the stream is cut into
  # messages. The `:no_marker` text is what had arrived by then.
  @doc false
  # Public for the direct test of the preamble limit.
  def read_marker(port, nonce, pre, acc) do
    case String.split(acc, "\n", parts: 2) do
      [line, rest] when byte_size(pre) + byte_size(line) < @max_preamble_bytes ->
        case parse_marker(line, nonce) do
          nil -> read_marker(port, nonce, pre <> line <> "\n", rest)
          marker -> {marker, pre <> rest}
        end

      [_] when byte_size(pre) + byte_size(acc) < @max_preamble_bytes ->
        receive do
          {^port, {:data, data}} -> read_marker(port, nonce, pre, acc <> data)
          {^port, {:exit_status, _status}} -> {:no_marker, pre <> acc}
        end

      _ ->
        {:no_marker, pre <> acc}
    end
  end

  # `kill -- -1` would signal every process the user may signal, so nothing
  # below 2 is ever accepted as a group. 0 is the watchdog's word for a
  # command it could not start.
  defp parse_marker(line, nonce) do
    with [^nonce, number] <- String.split(line, " "),
         {number, ""} <- Integer.parse(number) do
      case number do
        0 -> :not_started
        group when group > 1 -> group
        _ -> nil
      end
    else
      _ -> nil
    end
  end
end
