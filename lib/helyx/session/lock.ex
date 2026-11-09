defmodule Helyx.Session.Lock do
  @moduledoc false
  # The writer lock of a file, a session file for the session server
  # (docs/features/session-lock.md): a `flock` on `<id>.lock` next to
  # `<id>.jsonl`, held by a perl program on a port. The session server
  # takes it with `hold/2` at its start, so it owns the port from its open,
  # and releases it at its stop (`release/1`). When the owner of the port
  # ends, the port closes, perl reads the end of its stdin and exits, and
  # the kernel releases the lock.

  # The program writes "<nonce> ok", "<nonce> locked", or
  # "<nonce> error <reason>" as one line. With the lock, it then reads
  # commands on stdin until a byte that is no command or the end of stdin,
  # and exits: `w` writes a file, `r` removes one, `m` renames one
  # (`write_file/3`, `remove_file/2`, `rename_file/3`); `c` makes a copy
  # file, `a` appends to it, and `k` sets its mode and closes it
  # (`create_copy/2`, `append_copy/2`, `close_copy/2`); and each gets the
  # line "done" or "fail <reason>". The release sends `x`. The nonce
  # reaches it in its arguments only, so no startup warning of perl, which
  # stderr merges in, passes for the answer; perl runs with no warnings
  # after that. `%!` loads Errno. The open does not wait (a FIFO with no
  # reader fails), and a file that is not regular is refused, so perl
  # never blocks before it reads stdin. The temporary file of a write is
  # removed first, then made with `O_EXCL|O_NOFOLLOW` and mode 0600, so no
  # other file or link is written through.
  @program ~S"""
  use Fcntl qw(:DEFAULT :flock);
  my ($nonce, $path) = @ARGV;
  $| = 1;
  sysopen(my $fh, $path, O_WRONLY | O_APPEND | O_CREAT | O_NONBLOCK)
    or do { print "$nonce error $!\n"; exit 0 };
  -f $fh or do { print "$nonce error not a regular file\n"; exit 0 };
  if (!flock($fh, LOCK_EX | LOCK_NB)) {
    print($!{EWOULDBLOCK} ? "$nonce locked\n" : "$nonce error $!\n");
    exit 0;
  }
  print "$nonce ok\n";
  sub take {
    my ($n, $buf) = (shift, '');
    while (length($buf) < $n) {
      sysread(STDIN, $buf, $n - length($buf), length($buf)) or exit 0;
    }
    $buf;
  }
  sub field { take(unpack('N', take(4))) }
  my $copy;
  while (sysread(STDIN, my $op, 1)) {
    if ($op eq 'c') {
      my $file = field();
      close($copy) if $copy;
      unlink($file);
      my $ok = sysopen($copy, $file, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0600)
        && chmod(0600, $copy);
      my $error = "$!";
      undef $copy unless $ok;
      print($ok ? "done\n" : "fail $error\n");
    } elsif ($op eq 'a') {
      my $data = field();
      my ($ok, $at) = (defined($copy), 0);
      while ($ok && $at < length($data)) {
        my $n = syswrite($copy, $data, length($data) - $at, $at);
        $ok = defined($n) && $n > 0;
        $at += $n if $ok;
      }
      print($ok ? "done\n" : defined($copy) ? "fail $!\n" : "fail no copy\n");
    } elsif ($op eq 'k') {
      my $mode = unpack('N', take(4));
      my $ok = defined($copy) && chmod($mode, $copy) && close($copy);
      my $error = defined($copy) ? "$!" : "no copy";
      undef $copy;
      print($ok ? "done\n" : "fail $error\n");
    } elsif ($op eq 'r') {
      my $file = field();
      print(unlink($file) || $!{ENOENT} ? "done\n" : "fail $!\n");
    } elsif ($op eq 'm') {
      my ($from, $to) = (field(), field());
      print(rename($from, $to) ? "done\n" : "fail $!\n");
    } elsif ($op eq 'w') {
      my ($file, $data) = (field(), field());
      my $tmp = "$file.tmp";
      unlink($tmp);
      my $out;
      my $ok = sysopen($out, $tmp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0600)
        && chmod(0600, $out)
        && (syswrite($out, $data) // -1) == length($data)
        && close($out)
        && rename($tmp, $file);
      my $error = "$!";
      unlink($tmp) unless $ok;
      print($ok ? "done\n" : "fail $error\n");
    } else {
      exit 0;
    }
  }
  """

  # perl answers in a few ms; the rest is the margin for load.
  @reply_ms 5_000
  # The output before the answer line, such as a locale warning of about
  # 400 bytes.
  @max_output_bytes 4096
  # The wait for perl's exit at a release: it exits on the byte at once.
  @release_ms 1_000

  def release_ms, do: @release_ms

  # Takes the lock of the session file `path`, then runs `fun`, which writes
  # the file. Returns `{:ok, lock, result}` for `{:ok, result}` of `fun`.
  # perl can end while `fun` runs, a resume read for example: the port then
  # sends its exit to the owner, which handles it as a lock lost while the
  # session runs (session-lock.md). Any other return of `fun` releases the
  # lock and is returned. A raise, throw, or exit of `fun` goes on: the
  # owner of the port dies with it, and the port closes. The caller traps
  # exits: a perl that ends with no answer is seen at the exit of its port.
  def hold(path, fun) do
    with {:ok, lock} <- take(path) do
      case fun.() do
        {:ok, result} ->
          {:ok, lock, result}

        error ->
          release(lock)
          error
      end
    end
  end

  # Takes the lock of `<path without extension>.lock` and returns the port
  # that holds it; the caller owns the port. A product can lock a file of
  # its own with it. The folder of the lock file must exist.
  def take(path) do
    with {:ok, perl} <- find_perl() do
      nonce = Base.encode16(:crypto.strong_rand_bytes(8))

      port =
        Port.open({:spawn_executable, perl}, [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          {:line, @max_output_bytes},
          args: ["-e", @program, "--", nonce, Path.rootname(path) <> ".lock"]
        ])

      case read_answer(port, &answer(&1, nonce)) do
        :ok ->
          {:ok, port}

        :locked ->
          close(port)
          {:error, {:session_locked, Path.basename(path, ".jsonl")}}

        {:error, text} ->
          close(port)
          {:error, {:lock_failed, String.replace_invalid(text, "")}}
      end
    end
  end

  defp find_perl do
    case System.find_executable("perl") do
      nil -> {:error, {:lock_failed, "perl is not on the PATH; Helyx needs it to lock a session"}}
      perl -> {:ok, perl}
    end
  end

  defp answer(line, nonce) do
    case String.split(line, " ", parts: 3) do
      [^nonce, "ok"] -> :ok
      [^nonce, "locked"] -> :locked
      [^nonce, "error", reason] -> {:error, "cannot open the lock file: " <> reason}
      _other -> :other
    end
  end

  # Writes `path` with mode 0600 through `<path>.tmp` and a rename, in the
  # perl process that holds the lock `port`: when the lock has ended, no
  # write happens. `data` is a closure, so its text, a secret for example,
  # is in no frame and no argument but the one call that sends it. Returns
  # `:ok` or `{:error, text}`. The owner traps exits, as for `take/1`.
  def write_file(port, path, data) when is_function(data, 0),
    do: command(port, fn -> ["w", field(path), field(data.())] end)

  # Removes `path` in the perl process that holds the lock `port`; a file
  # that is not there counts as removed.
  def remove_file(port, path), do: command(port, fn -> ["r", field(path)] end)

  # Renames `from` to `to` in the perl process that holds the lock `port`,
  # so the rename happens only while the lock is held.
  def rename_file(port, from, to), do: command(port, fn -> ["m", field(from), field(to)] end)

  # Makes the file `path` new with mode 0600 in the perl process that holds
  # the lock `port`, after a remove of a file at that path, and keeps it
  # open there for `append_copy/2` and `close_copy/2`: the copy of a
  # removal (docs/features/session-edit.md). When the lock ends, perl ends,
  # so no byte is written to the copy after it. A second create closes the
  # copy before.
  def create_copy(port, path), do: command(port, fn -> ["c", field(path)] end)

  # Appends the iodata `data`, under 4 GiB, to the open copy.
  def append_copy(port, data), do: command(port, fn -> ["a", field(data)] end)

  # Sets the permission bits of `mode` on the open copy and closes it.
  def close_copy(port, mode),
    do: command(port, fn -> ["k", <<Bitwise.band(mode, 0o7777)::32>>] end)

  defp field(text), do: [<<IO.iodata_length(text)::32>>, text]

  # The command goes in one call; a port that closed with its lock gets
  # none. The answer has the bound and the deadline of the take.
  defp command(port, frame) do
    if send_bytes(port, frame) do
      with {:error, text} <- read_answer(port, &reply/1),
           do: {:error, String.replace_invalid(text, "")}
    else
      {:error, "the lock has ended"}
    end
  end

  defp reply("done"), do: :ok
  defp reply("fail " <> reason), do: {:error, reason}
  defp reply(_line), do: :other

  defp read_answer(port, parse),
    do: read_answer(port, parse, "", System.monotonic_time(:millisecond) + @reply_ms)

  # Reads lines until the answer line that `parse` knows, within the output
  # bound and the deadline. `pre` holds the output read past; it and the
  # line in hand count in the bound. The last bytes of an output with no
  # line end come after the exit status, so the read goes on to the trapped
  # exit of the port. The deadline is checked before each receive: output
  # that is queued already does not keep the read past it.
  defp read_answer(port, parse, pre, deadline) do
    case deadline - System.monotonic_time(:millisecond) do
      wait when wait > 0 ->
        receive do
          {^port, {:data, {:eol, line}}}
          when byte_size(pre) + byte_size(line) < @max_output_bytes ->
            case parse.(line) do
              :other -> read_answer(port, parse, pre <> line <> "\n", deadline)
              answer -> answer
            end

          {^port, {:data, {:noeol, part}}}
          when byte_size(pre) + byte_size(part) < @max_output_bytes ->
            read_answer(port, parse, pre <> part, deadline)

          {^port, {:data, _over}} ->
            {:error, "perl wrote #{@max_output_bytes} bytes with no answer in them"}

          {^port, {:exit_status, _}} ->
            read_answer(port, parse, pre, deadline)

          {:EXIT, ^port, _reason} ->
            {:error, "perl ended with no answer: " <> pre}
        after
          wait -> no_answer()
        end

      _past ->
        no_answer()
    end
  end

  defp no_answer, do: {:error, "perl gave no answer in #{@reply_ms} ms"}

  # Sends perl the byte that ends it and waits for its exit, so the lock is
  # free when this returns, or unconfirmed past `@release_ms`: then the port
  # closes, and perl frees it when it ends. Only the owner of the port gets its
  # exit status. The owner is the session process, which traps exits and
  # stops after this, so the messages of the port stay in its mailbox.
  def release(nil), do: :ok

  def release(port) do
    if send_bytes(port, fn -> "x" end) do
      receive do
        {^port, {:exit_status, _status}} -> :ok
      after
        @release_ms -> :ok
      end
    end

    close(port)
    :ok
  end

  # A port that closed already gets nothing. The bytes come from `frame`
  # here, and the rescue drops the stacktrace, whose top frame would hold
  # them as an argument.
  defp send_bytes(port, frame) do
    Port.command(port, frame.())
  rescue
    ArgumentError -> false
  end

  # A port that closed already is skipped.
  defp close(port) do
    Port.close(port)
  rescue
    ArgumentError -> false
  end
end
