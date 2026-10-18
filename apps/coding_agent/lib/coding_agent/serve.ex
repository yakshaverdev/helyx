defmodule CodingAgent.Serve do
  @moduledoc """
  `helyx serve`: Core with the plugins of the agent and
  `Helyx.Transport.WebSocket`, up until SIGTERM or SIGHUP; the launcher of
  the release sends SIGTERM for SIGINT. One server runs for each data
  folder, the sessions folder: it holds the lock `server.lock` there. When
  it is ready, it writes `server.json` with mode 0600, which holds its
  address, port, token, protocol number, and OS pid, and prints one line
  with its address. The design is in `docs/features/serve.md`.
  """

  import Bitwise

  alias Helyx.Session.Lock
  alias Helyx.Transport.WebSocket

  # A second start reads the server file of the holder of the lock this
  # long, once each poll: the holder writes it when its listener is up.
  @wait_ms 5_000
  @poll_ms 100
  # The server file is about 150 bytes.
  @max_file_bytes 4_096

  @doc "The bound of the wait of a second start for the server file, in milliseconds."
  @spec wait_ms() :: pos_integer()
  def wait_ms, do: @wait_ms

  @doc "The bound of the read of the server file by a second start, in bytes."
  @spec max_file_bytes() :: pos_integer()
  def max_file_bytes, do: @max_file_bytes

  @doc """
  Runs the server until the first SIGTERM or SIGHUP, then stops it with a
  Core stop and returns `:ok`. Returns `{:error, text}` when another server
  holds the data folder, when the start fails, or when Core, the transport,
  or the lock ends while the server runs. The options are `:sessions_dir`
  (the data folder, an absolute path), `:model` (the default model ref),
  `:ip`, and `:port`. A data folder that other users can write is refused.
  From the lock to the end of `run/1`, its handler replaces the OTP handler
  in `:erl_signal_server`, which is global: the caller runs one server in a
  VM at a time. The OTP handler and the default of SIGHUP come back at the
  end of `run/1`, also after a crash of the server.
  """
  @spec run(keyword()) :: :ok | {:error, String.t()}
  def run(opts) do
    {pid, ref} = spawn_monitor(fn -> exit({:shutdown, serve(opts)}) end)

    result =
      receive do
        {:DOWN, ^ref, :process, _pid, {:shutdown, result}} -> result
        {:DOWN, ^ref, :process, _pid, reason} -> {:error, Helyx.Reason.text(reason)}
      end

    # The handler has the id of the serve process; a start that failed
    # before the lock did not swap it in.
    if {__MODULE__.Signal, pid} in :gen_event.which_handlers(:erl_signal_server) do
      :ok = swap_handler({{__MODULE__.Signal, pid}, []}, {:erl_signal_handler, []})
      :ok = :os.set_signal(:sighup, :default)
    end

    result
  end

  # The serve process traps exits: the end of Core, of the transport, or of
  # the port of the lock is a message of its wait. A signal before the
  # handler keeps the OTP default, which stops the VM; the kernel then frees
  # the lock, and no server file exists yet.
  defp serve(opts) do
    Process.flag(:trap_exit, true)
    dir = Keyword.fetch!(opts, :sessions_dir)

    with :ok <- mkdir(dir),
         {:ok, lock} <- lock(dir) do
      # The file of a server that was killed would pass for this one.
      case File.rm(Path.join(dir, "server.json")) do
        {:error, reason} when reason != :enoent ->
          Lock.release(lock)
          {:error, "could not remove the stale server file: #{:file.format_error(reason)}"}

        _removed ->
          :ok = swap_handler({:erl_signal_handler, []}, {{__MODULE__.Signal, self()}, self()})
          :ok = :os.set_signal(:sighup, :handle)
          start(lock, dir, opts)
      end
    end
  end

  defp swap_handler(old, new), do: :gen_event.swap_handler(:erl_signal_server, old, new)

  # The sessions folder gets mode 0700 when this makes it, as at a start.
  # Another user who can write the folder could swap `.server.tmp` after its
  # chmod, so such a folder is refused.
  defp mkdir(dir) do
    with :ok <- Helyx.Session.File.mkdir(dir),
         {:ok, %File.Stat{mode: mode}} when (mode &&& 0o022) == 0 <- File.stat(dir) do
      :ok
    else
      {:ok, %File.Stat{}} ->
        {:error, "other users can write the data folder #{dir}; run chmod go-w on it"}

      {:error, {:create_failed, reason}} ->
        folder_error(reason)

      {:error, reason} ->
        folder_error(reason)
    end
  end

  defp folder_error(reason),
    do: {:error, "could not make the data folder: #{:file.format_error(reason)}"}

  defp lock(dir) do
    case Lock.take(Path.join(dir, "server")) do
      {:ok, lock} ->
        {:ok, lock}

      {:error, {:session_locked, _}} ->
        running(dir, System.monotonic_time(:millisecond) + @wait_ms)

      {:error, {:lock_failed, text}} ->
        {:error, "could not lock the data folder: " <> text}
    end
  end

  # The address of the server that holds the lock, from its server file.
  defp running(dir, deadline) do
    case read(Path.join(dir, "server.json")) do
      {:ok, address} ->
        {:error, "a server runs for #{dir} at #{address}"}

      :error ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(@poll_ms)
          running(dir, deadline)
        else
          {:error, "a server holds the lock of #{dir} and gave no address in #{@wait_ms} ms"}
        end
    end
  end

  # The disk is a boundary: the file is read up to its bound, and only a
  # parsed address and port reach the line. `read_up_to/2` opens only a
  # regular file (accepted hole: a FIFO swapped in after its stat).
  defp read(path) do
    with {:ok, data} when byte_size(data) <= @max_file_bytes <-
           Helyx.Session.File.Scan.read_up_to(path, @max_file_bytes + 1),
         {:ok, %{"address" => text, "port" => port}}
         when is_binary(text) and port in 1..65_535 <- JSON.decode(data),
         {:ok, ip} <- :inet.parse_address(String.to_charlist(text)) do
      {:ok, url(ip, port)}
    else
      _ -> :error
    end
  end

  # Each step that fails stops the steps before it.
  defp start(lock, dir, opts) do
    case start_core(dir, opts) do
      {:ok, core} -> listen(lock, core, dir, opts)
      error -> stop([], lock, dir, error)
    end
  end

  defp start_core(dir, opts) do
    with {:error, reason} <-
           Helyx.Core.start_link(
             plugins: CodingAgent.plugins(),
             sessions_dir: dir,
             model: Keyword.fetch!(opts, :model)
           ),
         do: {:error, CodingAgent.error_text(reason)}
  end

  defp listen(lock, core, dir, opts) do
    ip = Keyword.fetch!(opts, :ip)
    port = Keyword.fetch!(opts, :port)
    token = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

    case WebSocket.start_link(core: Helyx.Core, ip: ip, port: port, token: token) do
      {:ok, transport} ->
        port = WebSocket.port(transport)

        case write_file(dir, ip, port, token) do
          :ok ->
            IO.puts("helyx: serving on " <> url(ip, port))
            wait(lock, core, transport, dir)

          error ->
            stop([transport, core], lock, dir, error)
        end

      {:error, reason} ->
        error = {:error, "could not listen on #{url(ip, port)}: " <> listen_error(reason)}
        stop([core], lock, dir, error)
    end
  end

  # The socket error of the listener, such as `:eaddrinuse`, in the start
  # error of the transport supervisor; any other error as a term.
  defp listen_error({{:shutdown, {:failed_to_start_child, :listener, reason}}, _child})
       when is_atom(reason),
       do: to_string(:inet.format_error(reason))

  defp listen_error(reason), do: Helyx.Reason.text(reason)

  # The file is written in a folder of mode 0700, so no other user can open
  # it before its mode is 0600, then renamed, so a reader sees no partial
  # file. The folder of a start that was killed goes first. The folder has
  # the umask mode until its chmod: `:exclusive` refuses a file or a link
  # that another user put in it then.
  defp write_file(dir, ip, port, token) do
    tmp = Path.join(dir, ".server.tmp")
    file = Path.join(tmp, "server.json")

    json =
      JSON.encode!(%{
        address: List.to_string(:inet.ntoa(ip)),
        port: port,
        token: token,
        protocol: WebSocket.protocol(),
        pid: String.to_integer(System.pid())
      })

    with {:ok, _} <- File.rm_rf(tmp),
         :ok <- File.mkdir(tmp),
         :ok <- File.chmod(tmp, 0o700),
         :ok <- File.write(file, json, [:exclusive]),
         :ok <- File.chmod(file, 0o600),
         :ok <- File.rename(file, Path.join(dir, "server.json")),
         :ok <- File.rmdir(tmp) do
      :ok
    else
      {:error, reason} -> write_error(reason)
      {:error, reason, _path} -> write_error(reason)
    end
  end

  defp write_error(reason),
    do: {:error, "could not write the server file: #{:file.format_error(reason)}"}

  defp url({_, _, _, _} = ip, port), do: "ws://#{:inet.ntoa(ip)}:#{port}"
  defp url(ip, port), do: "ws://[#{:inet.ntoa(ip)}]:#{port}"

  defp wait(lock, core, transport, dir) do
    receive do
      :stop ->
        stop([transport, core], lock, dir, :ok)

      # With the lock lost, `server.json` can be the file of the next
      # server, so it stays, and there is no lock to release.
      {:EXIT, ^lock, _reason} ->
        Enum.each([transport, core], &stop_supervisor/1)
        {:error, "the lock of the data folder is lost; the server stopped"}

      {:EXIT, pid, reason} when pid in [core, transport] ->
        error = {:error, "the server stopped: " <> Helyx.Reason.text(reason)}
        stop([transport, core], lock, dir, error)

      _other ->
        wait(lock, core, transport, dir)
    end
  end

  # The file goes first, so no new client finds a server that stops. The
  # parts stop in order, the transport before Core; a part that ended
  # already is skipped. A signal during the stop does nothing: `run/1` swaps
  # the handler back after it.
  defp stop(parts, lock, dir, result) do
    _ = File.rm(Path.join(dir, "server.json"))
    Enum.each(parts, &stop_supervisor/1)
    Lock.release(lock)
    result
  end

  defp stop_supervisor(pid) do
    Supervisor.stop(pid)
  catch
    :exit, _gone -> :ok
  end

  defmodule Signal do
    @moduledoc false
    # The handler in `:erl_signal_server` while `run/1` runs. SIGTERM and
    # SIGHUP send the serve process its stop; it stops at the first and
    # ends. Other signals keep the OTP default.
    @behaviour :gen_event

    @impl true
    def init({pid, _old_state}), do: {:ok, pid}

    @impl true
    def handle_event(signal, pid) when signal in [:sigterm, :sighup] do
      send(pid, :stop)
      {:ok, pid}
    end

    def handle_event(signal, pid) do
      {:ok, otp} = :erl_signal_handler.init([])
      {:ok, _otp} = :erl_signal_handler.handle_event(signal, otp)
      {:ok, pid}
    end

    @impl true
    def handle_call(_request, pid), do: {:ok, :ok, pid}
  end
end
