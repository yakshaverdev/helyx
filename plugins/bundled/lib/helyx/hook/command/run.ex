defmodule Helyx.Hook.Command.Run do
  @moduledoc false
  # The run of the command of `Helyx.Hook.Command`
  # (docs/features/command-hook.md): `bash -c <command>` under the perl
  # watchdog (`Helyx.Watchdog`), in its own process group that the hook
  # Task holds before the command runs, with `input` on standard input and
  # then end of file.
  #
  # The watchdog merges standard error into its port, so the relay
  # (`relay.pl`) runs the command with a pipe for each stream and writes
  # each read to the port as a frame: a tag byte, `o` or `e`, the length
  # in four bytes, and at most `@max_frame_bytes` of data, its first
  # argument. It reads at most 16 times from a pipe before it checks the
  # command again, and when the command exits, it reads at most 16 more
  # times from each pipe, what the pipes hold, and exits with the
  # command's status, 128 plus the signal for a signal death. So the
  # answer is what the command wrote before it exited: a child that the
  # command left with a pipe open does not hold the hook, and what it
  # writes later is not read; the release of the hands releases it. The
  # relay's own standard error is /dev/null, so its startup warnings
  # cannot break the frames.
  #
  # The relay is in the command's group and is the command's reaper, as
  # the watchdog is the relay's: it ignores TERM, HUP, and SIGPIPE, so the
  # TERM of a release or of the watchdog reaches the command, which has
  # its grace, and the relay reaps it and exits after it. The relay sets
  # TERM and HUP to their default action at its start, also when Helyx
  # runs with one ignored, and blocks them across its fork, so the command
  # starts with the defaults, and the relay sends one that came while they
  # were blocked on to the command. Once the port is gone, a failed write
  # drops the rest of the output. Only a KILL ends the relay first, as it
  # ends any parent in the group.
  #
  # The read has no deadline of its own: the hands kill the hook Task at
  # its limit, the port closes with it, and the watchdog stops the group.

  @relay_path Path.join(__DIR__, "relay.pl")
  @external_resource @relay_path
  @relay File.read!(@relay_path)

  # The bytes kept of each stream: four times the result bound, so a
  # reason at that bound fits with JSON escapes.
  @max_output_bytes 4 * Helyx.Message.max_result_bytes()
  # The most data of one frame: the relay reads at most this much.
  @max_frame_bytes 65_536

  @relay_argv ["-e", @relay, "--", Integer.to_string(@max_frame_bytes)]

  def max_output_bytes, do: @max_output_bytes
  def max_frame_bytes, do: @max_frame_bytes

  defmodule Out do
    @moduledoc false
    # The kept head of each stream, whether bytes of standard output were
    # dropped, and the part of a frame that the next read completes.
    defstruct stdout: "", stdout_cut?: false, stderr: "", buffer: ""
  end

  # Returns `{:exit, status, stdout, stdout_cut?, stderr}`,
  # `{:not_started, reason}`, or `:unreadable` for a port stream that is
  # not frames.
  def run(input, command, cwd) do
    with {:ok, perl} <- find_perl(),
         bash = System.find_executable("bash") || "/bin/bash",
         argv = ["/bin/sh", "-c", ~S(exec "$0" "$@" 2>/dev/null), perl | @relay_argv],
         {:started, port, _pre, _handles} <-
           Helyx.Watchdog.start(argv ++ [bash, "-c", command], cwd, :open) do
      # JSON holds no raw NUL, so the NUL ends the input (`Helyx.Watchdog`).
      Helyx.Watchdog.write(port, [input, <<0>>])
      collect(port, %Out{})
    else
      {:error, reason} -> {:not_started, reason}
    end
  end

  # `Helyx.Watchdog.start/4` needs perl; the hook has no `check/0` that
  # reports it at the start of a session, as the bash tool has.
  defp find_perl do
    case System.find_executable("perl") do
      nil -> {:error, "perl not found: the command runs under a perl watchdog"}
      perl -> {:ok, perl}
    end
  end

  @doc false
  # Reads the frames of `port` to its exit status. Public for the direct
  # test of a stream that is not frames.
  def collect(port, out) do
    receive do
      {^port, {:data, data}} ->
        case frames(out.buffer <> data, out) do
          {:ok, out} -> collect(port, out)
          :error -> :unreadable
        end

      {^port, {:exit_status, status}} when out.buffer == "" ->
        {:exit, status, out.stdout, out.stdout_cut?, out.stderr}

      {^port, {:exit_status, _status}} ->
        :unreadable
    end
  end

  @doc false
  # Takes each whole frame from `buffer` and keeps the rest, at most one
  # frame, for the next read: `{:ok, out}`, or `:error` for bytes that are
  # no frame. Public for its direct test: only the relay writes the stream.
  def frames(<<tag, size::32, rest::binary>> = buffer, out)
      when tag in [?o, ?e] and size <= @max_frame_bytes do
    case rest do
      <<data::binary-size(size), rest::binary>> -> frames(rest, keep(out, tag, data))
      _part -> {:ok, %{out | buffer: buffer}}
    end
  end

  def frames(<<_head::binary-size(5), _rest::binary>>, _out), do: :error
  def frames(<<tag, _rest::binary>>, _out) when tag not in [?o, ?e], do: :error
  def frames(buffer, out), do: {:ok, %{out | buffer: buffer}}

  # The head of each stream up to `@max_output_bytes`; the rest is dropped.
  defp keep(out, ?o, data) do
    cut? = byte_size(out.stdout) + byte_size(data) > @max_output_bytes
    %{out | stdout: head(out.stdout, data), stdout_cut?: out.stdout_cut? or cut?}
  end

  defp keep(out, ?e, data), do: %{out | stderr: head(out.stderr, data)}

  defp head(kept, data) do
    room = @max_output_bytes - byte_size(kept)
    kept <> binary_part(data, 0, min(room, byte_size(data)))
  end
end
