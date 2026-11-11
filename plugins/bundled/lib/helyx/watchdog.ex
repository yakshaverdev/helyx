defmodule Helyx.Watchdog do
  @moduledoc false
  # Runs a program in its own process group under a perl watchdog, and
  # releases the groups. The bash tool and, through `Helyx.HarnessIO`, the
  # harness providers share it; it is not a plugin, and no plugin calls
  # another (ADR 0005).

  # `watchdog/watchdog.pl` owns the protocol: the marker before the
  # go-ahead, the input modes, the grace, the reap, and the select tick.
  # ADR 0004 and `docs/features/tool-resource-release.md` own the reasons.
  # The nonce of the marker is random for each call and reaches the program
  # in its arguments only, so command output cannot pass for a marker.
  alias Helyx.Watchdog.Mask

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

  # The longest reason of a start that failed: an error line of a program
  # with room for context. It goes into a terminal error of the harness
  # providers and into the bash tool's error, and `Helyx.HarnessIO` cuts
  # program error text to it too. perl's warnings quote the environment as
  # raw bytes, so the cut also drops invalid bytes.
  @reason_max_bytes 2_000

  @doc false
  def reason_max_bytes, do: @reason_max_bytes

  @doc false
  # Opens the port for `argv` in `cwd` and runs the handshake. With `input`
  # nil the command's stdin is /dev/null. With `:open` the command reads
  # what `write/2` sends until `write(port, <<0>>)` or the close. Returns:
  #
  #   * `{:started, port, pre, handles}`: the go-ahead is sent. `pre` is
  #     what came before the marker, perl's own startup output. `handles`
  #     are the handles held with `Helyx.Tool.hold/1`, for a caller that
  #     releases the groups itself (the bash tool at its time limit).
  #   * `{:error, reason}`: no command ran and the port is closed. `reason`
  #     is valid UTF-8 of at most `@reason_max_bytes`.
  #
  # Only a group marker leads to the go-ahead, after the group is held: a
  # command never runs without its group in the hands.
  #
  # The option `:grace_ms` (default #{@grace_ms}) is the wait between the
  # TERM and the KILL of the command group when the port closes, or when
  # open input that the command has not read is over
  # `@stdin_max_bytes`. The option `:env` (default `[]`) is the name and
  # value pairs, valid UTF-8, that the port adds to the inherited
  # environment, and `:unset` (default `[]`) the names that it removes from
  # it. Neither a crash report nor the `reason` of an error shows a value
  # (docs/features/harness-no-state.md).
  #
  # The option `:deadline` (default none) is an absolute
  # `System.monotonic_time(:millisecond)`; past it the start returns
  # `{:error, @late}` (`docs/features/mcp-client.md`). The option
  # `:watchdog_exe`, for tests only, runs that program in place of perl.
  def start(argv, cwd, input, opts \\ []) do
    nonce = random_word()
    grace = Keyword.get(opts, :grace_ms, @grace_ms)
    env = Keyword.get(opts, :env, [])
    unset = for name <- Keyword.get(opts, :unset, []), do: {to_charlist(name), false}
    {exe, options} = launcher(argv, cwd, nonce, feed(input), grace)
    exe = Keyword.get(opts, :watchdog_exe, exe)
    env = for({name, value} <- env, do: {to_charlist(name), chars(value)})
    options = [{:env, unset ++ env} | options]
    port = Helyx.Reason.no_args(fn -> Port.open({:spawn_executable, exe}, options) end)
    values = opts |> Keyword.get(:env, []) |> Enum.map(&elem(&1, 1)) |> Enum.uniq()
    handshake(port, nonce, values, Keyword.get(opts, :deadline))
  end

  @late "the perl watchdog gave no marker before the deadline"

  # The port writes a charlist in the native name encoding of the BEAM.
  # With latin1, the BEAM of a locale that is not UTF-8, each byte of the
  # value is one character, so the program gets the UTF-8 bytes in both.
  defp chars(value) do
    if :file.native_name_encoding() == :utf8,
      do: String.to_charlist(value),
      else: :binary.bin_to_list(value)
  end

  defp handshake(port, nonce, values, deadline) do
    # The runtime detaches port programs into their own process group, so
    # the port's OS pid is the watchdog's group. Held as :watchdog: the
    # release waits for it, so an abort cannot return while the command is
    # a zombie, and KILLs it only after the command group is gone, so a
    # KILL can never cut the reap short.
    watchdog =
      case Port.info(port, :os_pid) do
        {:os_pid, os_pid} ->
          handle = {:watchdog, os_pid, Helyx.Watchdog.Group.record()}
          Helyx.Tool.hold(handle)
          [handle]

        nil ->
          []
      end

    case read_marker(port, nonce, "", "", deadline) do
      :deadline ->
        let_go(port, watchdog)
        {:error, @late}

      {:not_started, acc} ->
        case read_to_exit(port, acc, deadline) do
          :deadline ->
            let_go(port, watchdog)
            {:error, @late}

          reason ->
            let_go(port, watchdog)
            {:error, Helyx.Text.cap(Mask.mask(reason, values), @reason_max_bytes, :tail)}
        end

      # Names the watchdog, not a cause: perl may be gone, fail to compile
      # the watchdog, or never run (an argv over the OS limit).
      {:no_marker, text} ->
        let_go(port, watchdog)
        reason = "the perl watchdog gave no marker: " <> preamble(text, values)
        {:error, Helyx.Text.cap(reason, @reason_max_bytes, :head)}

      {group, pre} ->
        handle = {:command, group, Helyx.Watchdog.Group.record()}
        Helyx.Tool.hold(handle)
        go(port, pre, [handle | watchdog], deadline)
    end
  end

  # The hold of the command group can wait behind the releases of the
  # hands: past the deadline the go-ahead is not written, so the command
  # never runs, and the hands release both groups at the end of the caller.
  defp go(port, pre, handles, deadline) do
    if deadline != nil and System.monotonic_time(:millisecond) >= deadline do
      close(port)
      {:error, @late}
    else
      # A port that closed already drops the write; its exit status is in
      # the mailbox for the caller's read.
      write(port, "\n")
      {:started, port, pre, handles}
    end
  end

  # The wait for the watchdog of a failed start to be gone, after the close
  # of its port: one that read to its exit is gone at the first probe, and
  # one that still runs ends at the end of its stdin. No kill(1) run starts
  # at or after it, and a run has no timeout of its own.
  @gone_ms 100

  # A failed start returns no handles, so it drops the watchdog hold itself
  # once the release confirms the watchdog gone (#802,
  # `docs/features/tool-resource-release.md`). One not gone by then stays
  # held for the release of the hands.
  defp let_go(port, watchdog) do
    close(port)
    gone = watchdog -- release(watchdog)
    if gone != [], do: Helyx.Tool.unhold(gone)
  end

  defp release(watchdog) do
    Helyx.Watchdog.Group.release(
      watchdog,
      :deliver,
      System.monotonic_time(:millisecond) + @gone_ms
    )
  rescue
    # A kill(1) that cannot run, such as one not on PATH, confirms nothing,
    # as a raise in the release of the hands, and the start keeps its reason.
    ErlangError -> watchdog
  end

  # The marker's chunk can hold only the head of the reason: the port cuts
  # the stream where a pipe read ends, on macOS at 512 bytes (#340). The
  # watchdog writes the reason in one write, at most an error text with
  # `cwd` in it, and exits right after it, so the exit status ends the read.
  defp read_to_exit(port, acc, deadline) do
    receive do
      {^port, {:data, data}} -> read_to_exit(port, acc <> data, deadline)
      {^port, {:exit_status, _status}} -> acc
    after
      wait_ms(deadline) -> :deadline
    end
  end

  # The time left to `deadline`, or `:infinity` with none.
  defp wait_ms(nil), do: :infinity
  defp wait_ms(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)

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
  # the write close the port with `:epipe`, and that exit signal ends the
  # port's linked caller (#390).
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
  # output. Returns the group (or `:not_started`, see the watchdog) and the
  # output so far, or `:no_marker` with the text read. Only
  # a line that ends within the limit counts, marker or not, so which
  # marker is found, if any, does not depend on how the stream is cut into
  # messages.
  @doc false
  # Public for the direct test of the preamble limit.
  def read_marker(port, nonce, pre, acc, deadline \\ nil) do
    case String.split(acc, "\n", parts: 2) do
      [line, rest] when byte_size(pre) + byte_size(line) < @max_preamble_bytes ->
        case parse_marker(line, nonce) do
          nil -> read_marker(port, nonce, pre <> line <> "\n", rest, deadline)
          marker -> {marker, pre <> rest}
        end

      [_] when byte_size(pre) + byte_size(acc) < @max_preamble_bytes ->
        receive do
          {^port, {:data, data}} -> read_marker(port, nonce, pre, acc <> data, deadline)
          {^port, {:exit_status, _status}} -> {:no_marker, pre <> acc}
        after
          wait_ms(deadline) -> :deadline
        end

      _ ->
        {:no_marker, pre <> acc}
    end
  end

  # The `:no_marker` text, masked. Only a read that reached the limit gives
  # a text of `@max_preamble_bytes` or more, and it can end in a part of a
  # value, which no mask finds: with `:env`, such a text is not shown.
  defp preamble(text, [_ | _]) when byte_size(text) >= @max_preamble_bytes,
    do: "perl wrote #{@max_preamble_bytes} bytes or more, not shown"

  defp preamble(text, values), do: Mask.mask(text, values)

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
