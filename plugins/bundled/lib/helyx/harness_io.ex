defmodule Helyx.HarnessIO do
  @moduledoc false
  # What the harness providers share (ADR 0005): every call into
  # `Helyx.Watchdog`, the move of the port's link to a keeper, the read
  # of a program's stdout as JSON lines under a line cap, the sort of a
  # port message, the release, the cut of program error text, the split of
  # the prompt from the history, the byte cap of a replay, the wire id of
  # a replayed tool call, and the close. It is not a plugin. `state` is
  # a provider's run state with the fields `port`, `buffer` (iodata),
  # `size`, `terminal`, and `closing`.

  @line_max_bytes 16 * 1024 * 1024
  # The longest program error text that goes into a terminal error or a
  # notice: the notice bound of Core.
  @error_max_bytes Helyx.Provider.max_notice_bytes()
  @replay_max_bytes 400_000
  # The TERM grace of the watchdog and the release: claude and codex end
  # their own commands on TERM, but a KILL leaves them running (research
  # notes).
  @term_grace_ms 5_000

  def line_max_bytes, do: @line_max_bytes
  def term_grace_ms, do: @term_grace_ms
  def replay_max_bytes, do: @replay_max_bytes

  # The lookup of the harness program, with the check for perl: the
  # watchdog needs perl, so without it the error names perl, not the exit
  # of a run that never started.
  def find(program) do
    case {System.find_executable(program), System.find_executable("perl")} do
      {nil, _} -> {:error, program <> " not found on PATH"}
      {_, nil} -> {:error, "perl not found on PATH: #{program} runs under a perl watchdog"}
      {exe, _} -> {:ok, exe}
    end
  end

  # Runs `argv` under the watchdog with `input` and puts the port in the
  # state. What came before the marker is perl's own output: the program
  # runs only after the go-ahead. A program that did not start gives the
  # terminal error.
  def start(argv, cwd, input, state, opts \\ []) do
    case Helyx.Watchdog.start(argv, cwd, input, opts) do
      {:started, port, _pre} ->
        %{state | port: port}

      {:error, reason} ->
        %{state | terminal: {:error, {:not_started, reason}}}
    end
  end

  # Runs `exe` with `args` under the watchdog, with open input and stderr
  # dropped, and moves the port's link to a keeper (`keep_port/1`).
  def launch(exe, args, cwd, state) do
    ["/bin/sh", "-c", ~S(exec "$0" "$@" 2>/dev/null), exe | args]
    |> start(cwd, :open, state, grace_ms: @term_grace_ms)
    |> keep_port()
  end

  # Moves the caller's link to the port to a keeper process, and monitors
  # the port instead (#167). A write to a watchdog that died closes the port
  # with `:epipe` and sends no exit status; through a link, that exit would
  # end the caller. The monitor gives it as `{:DOWN, _, :port, port,
  # reason}`, after the port's data. The keeper traps exits and is linked to
  # the caller and to the port: when the caller ends, it closes the port, so
  # the watchdog still ends the group (ADR 0004); when the port closes, it
  # ends. The caller unlinks only after the keeper holds its link, so the
  # port always has a link to a process that closes it. The caller does not
  # trap exits, so a shutdown ends it at once in every phase. Call it after
  # `start/5` and before any other write: no write is pending until then.
  def keep_port(%{port: nil} = state), do: state

  def keep_port(%{port: port} = state) do
    caller = self()

    keeper =
      spawn_link(fn ->
        Process.flag(:trap_exit, true)
        Process.link(port)
        send(caller, {:kept, self()})

        receive do
          {:EXIT, _from, _reason} -> Helyx.Watchdog.close(port)
        end
      end)

    receive do
      {:kept, ^keeper} -> :ok
    end

    Process.unlink(port)
    Port.monitor(port)
    state
  end

  # The `Stream.resource/3` end: the closed port ends the program.
  def stop(%{port: nil}), do: :ok
  def stop(%{port: port}), do: Helyx.Watchdog.close(port)

  # Writes to the program's stdin through the watchdog.
  def write(%{port: port}, data), do: Helyx.Watchdog.write(port, data)

  # The provider's `:close`: the NUL asks the watchdog to end the program,
  # and the port's exit answers `from` (`port_message/3`).
  def close(state, from) do
    write(state, <<0>>)
    %{state | closing: from}
  end

  # The provider's `release/3`. See `Helyx.Watchdog.Group`. A delivery
  # TERMs first too: the provider process can end (an error answer, a line
  # over the cap, a stop) while the program still runs a command, and a
  # KILL would leave the command running.
  def release(handles, :deliver, deadline), do: release(handles, :cancel, deadline)

  def release(handles, mode, deadline),
    do: Helyx.Watchdog.Group.release(handles, mode, deadline, grace_ms: @term_grace_ms)

  # Sorts a message for the provider process: a chunk of the port's stdout
  # gives `{:lines, events, state}` (see `lines/3`). The port's exit gives
  # `{:closed, from}` during a close, the end the close waits for, and
  # `{:exit, status_or_reason}` at any other time. A write to a watchdog
  # that died closes the port with `:epipe` and no exit status (#167), so
  # the port's `:DOWN` is an exit too. Any other message, such as one of a
  # closed port, is `:other`. `state.closing` is the `from` of a close, or
  # nil.
  def port_message({port, {:data, data}}, %{port: port} = state, decode) do
    {events, state} = lines(data, state, decode)
    {:lines, events, state}
  end

  def port_message({port, {:exit_status, status}}, %{port: port} = state, _decode),
    do: exited(status, state)

  def port_message({:DOWN, _ref, :port, port, reason}, %{port: port} = state, _decode),
    do: exited(reason, state)

  def port_message(_message, _state, _decode), do: :other

  defp exited(status, %{closing: nil}), do: {:exit, status}
  defp exited(_status, %{closing: from}), do: {:closed, from}

  # Reads a chunk of stdout: `decode` gets each complete line that is a
  # JSON object, and the state; other lines (perl's own text) are skipped.
  # Once the state has a terminal, output is not read. Only the new chunk is searched for a newline, so a long line
  # costs one pass over its bytes. A line over the cap, with its newline in
  # this chunk or not, ends the stream with an error.
  def lines(_data, %{terminal: terminal} = state, _decode) when terminal != nil, do: {[], state}

  def lines(data, state, decode) do
    case :binary.split(data, "\n") do
      [part | _] when state.size + byte_size(part) > @line_max_bytes ->
        {[], %{state | terminal: {:error, {:line_over_limit, @line_max_bytes}}}}

      [part] ->
        {[], %{state | buffer: [state.buffer, part], size: state.size + byte_size(part)}}

      [part, rest] ->
        line = IO.iodata_to_binary([state.buffer, part])
        state = %{state | buffer: [], size: 0}

        {events, state} =
          case JSON.decode(line) do
            {:ok, %{} = object} -> decode.(object, state)
            _ -> {[], state}
          end

        {more, state} = lines(rest, state, decode)
        {events ++ more, state}
    end
  end

  # A value that is not text is empty. The text is cut at the cap to valid
  # UTF-8 (`Helyx.Text.cap/3`).
  def cap_error(text) when not is_binary(text), do: ""
  def cap_error(text), do: Helyx.Text.cap(text, @error_max_bytes, :head)

  # The prompt is the user messages at the end of the transcript; the
  # history is the rest. Both keep their order.
  def split_prompt(messages) do
    {prompt, history} = messages |> Enum.reverse() |> Enum.split_while(&(&1.role == :user))
    {Enum.reverse(prompt), Enum.reverse(history)}
  end

  # Keeps the newest entries within the byte cap, then drops kept entries
  # up to the first one the replay may start at. An entry is {iodata or
  # false, messages, start?}. Returns the kept iodata and the number of
  # messages left out of `total`.
  def cap_replay(entries, total) do
    {kept, _bytes} =
      entries
      |> Enum.reverse()
      |> Enum.reduce_while({[], 0}, fn {data, _n, _start?} = entry, {kept, bytes} ->
        bytes = bytes + if(data, do: IO.iodata_length(data), else: 0)

        if bytes > @replay_max_bytes,
          do: {:halt, {kept, bytes}},
          else: {:cont, {[entry | kept], bytes}}
      end)

    kept = Enum.drop_while(kept, fn {_data, _n, start?} -> not start? end)

    {for({data, _n, _start?} <- kept, data, do: data),
     total - Enum.sum(for {_, n, _} <- kept, do: n)}
  end

  # The model APIs take a tool call id of `[a-zA-Z0-9_-]`, at most 64
  # characters; another provider's id can be longer or have other
  # characters. Such an id becomes a digest, the same for a call and its
  # result, so two ids stay two.
  def wire_id(id) do
    if id =~ ~r/\A[a-zA-Z0-9_-]{1,64}\z/,
      do: id,
      else: "h_" <> hex_digest(id, 62)
  end

  # The first `size` hex digits of the SHA-256 of `data`.
  def hex_digest(data, size),
    do: binary_part(Base.encode16(:crypto.hash(:sha256, data), case: :lower), 0, size)
end
