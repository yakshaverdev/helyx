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
  # ran (ADR 0004). `release/3` is the `release/3` of the plugin that holds
  # the handles. perl is required.

  # The watchdog forks the command into its own process group and stays in
  # the launcher's own group, so the port's OS process is the watchdog. It
  # writes the command's group id as the stdout marker and holds the command
  # until the go-ahead line arrives on stdin, so either the hands hold the
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
  # The input (#10). The second argument is a byte count. At -1 the
  # command's stdin is /dev/null. At 0 or more it is a pipe: the watchdog
  # forwards exactly that many bytes of what follows the go-ahead line on its
  # own stdin, then closes the pipe, so the command reads end of file. The
  # go-ahead line is read one byte at a time, so no buffer takes input bytes
  # from the loop. The pipe is non-blocking and the loop writes it only when
  # select reports it writable, so a command that does not read cannot stop
  # the watch of stdin. A write that fails for any other reason than a full
  # pipe (the command closed its stdin) drops the rest of the input. SIGPIPE
  # is ignored in the parent only, after the fork, like TERM. At -2 the
  # input is open (#11): the watchdog forwards everything that follows the
  # go-ahead line up to the first NUL byte, then closes the pipe. A protocol
  # of JSON lines never holds a raw NUL, so a NUL ends the input and the
  # command reads end of file while the watch of stdin goes on. Open input
  # has a cap (#196), the fifth argument: when the input that the command
  # has not read is over it, after a read of stdin, the command is stuck.
  # The watchdog stops the group as at the end of its stdin, then exits as
  # at the command's own end, with its status. Counted input needs no cap:
  # the count bounds it. The watchdog reads stdin at every tick, so a closed
  # port is seen at once; a cap on the read would hold a stuck command
  # past the close.
  #
  # The watchdog enters the working directory itself, before the fork. The
  # port's cd option has no failure signal: the emulator's child exits with
  # status 2, which a real command can also do. A chdir, pipe, or fork that
  # fails writes the marker with `0`, which is never a group id, then the
  # reason, and no command exists.
  #
  # A marker line is "<nonce> <number>". The nonce is random for each call
  # and reaches the watchdog in its arguments only. The command is held
  # until the go-ahead, so no command output can come before the marker.
  # perl's own startup output can, because stderr is merged: a bad locale
  # warning prints environment values, which can hold any line. It cannot
  # hold the nonce, so no text can pass for a marker; `read_marker/4` reads
  # past the rest.
  #
  # The start report (#70). The held child writes the start line,
  # "<nonce> 1", as its last act before the `exec`, so the line is in front
  # of all command output, and a result is ok only with it: a watchdog that
  # dies before it passes the go-ahead on, or a child that dies while held,
  # leaves no start line. The child reports a failed `exec`, or its own
  # death by `die`, through a second pipe that closes on `exec` (perl sets
  # close-on-exec on every descriptor above 2): the watchdog reads end of
  # file when the `exec` worked, and the error when it did not. It reads
  # the pipe only after the child ended, so the read never waits: the write
  # end is closed by then, by the `exec` or by the exit, and the watchdog's
  # poll of stdin is never held. It then writes "<go> 0" and the error.
  # `<go>` is a second random word, which arrives on stdin as the go-ahead
  # line, after the fork: it is in no argument list and not in the child, so
  # a command that ran cannot write a failure report, and the report counts
  # wherever it is in the output, so text of perl in front of it cannot
  # hide it. The command can read the nonce from the process table, but a
  # start line is only true of a command that ran.
  #
  # The perl environment (#71). Variables of the environment change the
  # interpreter: `PERL_UNICODE` puts a `:utf8` layer on handles, and a
  # `sysread` or `syswrite` on such a handle is fatal; `PERL5OPT=-d` starts
  # the debugger on the watchdog's stdin; `PERL5LIB` can replace the POSIX
  # module. So the port starts perl without every variable whose name
  # starts with `PERL` (`launcher/5`), except `PERL_BADLANG`. That one only
  # stops the locale warning. A user with a locale that the system does not
  # have sets it to 0, and without it that user gets the warning in front of
  # every result.
  #
  # The values are the user's, and the command can be perl. So each value
  # stays in the environment under the name `HELYX_KEEP_<name>`, which perl
  # does not read, and the watchdog gives it its name back in `%ENV` before
  # the fork. `%ENV` does not change an interpreter that runs already. The
  # prefix `HELYX_KEEP_PERL` is reserved: the watchdog takes every such name
  # for one of its own. A kept value has a `=` in front, which the watchdog
  # takes off: the port takes an empty value for "remove", and an empty
  # `PERL_UNICODE` is not the same as none.
  @watchdog ~S"""
  use POSIX ":sys_wait_h";
  use Fcntl;
  my $nonce = shift @ARGV;
  sub fail { syswrite(STDOUT, "$nonce 0\n$_[0]: $!"); exit 0 }
  my $feed = shift @ARGV;
  my $dir = shift @ARGV;
  my $grace = shift(@ARGV) / 1000;
  my $cap = shift @ARGV;
  for (keys %ENV) { $ENV{$1} = substr(delete $ENV{$_}, 1) if /^HELYX_KEEP_(PERL.*)/s }
  chdir($dir) or fail("cannot enter the working directory $dir");
  pipe(my $r, my $w) or fail("pipe failed");
  pipe(my $er, my $ew) or fail("report pipe failed");
  my ($ir, $iw);
  if ($feed != -1) { pipe($ir, $iw) or fail("input pipe failed") }
  my $child = fork() // fail("fork failed");
  if ($child == 0) {
    close($w); close($er); close($iw) if $iw;
    setpgrp(0, 0);
    eval {
      sysread($r, my $go, 1) or exit 0;
      if ($ir) { open(STDIN, "<&", $ir) } else { open(STDIN, "<", "/dev/null") }
      syswrite(STDOUT, "$nonce 1\n");
      exec @ARGV;
      die "cannot run $ARGV[0]: $!\n";
    };
    syswrite($ew, $@);
    exit 0;
  }
  $SIG{TERM} = "IGNORE";
  $SIG{PIPE} = "IGNORE";
  close($r); close($ew); close($ir) if $ir;
  syswrite(STDOUT, "$nonce $child\n");
  my $go = ""; my $c = "";
  while (sysread(STDIN, $c, 1)) { last if $c eq "\n"; $go .= $c }
  if ($c eq "\n") { syswrite($w, "g"); close($w) }
  else { close($w); kill("KILL", -$child); waitpid($child, 0); exit 0 }
  fcntl($iw, F_SETFL, O_NONBLOCK) if $iw;
  sub stop {
    kill("TERM", -$child);
    my $t = 0; my $done;
    until (($done = waitpid($child, WNOHANG) > 0) or $t >= $grace) { select(undef, undef, undef, 0.05); $t += 0.05 }
    my $s = $?;
    kill("KILL", -$child);
    if (!$done) { waitpid($child, 0); $s = $? }
    $s
  }
  sub finish {
    if (sysread($er, my $err, 4096)) { syswrite(STDOUT, "$go 0\n$err"); exit 0 }
    exit(($_[0] & 127) ? 128 + ($_[0] & 127) : $_[0] >> 8);
  }
  my $out = "";
  while (1) {
    if ($iw and $feed == 0 and !length($out)) { close($iw); undef $iw }
    my $rin = ""; vec($rin, fileno(STDIN), 1) = 1;
    my $win; if ($iw and length($out)) { $win = ""; vec($win, fileno($iw), 1) = 1 }
    my $n = select(my $rout = $rin, $win, undef, 0.05);
    if ($n > 0 and vec($rout, fileno(STDIN), 1)) {
      my $got = sysread(STDIN, my $buf, 65536);
      if (!$got) { stop(); exit 0 }
      if ($iw and $feed < 0) {
        my $end = index($buf, "\0");
        if ($end < 0) { $out .= $buf } else { $out .= substr($buf, 0, $end); $feed = 0 }
        if (length($out) > $cap) { finish(stop()) }
      } elsif ($iw) { my $take = substr($buf, 0, $feed); $out .= $take; $feed -= length($take) }
    }
    if ($n > 0 and $win and vec($win, fileno($iw), 1)) {
      my $put = syswrite($iw, $out);
      if (defined($put)) { substr($out, 0, $put) = "" } elsif (!$!{EAGAIN}) { $out = ""; $feed = 0 }
    }
    finish($?) if waitpid($child, WNOHANG) > 0;
  }
  """

  # The TERM grace when the port closes, unless the caller gives one.
  @grace_ms 500

  # The most open input that the command has not read, in the watchdog
  # (#196). Public for the tests.
  @stdin_max_bytes 1024 * 1024

  @doc false
  def stdin_max_bytes, do: @stdin_max_bytes

  @doc false
  # Opens the port for `argv` in `cwd` and runs the handshake. With `input`
  # nil the command's stdin is /dev/null; with a binary the command reads
  # exactly that binary, then end of file. With `:open` the command reads
  # what `write/2` sends until `write(port, <<0>>)` or the close. Returns:
  #
  #   * `{:started, port, pre, nonce, go}`: the go-ahead is sent. `pre` is
  #     what came before the marker, perl's own startup output. The output
  #     that follows starts with the start line, "<nonce> 1", unless the
  #     child died before the `exec`; a failure report is "<go> 0".
  #   * `{:not_started, port, acc}`: the watchdog did not fork; the rest of
  #     the stream up to the exit status is the reason.
  #   * `{:failed, text}`: no command ran, and the port is closed: perl did
  #     not start (no port), the watchdog gave no marker, or it died before
  #     the go-ahead. The text always names perl.
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

    case open_port(exe, options) do
      {:ok, port} -> handshake(port, nonce, input)
      {:error, reason} -> {:failed, "perl did not start: " <> reason}
    end
  end

  # perl is used here, so its failure is handled here. The callers check
  # for perl earlier (the bash tool's `check/0`, `Helyx.HarnessIO.find/1`),
  # but PATH and the file can change after that check. The rescue also
  # catches a normalized error such as `SystemLimitError` at the port limit,
  # which has no `:original` field, so the text is the exception message.
  defp open_port(nil, _options), do: {:error, "not found on PATH"}

  defp open_port(exe, options) do
    {:ok, Port.open({:spawn_executable, exe}, options)}
  rescue
    error in ErlangError -> {:error, Exception.message(error)}
  end

  defp handshake(port, nonce, input) do
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
        {:not_started, port, acc}

      # Names the watchdog, not a cause: perl may be gone, fail to compile
      # the watchdog, or never run (an argv over the OS limit).
      {:no_marker, text} ->
        close(port)
        {:failed, "the perl watchdog gave no marker: " <> text}

      {group, pre} ->
        Helyx.Tool.hold({:command, group})
        go = random_word()

        case go_ahead(port, go) do
          :sent ->
            write_input(port, input)
            {:started, port, pre, nonce, go}

          :died ->
            {:failed, "the perl watchdog died before the go-ahead: " <> pre}
        end
    end
  end

  # A watchdog that dies after the marker can close its stdin while the
  # port is still open. The go-ahead write then gets EPIPE: the port closes
  # with the exit reason `:epipe`, sends no exit status, and its exit
  # signal would end the caller (#131). So the go-ahead traps exits. It is
  # its own write, and the first on the pipe, so the pipe takes all of it
  # or the write fails at once: no part of it waits in the port's queue.
  # `Port.info/2` is a port signal, which the port takes after the write.
  # A write that raised found the port closed. In both cases the watchdog
  # died before the go-ahead. The input is a later write. A port that
  # closes after `Port.info/2`, before the trap ends, leaves its exit
  # message in the mailbox, which no receive of `go_ahead/2` takes. No
  # write is pending then, so the close is not EPIPE.
  defp go_ahead(port, go) do
    trap = Process.flag(:trap_exit, true)

    result =
      cond do
        not write(port, [go, "\n"]) -> :died
        Port.info(port, :id) -> :sent
        true -> port_exit(port)
      end

    Process.flag(:trap_exit, trap)
    if not trap, do: pass_exits(port)
    result
  end

  # The port closed. A `:normal` close comes after the watchdog's exit
  # status, which is in the mailbox for the caller's read; any other reason
  # ends the caller, as the signal would have.
  defp port_exit(port) do
    receive do
      {:EXIT, ^port, :epipe} -> :died
      {:EXIT, ^port, :normal} -> :sent
      {:EXIT, ^port, reason} -> exit(reason)
    end
  end

  # Acts on the exit signals that the trap made messages, as a process that
  # does not trap exits does: a `:normal` one does nothing, any other ends
  # the process. The port's own exit is left for `port_exit/1`.
  defp pass_exits(port) do
    receive do
      {:EXIT, from, :normal} when from != port -> pass_exits(port)
      {:EXIT, from, reason} when from != port -> exit(reason)
    after
      0 -> :ok
    end
  end

  @doc false
  # The release of the handles `start/4` holds. See `Helyx.Watchdog.Group`.
  defdelegate release(handles, mode, deadline, opts \\ []), to: Helyx.Watchdog.Group

  @doc false
  # Public for the watchdog's direct tests. `feed` is the input byte count,
  # -1 for none, or -2 for open input (see the watchdog). `grace_ms` is the
  # TERM grace when the port closes.
  def launcher(argv, cwd, nonce, feed, grace_ms \\ @grace_ms) do
    perl = System.find_executable("perl")
    # ponytail: the VM decodes a name or a value that is not UTF-8 as
    # Latin-1. Such a `PERL*` value reaches the command with other bytes,
    # and such a name is not removed. Raw bytes need another transport, if
    # a user has such a variable.
    perl_env =
      for {"PERL" <> _ = name, _value} = variable <- System.get_env(),
          name != "PERL_BADLANG",
          do: variable

    unset = for {name, _value} <- perl_env, do: {String.to_charlist(name), false}

    keep =
      for {name, value} <- perl_env,
          do: {String.to_charlist("HELYX_KEEP_" <> name), String.to_charlist("=" <> value)}

    # No cd option: the watchdog enters `cwd`, so a failure has a signal.
    {perl,
     [
       :binary,
       :exit_status,
       :stderr_to_stdout,
       {:env, unset ++ keep},
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

  # The input follows the go-ahead as a later write (see `go_ahead/2`).
  defp write_input(port, input) when is_binary(input), do: write(port, input)
  defp write_input(_port, _input), do: :ok

  defp feed(nil), do: -1
  defp feed(:open), do: -2
  defp feed(input), do: byte_size(input)

  @doc false
  # Writes to the watchdog's stdin. A port whose watchdog already died is
  # closed and the write raises; the exit status is still in the mailbox for
  # the caller's read. A watchdog that died while the port is open makes
  # the write close the port with `:epipe`: the go-ahead handles that, and
  # the harness providers' read loops handle a later write (#167).
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
