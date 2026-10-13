defmodule CodingAgent.Print do
  @moduledoc """
  Print mode, a client of one session: one prompt in, the final answer out
  on stdout, and an exit status. The session id, the notices, and the
  errors go to stderr. Piped stdin (stdin is not a terminal) is added to the
  prompt as a block, up to 1 MiB of UTF-8. The first SIGTERM or SIGHUP
  aborts the turn, waits at most `abort_ms/0` for the abort, and halts the
  VM with 143 or 129 and no flush, whatever stdout and stderr do. The
  design is in `docs/features/print-mode.md`.
  """

  alias Helyx.{Event, Message, Session}

  # About 250,000 tokens, more than the context window of the models Helyx
  # runs, and far under the 64 MiB of a session file.
  @max_stdin_bytes 1_048_576

  # The abort stops the provider and the tools; a turn that does not end in
  # this time is cut by the halt.
  @abort_ms 3_000

  @typedoc "The exit status that `run/2` returns; a signal halts with 129 or 143."
  @type status :: 0 | 1

  @doc "The bound of piped stdin, in bytes."
  @spec max_stdin_bytes() :: pos_integer()
  def max_stdin_bytes, do: @max_stdin_bytes

  @doc "The bound of the wait for the abort after a signal, in milliseconds."
  @spec abort_ms() :: pos_integer()
  def abort_ms, do: @abort_ms

  @doc """
  Runs `fun` in the setup of print mode, and puts the VM back after it.
  SIGTERM and SIGHUP are trapped: the first one aborts the session that
  `run/2` runs, waits at most `abort_ms/0`, and calls `halt` with 143 or
  129. `halt` halts the VM with no flush, so output that blocks never holds
  the exit; tests pass their own. After a signal, `wrap/2` does not
  return: the halt ends the run. The log goes to stderr, so stdout holds
  only the answer.
  """
  @spec wrap((-> result), (status :: 129 | 143 -> term())) :: result when result: term()
  def wrap(fun, halt \\ &:erlang.halt(&1, flush: false)) do
    # The type of the handler is fixed when it is added. Under `mix helyx`
    # Logger starts before the app config loads, so config cannot set it.
    {:ok, log} = :logger.get_handler_config(:default)
    put_log(put_in(log.config.type, :standard_error))

    :ok =
      :gen_event.swap_handler(
        :erl_signal_server,
        {:erl_signal_handler, []},
        {__MODULE__.Signal, halt}
      )

    :ok = :os.set_signal(:sighup, :handle)

    try do
      fun.()
    after
      # Elixir traps on SIGHUP are not set back; the product has none.
      :ok = :os.set_signal(:sighup, :default)
      # A signal between these two calls finds no handler and is dropped.
      stopping = :gen_event.delete_handler(:erl_signal_server, __MODULE__.Signal, :restore)
      :ok = :gen_event.add_handler(:erl_signal_server, :erl_signal_handler, [])
      put_log(log)
      # A stop has started: its halt sets the status, not the result of `fun`.
      if stopping, do: Process.sleep(:infinity)
    end
  end

  defp put_log(config) do
    :ok = :logger.remove_handler(:default)
    :ok = :logger.add_handler(:default, :logger_std_h, config)
  end

  @doc """
  The prompt with the piped input added as a block. Returns `{:error, text}`
  when the input is over `max_stdin_bytes/0` or not UTF-8.
  """
  @spec prompt(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def prompt(text) do
    if :io.getopts(:standard_io)[:stdin] == true,
      do: {:ok, text},
      else: add_input(text, read_stdin())
  end

  # In unicode mode the device counts characters and changes the bytes. In
  # latin1 mode a latin1 read (`:file.read/2`) returns the raw bytes, as
  # probed on OTP 28. One byte over the bound shows a longer input.
  defp read_stdin do
    :ok = :io.setopts(:standard_io, encoding: :latin1)

    try do
      :file.read(:standard_io, @max_stdin_bytes + 1)
    after
      :ok = :io.setopts(:standard_io, encoding: :unicode)
    end
  end

  defp add_input(text, :eof), do: {:ok, text}

  defp add_input(_text, {:error, reason}),
    do: {:error, "could not read stdin: " <> inspect(reason)}

  defp add_input(_text, {:ok, input}) when byte_size(input) > @max_stdin_bytes,
    do: {:error, "the piped input is over the #{@max_stdin_bytes}-byte limit"}

  defp add_input(text, {:ok, input}) do
    if String.valid?(input),
      do: {:ok, "#{text}\n\n<stdin>\n#{input}\n</stdin>"},
      else: {:error, "the piped input is not UTF-8"}
  end

  @doc """
  Sends `prompt` to `session`, waits for the end of its turn, prints the
  answer, and returns the exit status: 0 for a normal end, 1 for a failed
  or aborted turn, an answer cut at the output limit, or a session that
  stops. It must run inside `wrap/2`, which a signal uses to abort `session`. The
  caller aborts the turn and stops Core after it.
  """
  @spec run(Session.t(), String.t()) :: status()
  def run(session, prompt) do
    :ok = :gen_event.call(:erl_signal_server, __MODULE__.Signal, {:session, session})

    with {:ok, _snapshot, ref} <- Session.subscribe(session),
         stderr("session " <> session.id),
         :ok <- Session.prompt(session, prompt) do
      wait(ref, nil)
    else
      {:error, reason} -> fail("could not run the prompt: " <> inspect(reason))
    end
  end

  defp wait(ref, last) do
    receive do
      {:helyx_event, %Event{type: :message_end, data: %{message: %Message{role: :assistant} = m}}} ->
        wait(ref, m)

      {:helyx_event, %Event{type: :notice, data: %{text: text}}} ->
        stderr(CodingAgent.clean_line(text))
        wait(ref, last)

      {:helyx_event, %Event{type: :turn_end, data: data}} ->
        finish(data, last)

      {:helyx_event, %Event{}} ->
        wait(ref, last)

      {:DOWN, ^ref, :process, _pid, reason} ->
        fail({:session_down, Session.end_reason(reason)})
    end
  end

  defp finish(%{outcome: :done}, last) do
    IO.puts(if last, do: Message.text(last), else: "")
    status(last)
  end

  defp finish(%{outcome: :aborted}, _last), do: fail("the turn was aborted")
  defp finish(%{outcome: :error, error: text}, _last), do: fail("the turn failed: " <> text)

  defp status(%Message{stop_reason: :max_tokens}) do
    stderr("the answer stopped at the token limit")
    1
  end

  defp status(%Message{stop_reason: :refused}) do
    stderr("the answer stopped: the provider refused or filtered it")
    0
  end

  defp status(_last), do: 0

  defp fail(text) when is_binary(text) do
    stderr(CodingAgent.clean_line(text))
    1
  end

  defp fail(reason), do: fail(CodingAgent.error_text(reason))

  defp stderr(line), do: IO.puts(:stderr, "helyx: " <> line)

  defmodule Signal do
    @moduledoc false
    # The handler in `:erl_signal_server` while print mode runs. The first
    # trapped signal starts the stop; the handler ignores the rest. The stop
    # runs in its own process, so the signal server never waits on it.
    @behaviour :gen_event

    @statuses %{sigterm: 143, sighup: 129}

    @impl true
    def init({halt, _old_state}), do: {:ok, %{halt: halt, session: nil, stopping: false}}

    @impl true
    def handle_event(signal, %{stopping: false} = state) when is_map_key(@statuses, signal) do
      %{halt: halt, session: session} = state
      spawn(fn -> stop(session, Map.fetch!(@statuses, signal), halt) end)
      {:ok, %{state | stopping: true}}
    end

    def handle_event(_signal, state), do: {:ok, state}

    @impl true
    def handle_call({:session, session}, state), do: {:ok, :ok, %{state | session: session}}

    # `wrap/2` deletes the handler with `:restore` and learns if a stop runs.
    @impl true
    def terminate(:restore, %{stopping: stopping}), do: stopping
    def terminate(_arg, _state), do: :ok

    # The abort runs unlinked: a session that is gone, or one that does not
    # answer, holds the halt for at most the bound.
    defp stop(nil, status, halt), do: halt.(status)

    defp stop(session, status, halt) do
      {_pid, ref} = spawn_monitor(fn -> Session.abort(session) end)

      receive do
        {:DOWN, ^ref, :process, _pid, _reason} -> :ok
      after
        CodingAgent.Print.abort_ms() -> :ok
      end

      halt.(status)
    end
  end
end
