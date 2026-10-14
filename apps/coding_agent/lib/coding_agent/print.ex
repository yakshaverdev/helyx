defmodule CodingAgent.Print do
  @moduledoc """
  Print mode, a client of one session: one prompt in, the final answer out
  on stdout, and an exit status. A background run that is open holds print
  mode until its end opens a turn, unless the session holds the ends; the
  answer is the one of the last turn. The session id, the notices, and the
  errors go to stderr. Piped stdin (stdin is not a terminal) is added to
  the prompt as a block, up to 1 MiB of UTF-8. Every print run ends with a
  halt of the VM. The first SIGTERM or SIGHUP aborts the turn, waits at
  most `abort_ms/0` for the abort, and halts the VM with 143 or 129 and no
  flush, whatever stdout and stderr do. The design is in
  `docs/features/print-mode.md`.
  """

  alias Helyx.{Event, Message, Session}

  defmodule Wait do
    @moduledoc false
    # The state of the wait of `run/2`: `last` is the last assistant message
    # of the turn, `runs` the ids of the open background runs, `held` the
    # count of the held ends, and `idle?` true from a normal turn end that
    # leaves the wait to the next turn.
    defstruct [:last, :runs, :held, idle?: false]
  end

  # About 250,000 tokens, more than the context window of the models Helyx
  # runs, and far under the 64 MiB of a session file.
  @max_stdin_bytes 1_048_576

  # The abort releases the provider and the tools, or reports them as not
  # confirmed; a turn that does not end in this time is cut by the halt.
  @abort_ms 3_000

  @typedoc "The exit status that `run/2` returns; a signal halts with 129 or 143."
  @type status :: 0 | 1

  @typedoc "Ends the VM with the status; tests pass a function that reports it."
  @type halt :: (0 | 1 | 129 | 143 -> term())

  @doc "The bound of piped stdin, in bytes."
  @spec max_stdin_bytes() :: pos_integer()
  def max_stdin_bytes, do: @max_stdin_bytes

  @doc "The bound of the wait for the abort after a signal, in milliseconds."
  @spec abort_ms() :: pos_integer()
  def abort_ms, do: @abort_ms

  @doc """
  Runs `fun` as the whole of print mode, and ends it with `halt` and the
  status. The first step traps SIGTERM and SIGHUP, before any output, and
  the trap stays for the life of the VM: the first of them aborts the
  session that `run/2` runs, waits at most `abort_ms/0`, and calls `halt`
  with 143 or 129; later ones are ignored. Other signals keep the OTP
  default (SIGQUIT and SIGUSR1 halt the VM). Then the calling process
  only waits for the run and halts. The run, in a process of its own, sends the log to
  stderr, so stdout holds only the answer, and calls `fun`. `fun` returns
  the status, or `{:error, text}`, which is written as one line on stderr
  and gives 1; a raise, throw, or exit of `fun` gives one such line and 1
  too. Any other end of the run (a failed error line, a linked crash, a
  kill) gives 1. When a signal came first, its stop sets the status. `halt`
  halts the VM with no flush, so output that blocks never holds the exit,
  and `main/2` does not return.
  """
  @spec main((-> status() | {:error, String.t()}), halt()) :: term()
  def main(fun, halt \\ &:erlang.halt(&1, flush: false)) do
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
  Sends `prompt` to `session`, waits until the session settles, prints the
  answer of the last turn, and returns the exit status: 0 for a normal
  end, 1 for a failed or aborted turn, an answer cut at the output limit,
  a session that stops, or background runs whose ends hold. While a
  background run is open and its ends do not hold, a normal turn end does
  not end the wait: the end of the run opens the next turn
  (`docs/features/print-background-wait.md`). It must run inside `main/2`,
  which a signal uses to abort `session`. The caller aborts the turn and
  stops Core after it.
  """
  @spec run(Session.t(), String.t()) :: status()
  def run(session, prompt) do
    :ok = :gen_event.call(:erl_signal_server, __MODULE__.Signal, {:session, session})

    with {:ok, snapshot, ref} <- Session.subscribe(session),
         stderr("session " <> session.id),
         :ok <- Session.prompt(session, prompt) do
      runs = Enum.reduce(snapshot.messages, MapSet.new(), &runs/2)
      wait(ref, %Wait{runs: runs, held: snapshot.queue.held})
    else
      {:error, reason} -> fail("could not run the prompt: " <> inspect(reason))
    end
  end

  defp wait(ref, state) do
    receive do
      {:helyx_event, %Event{type: :message_end, data: %{message: %Message{role: :assistant} = m}}} ->
        wait(ref, %{state | last: m})

      {:helyx_event, %Event{type: type, data: %{message: m}}}
      when type in [:message_end, :tool_execution_end] ->
        wait(ref, %{state | runs: runs(m, state.runs)})

      {:helyx_event, %Event{type: :queue_update, data: %{held: held}}} ->
        if held > 0 and state.idle?,
          do: settle(ref, %{state | held: held}),
          else: wait(ref, %{state | held: held})

      {:helyx_event, %Event{type: :notice, data: %{text: text}}} ->
        stderr(text)
        wait(ref, state)

      {:helyx_event, %Event{type: :turn_start}} ->
        wait(ref, %{state | last: nil, idle?: false})

      {:helyx_event, %Event{type: :turn_end, data: %{outcome: :done}}} ->
        settle(ref, state)

      {:helyx_event, %Event{type: :turn_end, data: data}} ->
        finish(data)

      {:helyx_event, %Event{}} ->
        wait(ref, state)

      {:DOWN, ^ref, :process, _pid, reason} ->
        fail({:session_down, Session.end_reason(reason)})
    end
  end

  # After a normal turn end: an open run whose end can still open a turn
  # holds the wait; a held end never opens one, as no user sends a prompt.
  defp settle(ref, %Wait{runs: runs, held: held, last: last} = state) do
    case {MapSet.size(runs), held} do
      {0, _held} ->
        answer(last)

      {n, held} when held > 0 ->
        _status = answer(last)
        stderr("background runs whose end did not reach the agent: #{n}")
        1

      {n, 0} ->
        stderr("waiting for background runs: #{n}")
        wait(ref, %{state | idle?: true})
    end
  end

  # The start answer and the end message of a background run open with the
  # line that names the run (docs/features/background-bash.md), as
  # `Helyx.Session.Background.lost/1` reads them at a resume.
  @background ~r/\A<background id="([A-Za-z0-9_-]{12})" status="([a-z]+)">\n/

  defp runs(%Message{content: [%Message.Text{text: "<background " <> _ = text} | _]} = m, runs) do
    case {m.role, m.is_error, Regex.run(@background, text, capture: :all_but_first)} do
      {:tool_result, false, [id, "started"]} -> MapSet.put(runs, id)
      {:user, _is_error, [id, _status]} -> MapSet.delete(runs, id)
      _other -> runs
    end
  end

  defp runs(%Message{}, runs), do: runs

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
    def init({halt, _old_state}), do: {:ok, %{halt: halt, session: nil, done: false}}

    @impl true
    def handle_event(signal, %{done: false} = state) when is_map_key(@statuses, signal) do
      %{halt: halt, session: session} = state
      spawn(fn -> stop(session, Map.fetch!(@statuses, signal), halt) end)
      {:ok, %{state | done: true}}
    end

    # A signal that print mode does not own keeps the OTP default: SIGUSR1
    # and SIGQUIT halt the VM, the rest are ignored.
    def handle_event(signal, state) when not is_map_key(@statuses, signal) do
      {:ok, otp} = :erl_signal_handler.init([])
      {:ok, _otp} = :erl_signal_handler.handle_event(signal, otp)
      {:ok, state}
    end

    def handle_event(_signal, state), do: {:ok, state}

    @impl true
    def handle_call({:session, session}, state), do: {:ok, :ok, %{state | session: session}}
    # `done`: a signal started the stop, or the run finished first.
    def handle_call(:finish, %{done: true} = state), do: {:ok, :stopping, state}
    def handle_call(:finish, state), do: {:ok, :ok, %{state | done: true}}

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
