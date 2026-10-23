defmodule Helyx.HarnessIO do
  @moduledoc false
  # What the harness providers share (ADR 0005). It is not a plugin.
  # `state` is a provider's run state with the fields `port`, `buffer`
  # (iodata), `size`, `terminal`, `closing`, `handles`, the handles that
  # the provider holds for its programs, and `env` (`env/1`).

  @line_max_bytes 16 * 1024 * 1024
  @replay_max_bytes 400_000
  # The TERM grace of the watchdog and the release: claude and codex end
  # their own commands on TERM, but a KILL leaves them running (research
  # notes).
  @term_grace_ms 5_000
  # The wait for the exit of a program that another one replaces, after
  # the end of its input. A Helyx close of Claude took 615 and 628 ms
  # (`docs/research/claude-code-stream-json.md`, "Processes"). The wait is
  # part of the 2,000 ms reply bound of the turn.
  @end_wait_ms 1_000
  # The release of the groups of a program that ended, at the launch of
  # the next one. The groups of a program that exited are gone, so the
  # release only confirms it. At a turn start it is part of the reply
  # bound; a lost-session relaunch in a turn makes the turn longer.
  @let_go_ms 500

  # The hex digits of the digest in a stored id.
  @digest_hex 16

  def line_max_bytes, do: @line_max_bytes
  def let_go_ms, do: @let_go_ms

  # The stored id of a harness session: its id, `#`, and the digest of the
  # JSON of `fixed`, what the program fixes at the start of the session and
  # keeps on a resume. A stored id with another digest is not resumed: a
  # fresh harness session starts with the replay
  # (`docs/features/provider-parity.md`, "Resume eligibility").
  def session_id(id, fixed), do: id <> "#" <> hex_digest(JSON.encode!(fixed), @digest_hex)

  def resumable(nil, _fixed), do: nil

  def resumable(stored, fixed) do
    [id | _] = String.split(stored, "#", parts: 2)
    if session_id(id, fixed) == stored, do: id
  end

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
  defp start(argv, cwd, input, state, opts) do
    state = let_go(state)

    case Helyx.Watchdog.start(argv, cwd, input, opts) do
      {:started, port, _pre, handles} ->
        %{state | port: port, handles: state.handles ++ handles}

      {:error, reason} ->
        %{state | terminal: {:error, {:not_started, reason}}}
    end
  end

  # The hands hold the handles of one program, not of every program of
  # the provider process: before a launch, the groups of the program
  # before are released, and the hands drop the handles that the release
  # confirmed. A group that is not gone by the deadline stays held, for
  # the next launch or the end of the provider process.
  defp let_go(%{handles: []} = state), do: state

  defp let_go(state) do
    left = release(state.handles, :cancel, System.monotonic_time(:millisecond) + @let_go_ms)
    gone = state.handles -- left
    if gone != [], do: Helyx.Tool.unhold(gone)
    %{state | handles: left}
  end

  # Runs `exe` with `args` under the watchdog, with open input and stderr
  # dropped. The port stays linked to the caller: a write to a watchdog
  # that died closes the port with `:epipe`, and that exit ends the caller
  # (#390). The closed port makes the watchdog end the group (ADR 0004).
  # The program gets `state.env` on top of the inherited environment.
  def launch(exe, args, cwd, state) do
    ["/bin/sh", "-c", ~S(exec "$0" "$@" 2>/dev/null), exe | args]
    |> start(cwd, :open, state, grace_ms: @term_grace_ms, env: state.env)
  end

  def stop(%{port: port}), do: Helyx.Watchdog.close(port)

  # Ends the input of a program that another one replaces and waits for its
  # exit: two programs must not run one harness session at once. A program
  # that has not exited in time is stopped, and the turn fails.
  def finish(%{port: port} = state) do
    end_input(state)

    receive do
      {^port, {:exit_status, _status}} -> :ok
    after
      @end_wait_ms ->
        stop(state)
        {:error, :program_not_ended}
    end
  end

  # Writes to the program's stdin through the watchdog.
  def write(%{port: port}, data), do: Helyx.Watchdog.write(port, data)

  # The provider's `:close`: the NUL asks the watchdog to end the program,
  # and the port's exit answers `from` (`port_message/3`).
  def close(state, from) do
    end_input(state)
    %{state | closing: from}
  end

  defp end_input(state), do: write(state, <<0>>)

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
  # `{:exit, status}` at any other time. Any other message, such as one of
  # a closed port, is `:other`. `state.closing` is the `from` of a close,
  # or nil.
  def port_message({port, {:data, data}}, %{port: port} = state, decode) do
    {events, state} = lines(data, state, decode)
    {:lines, events, state}
  end

  def port_message({port, {:exit_status, status}}, %{port: port} = state, _decode),
    do: exited(status, state)

  def port_message(_message, _state, _decode), do: :other

  defp exited(status, %{closing: nil}), do: {:exit, status}
  defp exited(_status, %{closing: from}), do: {:closed, from}

  # Reads a chunk of stdout: `decode` gets each complete line that is a
  # JSON object, and the state; other lines (perl's own text) are skipped.
  # Once the state has a terminal, output is not read. Only the new chunk
  # is searched for a newline, so a long line costs one pass over its
  # bytes. A line over the cap, with its newline in this chunk or not, ends
  # the stream with an error.
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
          case Helyx.JSON.decode(line) do
            {:ok, %{} = object} -> decode.(object, state)
            _ -> {[], state}
          end

        {more, state} = lines(rest, state, decode)
        {events ++ more, state}
    end
  end

  # The options of `init/3` that a harness provider keeps, as the fields
  # `persist?` and `env` of its state.
  def options(opts) do
    with {:ok, persist?} <- persist(opts),
         {:ok, env} <- env(opts),
         do: {:ok, persist?: persist?, env: env}
  end

  # The `:persist` option of a harness provider, true by default. A harness
  # session with no stored state cannot be resumed, so a `:resume_id` with
  # `persist: false` fails (docs/features/harness-no-state.md).
  def persist(opts) do
    case {Keyword.get(opts, :persist, true), opts[:resume_id]} do
      {false, nil} -> {:ok, false}
      {false, _id} -> {:error, :no_state_resume}
      {true, _id} -> {:ok, true}
      _other -> {:error, {:invalid_option, :persist}}
    end
  end

  # The names that the `/bin/sh` of the launch or the OS is known to set
  # itself: the POSIX shell ones, and each one that the review probes saw
  # changed by the bash of macOS, dash, bash 5.3, or macOS itself.
  @shell_names ~w(BASH BASHOPTS BASHPID BASH_ARGV0 BASH_COMMAND BASH_EXECUTION_STRING
                  BASH_MONOSECONDS BASH_SUBSHELL BASH_VERSINFO BASH_VERSION CDPATH COMP_WORDBREAKS
                  ENV EPOCHREALTIME EPOCHSECONDS HISTCMD IFS LINENO OLDPWD OPTERR OPTIND
                  POSIXLY_CORRECT PPID PS1 PS2 PS4 PWD RANDOM SHELLOPTS SHLVL SRANDOM XPC_FLAGS
                  XPC_SERVICE_NAME)

  # The `:env` option of a harness provider, `%{}` by default: the map that
  # each launch sets on top of the inherited environment, as the name and
  # value pairs of `Helyx.Watchdog.start/4`. A name is a shell identifier,
  # since dash, a `/bin/sh` of the launch, drops any other name, and not
  # one of `@shell_names`; a shell or an OS can set other names of its own.
  # A value is non-empty valid UTF-8 with no NUL: the port unsets a
  # variable with an empty value and raises for a NUL. The error names no
  # value (docs/features/harness-no-state.md).
  def env(opts) do
    with env when is_map(env) <- Keyword.get(opts, :env, %{}),
         entries = Map.to_list(env),
         true <- Enum.all?(entries, &env_entry?/1) do
      {:ok, entries}
    else
      _other -> {:error, {:invalid_option, :env}}
    end
  end

  defp env_entry?({name, value}) do
    is_binary(name) and name =~ ~r/\A[A-Za-z_][A-Za-z0-9_]*\z/ and name not in @shell_names and
      is_binary(value) and value != "" and String.valid?(value) and
      not String.contains?(value, <<0>>)
  end

  # A compaction in a program with no history yet: the replay of the
  # transcript comes only with its first turn
  # (docs/features/harness-compaction.md).
  def no_history(provider), do: compaction_failed(provider, "no history in the program yet")

  def compaction_failed(provider, text),
    do: {:error, %Helyx.ProviderError{provider: provider, kind: :compaction_failed, text: text}}

  # The prompt is the user messages at the end of the transcript; the
  # history is the rest. Both keep their order.
  def split_prompt(messages) do
    {prompt, history} = messages |> Enum.reverse() |> Enum.split_while(&(&1.role == :user))
    {Enum.reverse(prompt), Enum.reverse(history)}
  end

  # Encodes entries from the newest and keeps them within the byte cap,
  # then drops kept entries up to the first one the replay may start at.
  # An entry is {group, messages, start?}; `encode` gives a group's iodata
  # or false. Returns {group, iodata} for each kept iodata, oldest first,
  # and the number of messages left out of `total`.
  def cap_replay(entries, total, encode) do
    {kept, _bytes} =
      entries
      |> Enum.reverse()
      |> Enum.reduce_while({[], 0}, fn {group, n, start?}, {kept, bytes} ->
        data = encode.(group)
        bytes = bytes + if(data, do: IO.iodata_length(data), else: 0)

        if bytes > @replay_max_bytes,
          do: {:halt, {kept, bytes}},
          else: {:cont, {[{group, data, n, start?} | kept], bytes}}
      end)

    kept = Enum.drop_while(kept, fn {_group, _data, _n, start?} -> not start? end)

    {for({group, data, _n, _start?} <- kept, data, do: {group, data}),
     total - Enum.sum(for {_, _, n, _} <- kept, do: n)}
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
