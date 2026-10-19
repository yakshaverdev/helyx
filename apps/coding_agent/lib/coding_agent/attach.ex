defmodule CodingAgent.Attach do
  @moduledoc """
  The client side of `helyx serve`: finds the server of a data folder by its
  server file and its lock, and connects to it over the wire
  (`Helyx.TUI.Wire`). The rules are in `docs/features/tui-attach.md`.
  """

  import Bitwise

  alias CodingAgent.Serve
  alias Helyx.Session.Lock
  alias Helyx.Transport.WebSocket
  alias Helyx.TUI.Wire

  # An attempt while the server is starting, once each poll, as a second
  # start reads the server file (`Serve.wait_ms/0`).
  @poll_ms 100
  # The TCP connect and the handshake of one attempt.
  @connect_ms 5_000

  @doc """
  Connects to the server of the data folder `dir`. Returns `{:ok, socket}`
  after `welcome`, with the socket owned by the caller, `:none` when no
  server runs, or `{:error, text}` with one line. While the lock is held, a
  missing or invalid server file and a failed connect mean that the server
  is starting: the attempt runs again every #{@poll_ms} ms, and none starts
  after `CodingAgent.Serve.wait_ms/0`. The client never writes or removes
  the server file.
  """
  @spec connect(Path.t()) :: {:ok, :gen_tcp.socket()} | :none | {:error, String.t()}
  def connect(dir) do
    with :ok <- folder(dir),
         do: attempt(dir, System.monotonic_time(:millisecond) + Serve.wait_ms())
  end

  # A user who can write the data folder could write a server file that
  # sends the prompts of the user to another server: the rule of serve.
  defp folder(dir) do
    case File.stat(dir) do
      {:ok, %File.Stat{type: :directory, mode: mode}} when (mode &&& 0o022) == 0 ->
        :ok

      {:ok, %File.Stat{type: :directory}} ->
        {:error, "other users can write the data folder #{dir}; run chmod go-w on it"}

      {:error, :enoent} ->
        :none

      {:ok, %File.Stat{}} ->
        {:error, "the data folder #{dir} is not a directory"}

      {:error, reason} ->
        {:error, "could not read the data folder #{dir}: #{:file.format_error(reason)}"}
    end
  end

  defp attempt(dir, deadline) do
    case test_lock(dir) do
      true -> read(dir, deadline)
      false -> :none
      error -> error
    end
  end

  defp read(dir, deadline) do
    case Serve.read_file(dir) do
      {:ok, ip, port, token} when is_function(token) -> open(dir, deadline, ip, port, token)
      {:ok, _ip, _port, nil} -> again(dir, deadline, "the server file holds no token")
      :error -> again(dir, deadline, "no valid server file")
    end
  end

  defp open(dir, deadline, ip, port, token) do
    case Wire.connect(ip, port, token, @connect_ms) do
      {:ok, socket} ->
        {:ok, socket}

      {:error, {:refused, server}} ->
        {:error,
         "the server speaks protocol #{server}, this client speaks " <>
           "#{WebSocket.protocol()}; install the same build"}

      {:error, :broken} ->
        {:error,
         "could not attach to the server at #{Serve.url(ip, port)}: " <>
           "the server broke the wire contract"}

      {:error, text} ->
        again(dir, deadline, text)
    end
  end

  # The deadline is checked after the sleep, so no attempt starts past it.
  defp again(dir, deadline, text) do
    Process.sleep(@poll_ms)

    if System.monotonic_time(:millisecond) < deadline,
      do: attempt(dir, deadline),
      else: {:error, "could not attach to the server of #{dir} in #{Serve.wait_ms()} ms: #{text}"}
  end

  # A non-blocking take of the lock: `true` when a server holds it. A take
  # that gets it means that no server runs, and it releases the lock at once.
  # The take runs in a Task, so the port and its messages end with it. The
  # Task traps exits, as `Lock.take/1` needs: a perl that ends with no answer
  # is seen at the exit of its port.
  defp test_lock(dir) do
    task =
      Task.async(fn ->
        Process.flag(:trap_exit, true)

        case Lock.take(Path.join(dir, "server")) do
          {:ok, lock} ->
            Lock.release(lock)
            false

          {:error, {:session_locked, _}} ->
            true

          {:error, {:lock_failed, text}} ->
            {:error, "could not test the lock of the data folder: " <> text}
        end
      end)

    # The take and the release have their own bounds.
    Task.await(task, :infinity)
  end
end
