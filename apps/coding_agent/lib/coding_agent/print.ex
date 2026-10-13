defmodule CodingAgent.Print do
  @moduledoc """
  Print mode, a client of one session: one prompt in, the final answer out
  on stdout, and an exit status. The session id, the notices, and the
  errors go to stderr. Piped stdin (stdin is not a terminal) is added to the
  prompt as a block, up to 1 MiB of UTF-8. SIGTERM gives 143 and SIGHUP 129,
  after the turn is aborted and Core stops. The design is in
  `docs/features/print-mode.md`.
  """

  alias Helyx.{Event, Message, Session}

  # About 250,000 tokens, more than the context window of the models Helyx
  # runs, and far under the 64 MiB of a session file.
  @max_stdin_bytes 1_048_576

  @typedoc "The exit status of a print run: 129 for SIGHUP, 143 for SIGTERM."
  @type status :: 0 | 1 | 129 | 143

  @doc "The bound of piped stdin, in bytes."
  @spec max_stdin_bytes() :: pos_integer()
  def max_stdin_bytes, do: @max_stdin_bytes

  @doc """
  Runs `fun` in the setup of print mode, and puts the VM back after it.
  SIGTERM and SIGHUP are trapped: a signal becomes a message to the caller,
  which `prompt/1` and `run/2` take. When a signal came during `fun` and
  nothing took it, the result is the status of the signal. The log goes to
  stderr, so stdout holds only the answer.
  """
  @spec wrap((-> result)) :: result | 129 | 143 when result: term()
  def wrap(fun) do
    # The type of the handler is fixed when it is added. Under `mix helyx`
    # Logger starts before the app config loads, so config cannot set it.
    {:ok, log} = :logger.get_handler_config(:default)
    put_log(put_in(log.config.type, :standard_error))
    swap_signal_handler(:erl_signal_handler, {__MODULE__.Signal, self()})
    :ok = :os.set_signal(:sighup, :handle)

    try do
      result = fun.()

      case signal() do
        :none -> result
        status -> status
      end
    after
      # Elixir traps on SIGHUP are not set back; the product has none.
      :ok = :os.set_signal(:sighup, :default)
      swap_signal_handler(__MODULE__.Signal, {:erl_signal_handler, []})
      put_log(log)
    end
  end

  defp put_log(config) do
    :ok = :logger.remove_handler(:default)
    :ok = :logger.add_handler(:default, :logger_std_h, config)
  end

  defp swap_signal_handler(old, new),
    do: :ok = :gen_event.swap_handler(:erl_signal_server, {old, []}, new)

  @doc """
  The prompt with the piped input added as a block. Returns `{:error, text}`
  when the input is over `max_stdin_bytes/0` or not UTF-8, and the status
  of a signal that came during the read.
  """
  @spec prompt(String.t()) :: {:ok, String.t()} | {:error, String.t()} | 129 | 143
  def prompt(text) do
    if :io.getopts(:standard_io)[:stdin] == true do
      {:ok, text}
    else
      case unblocked(&read_stdin/0) do
        {:ok, input} -> add_input(text, input)
        {:signal, status} -> status
      end
    end
  end

  # Runs `fun` in a linked process, so that a signal ends the wait for a read or a
  # write that blocks: a pipe that stays open, or a full one.
  defp unblocked(fun) do
    parent = self()
    # Linked, so a crash of `fun` crashes the run, as with `Task.async/1`.
    pid = spawn_link(fn -> send(parent, {__MODULE__, self(), fun.()}) end)

    receive do
      {__MODULE__, ^pid, result} ->
        {:ok, result}

      {__MODULE__, :signal, status} ->
        Process.unlink(pid)
        Process.exit(pid, :kill)
        {:signal, status}
    end
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
  stops, and the status of a signal. The caller aborts the turn and stops
  Core after it.
  """
  @spec run(Session.t(), String.t()) :: status()
  def run(session, prompt) do
    # A signal during the start sends no prompt.
    with {:ok, _snapshot, ref} <- Session.subscribe(session),
         stderr("session " <> session.id),
         :none <- signal(),
         :ok <- Session.prompt(session, prompt) do
      wait(ref, nil)
    else
      {:error, reason} -> fail("could not run the prompt: " <> inspect(reason))
      status when is_integer(status) -> status
    end
  end

  defp signal do
    receive do
      {__MODULE__, :signal, status} -> status
    after
      0 -> :none
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

      {__MODULE__, :signal, status} ->
        status
    end
  end

  defp finish(%{outcome: :done}, last) do
    text = if last, do: Message.text(last), else: ""

    case unblocked(fn -> IO.puts(text) end) do
      {:ok, :ok} -> status(last)
      {:signal, status} -> status
    end
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
    # The handler in `:erl_signal_server` while print mode runs. It sends
    # only the first trapped signal to the print process; it ignores the rest.
    @behaviour :gen_event

    @statuses %{sigterm: 143, sighup: 129}

    @impl true
    def init({pid, _old_state}), do: {:ok, pid}

    @impl true
    def handle_event(signal, pid) when is_pid(pid) do
      case Map.fetch(@statuses, signal) do
        {:ok, status} ->
          send(pid, {CodingAgent.Print, :signal, status})
          {:ok, :sent}

        :error ->
          {:ok, pid}
      end
    end

    def handle_event(_signal, :sent), do: {:ok, :sent}

    @impl true
    def handle_call(_request, state), do: {:ok, :ok, state}

    @impl true
    def terminate(_arg, _state), do: :ok
  end
end
