defmodule CodingAgent.Print do
  @moduledoc """
  Print mode, a client of one session over the wire: one prompt in, the
  final answer out on stdout, and an exit status. The session id, the
  notices, and the errors go to stderr. Piped stdin (stdin is not a
  terminal) is added to the prompt as a block, up to 1 MiB of UTF-8. Every
  print run ends with a halt of the VM, and the first SIGTERM or SIGHUP
  ends the session first. The design is in `docs/features/print-mode.md`.
  """

  alias Helyx.{Event, Message, Reason}
  alias Helyx.TUI.Link
  alias Helyx.TUI.Wire.Connection

  require Link

  defmodule Wait do
    @moduledoc false
    # The state of the wait of `run/5`: `last` is the last assistant message
    # of the turn, `queue` the last counts of the session (`queue_update`),
    # and `idle?` true from a normal turn end that leaves the wait to the
    # next turn. `conn` and `sub` get the acks.
    defstruct [:conn, :sub, :last, :queue, idle?: false]
  end

  # About 250,000 tokens, more than the context window of the models Helyx
  # runs, and far under the 64 MiB of one line of a session file.
  @max_stdin_bytes 1_048_576

  # The end of the session releases the provider and the tools, or reports
  # them as not confirmed; a turn that does not end in this time is cut by
  # the halt.
  @abort_ms 3_000

  @typedoc "The exit status that `run/5` returns; a signal halts with 129 or 143."
  @type status :: 0 | 1

  @typedoc "Ends the VM with the status; tests pass a function that reports it."
  @type halt :: (0 | 1 | 129 | 143 -> term())

  @doc "The bound of piped stdin, in bytes."
  @spec max_stdin_bytes() :: pos_integer()
  def max_stdin_bytes, do: @max_stdin_bytes

  @doc "The bound of the wait for the end of the session after a signal, in milliseconds."
  @spec abort_ms() :: pos_integer()
  def abort_ms, do: @abort_ms

  @doc """
  Runs `fun` as the whole of print mode, and ends it with `halt` and the
  status. The first step traps SIGTERM and SIGHUP, before any output, and
  the trap stays for the life of the VM: the first of them ends the
  session that `run/5` runs, waits at most `abort_ms/0`, and calls `halt`
  with 143 or 129; later ones are ignored, and so is every other signal while
  the stop runs. The run, in a process of its own, sends the log to
  stderr, so stdout holds only the answer, and calls `fun`. A raise, throw,
  or exit of `fun` gives one line on stderr and 1. `halt`
  halts the VM with no flush, so output that blocks never holds the exit,
  and `main/2` does not return.
  """
  @spec main((-> status() | {:error, String.t()}), halt()) :: term()
  def main(fun, halt) do
    :ok =
      :gen_event.swap_handler(
        :erl_signal_server,
        {:erl_signal_handler, []},
        {__MODULE__.Signal, halt}
      )

    :ok = :os.set_signal(:sighup, :handle)

    # From here this process runs no code that can raise: every way the run
    # ends is a `:DOWN`, and every `:DOWN` reaches the halt.
    {_pid, ref} = spawn_monitor(fn -> exit({:shutdown, run_process(fun)}) end)

    status =
      receive do
        {:DOWN, ^ref, :process, _pid, {:shutdown, status}} when status in [0, 1] -> status
        {:DOWN, ^ref, :process, _pid, _reason} -> 1
      end

    # The handler answers `:stopping` once a signal has started its stop.
    case :gen_event.call(:erl_signal_server, __MODULE__.Signal, :finish) do
      :ok -> halt.(status)
      :stopping -> Process.sleep(:infinity)
    end
  end

  defp run_process(fun) do
    # The type of the handler is fixed when it is added. Under `mix helyx`
    # Logger starts before the app config loads, so config cannot set it.
    {:ok, log} = :logger.get_handler_config(:default)
    :ok = :logger.remove_handler(:default)
    :ok = :logger.add_handler(:default, :logger_std_h, put_in(log.config.type, :standard_error))

    result =
      try do
        fun.()
      catch
        kind, reason -> {:error, Exception.format_banner(kind, reason)}
      end

    case result do
      {:error, text} -> fail(text)
      status -> status
    end
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
  The prompt of a print run with a skill command `/name args` expanded
  (`Helyx.Skills.expand/3`), after each notice of the skills scan of `cwd`
  and `home` is written on stderr (`docs/features/skills.md`).
  """
  @spec skills(String.t(), String.t(), String.t()) :: String.t()
  def skills(prompt, cwd, home \\ System.user_home!()) do
    Enum.each(Helyx.Skills.scan(cwd, home).notices, &stderr/1)
    Helyx.Skills.expand(prompt, cwd, home) || prompt
  end

  @doc """
  Sends `prompt` to the session `id` over the connection `conn`, waits until
  the session settles, prints the answer of the last turn, and returns the
  exit status: 0 for a normal end, 1 for a failed or aborted turn, an answer
  cut at the output limit, a session or a connection that ends, or
  background runs whose ends hold
  (`docs/features/print-background-wait.md`). It must run inside `main/2`,
  in the process that owns `conn` and its monitor `ref`: the events of the
  subscription come to that process. `stop` is what the signal handler
  calls; the caller ends the session and the connection after it. The
  design is in `docs/features/print-mode.md`.
  """
  @spec run(pid(), reference(), String.t(), String.t(), (-> term())) :: status()
  def run(conn, ref, id, prompt, stop) do
    :ok = :gen_event.call(:erl_signal_server, __MODULE__.Signal, {:session, stop})

    with {:ok, snapshot, sub} <- Connection.subscribe(conn, id),
         stderr("session " <> id),
         # A stop of the saving before the subscribe sent its notice to no client.
         if(not snapshot.persisting, do: stderr(Reason.text(:not_saved))),
         :ok <- Connection.prompt(conn, id, prompt) do
      wait(ref, sub, %Wait{conn: conn, sub: sub, queue: snapshot.queue})
    else
      {:error, reason} -> fail("could not run the prompt: " <> prompt_error(reason))
    end
  end

  # A wire error has the text of the footer of the TUI; any other error is
  # the term as inspect/1 shows it.
  defp prompt_error(reason) when Link.wire_error?(reason), do: Link.error_text(reason)
  defp prompt_error(reason), do: inspect(reason)

  defp wait(ref, sub, state) do
    receive do
      {:helyx_event, ^sub, %Event{} = event} ->
        :ok = Connection.ack(state.conn, sub, event)
        on_event(event, ref, sub, state)

      # The session of the subscription ended: stopped, or crashed.
      {:helyx_end, ^sub, reason} ->
        fail({:session_down, reason})

      {:DOWN, ^ref, :process, _pid, reason} ->
        fail({:connection_down, reason})
    end
  end

  defp on_event(
         %Event{type: :message_end, data: %{message: %Message{role: :assistant} = m}},
         ref,
         sub,
         state
       ),
       do: wait(ref, sub, %{state | last: m})

  # While idle, a turn opens after the `queue_update` of its ends, so
  # the counts alone end the wait only with an end that holds.
  defp on_event(%Event{type: :queue_update, data: queue}, ref, sub, state) do
    if queue.held > 0 and state.idle?,
      do: settle(ref, sub, %{state | queue: queue}),
      else: wait(ref, sub, %{state | queue: queue})
  end

  defp on_event(%Event{type: :notice, data: %{text: text}}, ref, sub, state) do
    stderr(text)
    wait(ref, sub, state)
  end

  defp on_event(%Event{type: :turn_start}, ref, sub, state),
    do: wait(ref, sub, %{state | last: nil, idle?: false})

  defp on_event(%Event{type: :turn_end, data: %{outcome: :done}}, ref, sub, state),
    do: settle(ref, sub, state)

  defp on_event(%Event{type: :turn_end, data: data}, _ref, _sub, _state), do: finish(data)
  defp on_event(%Event{}, ref, sub, state), do: wait(ref, sub, state)

  # After a normal turn end: a running run, or an end that waits for a
  # turn, holds the wait; a held end never opens a turn, as no user sends a
  # prompt.
  defp settle(ref, sub, %Wait{queue: queue, last: last} = state) do
    case {queue.running + queue.waiting, queue.held} do
      {0, 0} ->
        answer(last)

      {n, held} when held > 0 ->
        _status = answer(last)
        stderr("background runs whose end did not reach the agent: #{n + held}")
        1

      {n, 0} ->
        stderr("waiting for background runs: #{n}")
        wait(ref, sub, %{state | idle?: true})
    end
  end

  defp answer(last) do
    IO.puts(if last, do: Message.text(last), else: "")
    status(last)
  end

  defp finish(%{outcome: :aborted}), do: fail("the turn was aborted")
  defp finish(%{outcome: :error, error: text}), do: fail("the turn failed: " <> text)

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
    stderr(text)
    1
  end

  defp fail(reason), do: fail(CodingAgent.error_text(reason))

  # Every line of print mode gets the clean pass and the cap here.
  defp stderr(line), do: IO.puts(:stderr, "helyx: " <> CodingAgent.clean_line(line))

  defmodule Signal do
    @moduledoc false
    # The handler in `:erl_signal_server` from the first step of print mode
    # to the halt. The first SIGTERM or SIGHUP starts the stop; the handler
    # ignores later ones. The stop runs in its own process, so the signal
    # server never waits on it.
    @behaviour :gen_event

    @statuses %{sigterm: 143, sighup: 129}

    @impl true
    def init({halt, _old_state}),
      do: {:ok, %{halt: halt, stop: nil, phase: :running}}

    @impl true
    def handle_event(signal, %{phase: :running} = state) when is_map_key(@statuses, signal) do
      %{halt: halt, stop: stop} = state
      status = Map.fetch!(@statuses, signal)
      spawn(fn -> stop(stop, status, halt) end)
      {:ok, %{state | phase: {:stopping, status}}}
    end

    # The stop owns the result. A later signal must not reach the OTP default
    # and halt the VM with its own status before the stop halts with the
    # first one.
    def handle_event(_signal, %{phase: {:stopping, _status}} = state), do: {:ok, state}

    # A signal that print mode does not own keeps the OTP default: SIGUSR1
    # and SIGQUIT halt the VM, the rest are ignored.
    def handle_event(signal, state) when not is_map_key(@statuses, signal) do
      {:ok, otp} = :erl_signal_handler.init([])
      {:ok, _otp} = :erl_signal_handler.handle_event(signal, otp)
      {:ok, state}
    end

    def handle_event(_signal, state), do: {:ok, state}

    @impl true
    def handle_call({:session, stop}, state), do: {:ok, :ok, %{state | stop: stop}}
    # `{:stopping, status}`: a signal started the stop. `:running`: the run
    # finished first, and only one call happens.
    def handle_call(:finish, %{phase: {:stopping, _status}} = state),
      do: {:ok, :stopping, state}

    def handle_call(:finish, state), do: {:ok, :ok, %{state | phase: :finished}}

    # The request runs unlinked: a session that is gone, or one that does not
    # answer, holds the halt for at most the bound. `stop` is nil before
    # `run/5` names it.
    defp stop(nil, status, halt), do: halt.(status)

    defp stop(stop, status, halt) do
      {_pid, ref} = spawn_monitor(stop)

      receive do
        {:DOWN, ^ref, :process, _pid, _reason} -> :ok
      after
        CodingAgent.Print.abort_ms() -> :ok
      end

      halt.(status)
    end
  end
end
