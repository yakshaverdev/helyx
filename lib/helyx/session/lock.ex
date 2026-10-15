defmodule Helyx.Session.Lock do
  @moduledoc false
  # The writer lock of a session file (docs/features/session-lock.md): a
  # `flock` on `<id>.lock` next to `<id>.jsonl`, held by a perl program on a
  # port. The session server takes it with `hold/2` in its init, so it owns
  # the port from its open, and releases it at its stop (`release/1`). When
  # the owner of the port ends, the port closes, perl reads the end of its
  # stdin and exits, and the kernel releases the lock.

  # The program writes "<nonce> ok", "<nonce> locked", or
  # "<nonce> error <reason>" as one line, then waits for one byte or the end
  # of its stdin and exits. The nonce reaches it in its arguments only, so
  # no startup warning of perl, which stderr merges in, passes for the
  # answer. `%!` loads Errno. The open does not wait (a FIFO with no reader
  # fails), and a file that is not regular is refused, so perl never blocks
  # before it reads stdin.
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
  sysread(STDIN, my $byte, 1);
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
  # the file. Returns `{:ok, lock, result}` for `{:ok, result}` of `fun`, or
  # a `:lock_failed` error when the port has closed by then.
  # Any other return of `fun` releases the lock and is returned; a raise,
  # throw, or exit of `fun` releases it and goes on.
  def hold(path, fun) do
    with {:ok, lock} <- take(path) do
      case run(lock, fun) do
        {:ok, result} ->
          held(lock, result)

        error ->
          release(lock)
          error
      end
    end
  end

  # perl can end while `fun` runs, a resume read for example: the lock is
  # gone, and no client is subscribed yet to see the notice of a lost lock.
  # The port closes some ms after perl ends, so a perl that ends right before
  # this check, or after it and before the first subscribe, sends its notice
  # to no client; the snapshot tells a later client (`lock_lost`,
  # session-lock.md).
  defp held(lock, result) do
    if Port.info(lock) do
      {:ok, lock, result}
    else
      close(lock)
      {:error, {:lock_failed, "the lock ended before the session started"}}
    end
  end

  defp run(lock, fun) do
    fun.()
  catch
    kind, reason ->
      release(lock)
      :erlang.raise(kind, reason, __STACKTRACE__)
  end

  defp take(path) do
    with :ok <- mkdir(Path.dirname(path)),
         {:ok, perl} <- find_perl() do
      nonce = Base.encode16(:crypto.strong_rand_bytes(8))

      port =
        Port.open({:spawn_executable, perl}, [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          args: ["-e", @program, "--", nonce, Path.rootname(path) <> ".lock"]
        ])

      deadline = System.monotonic_time(:millisecond) + @reply_ms

      case read_answer(port, nonce, "", "", deadline) do
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

  defp mkdir(dir) do
    case File.mkdir_p(dir) do
      :ok -> :ok
      {:error, reason} -> {:error, {:create_failed, reason}}
    end
  end

  defp find_perl do
    case System.find_executable("perl") do
      nil -> {:error, {:lock_failed, "perl is not on the PATH; Helyx needs it to lock a session"}}
      perl -> {:ok, perl}
    end
  end

  # Reads whole lines until the answer line, within the output bound and
  # the deadline. `pre` holds the lines read past.
  defp read_answer(port, nonce, pre, acc, deadline) do
    case String.split(acc, "\n", parts: 2) do
      [line, rest] when byte_size(pre) + byte_size(line) < @max_output_bytes ->
        case String.split(line, " ", parts: 3) do
          [^nonce, "ok"] -> :ok
          [^nonce, "locked"] -> :locked
          [^nonce, "error", reason] -> {:error, "cannot open the lock file: " <> reason}
          _other -> read_answer(port, nonce, pre <> line <> "\n", rest, deadline)
        end

      [_part] when byte_size(pre) + byte_size(acc) < @max_output_bytes ->
        read_more(port, nonce, pre, acc, deadline)

      # The answer line counts in the bound too.
      _over ->
        {:error, "perl wrote #{@max_output_bytes} bytes with no answer in them"}
    end
  end

  # The deadline is checked before each receive: output that is queued
  # already does not keep the read past it.
  defp read_more(port, nonce, pre, acc, deadline) do
    case deadline - System.monotonic_time(:millisecond) do
      wait when wait > 0 ->
        receive do
          {^port, {:data, data}} -> read_answer(port, nonce, pre, acc <> data, deadline)
          {^port, {:exit_status, _}} -> {:error, "perl ended with no answer: " <> pre <> acc}
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
  # exit status. The unlink comes first: a write to a port whose perl died
  # closes it with `:epipe`, an exit signal that would end the caller. A
  # message or an exit of the port that came before the unlink is dropped.
  def release(nil), do: :ok

  def release(port) do
    Process.unlink(port)
    flush(port)

    if write(port) do
      receive do
        {^port, {:exit_status, _status}} -> :ok
      after
        @release_ms -> :ok
      end
    end

    close(port)
  end

  defp write(port) do
    Port.command(port, "x")
  rescue
    ArgumentError -> false
  end

  # A port that closed already is skipped. The close is synchronous, so
  # after it only the messages already sent are left, and they are dropped.
  defp close(port) do
    Process.unlink(port)

    try do
      Port.close(port)
    rescue
      ArgumentError -> false
    end

    flush(port)
  end

  defp flush(port) do
    receive do
      {^port, _message} -> flush(port)
      {:EXIT, ^port, _reason} -> flush(port)
    after
      0 -> :ok
    end
  end
end
