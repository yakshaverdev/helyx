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
  The handler of the server replaces the OTP handler in
  `:erl_signal_server`, which is global, only when the OTP handler is in
  place, so a VM runs one server: a second `run/1` while one serves returns
  an error. The OTP handler and the default of SIGHUP come back at the end
  of the server, also after its crash.
  """
  @spec run(keyword()) :: :ok | {:error, String.t()}
  def run(opts) do
    {_pid, ref} = spawn_monitor(fn -> exit({:shutdown, serve(opts)}) end)

    receive do
      {:DOWN, ^ref, :process, _pid, {:shutdown, result}} -> result
      {:DOWN, ^ref, :process, _pid, reason} -> {:error, Helyx.Reason.text(reason)}
    end
  end

  # The serve process traps exits: the end of Core, of the transport, or of
  # the port of the lock is a message of its wait. A signal before the
  # handler keeps the OTP default, which stops the VM; the kernel then frees
  # the lock, and no server file exists yet. The perl process that holds
  # the lock does every operation on `server.json`, so a server whose lock
  # ended does none (`Helyx.Session.Lock.write_file/3`).
  defp serve(opts) do
    Process.flag(:trap_exit, true)
    dir = Keyword.fetch!(opts, :sessions_dir)

    with :ok <- mkdir(dir),
         {:ok, lock} <- lock(dir) do
      # The file of a server that was killed would pass for this one.
      case Lock.remove_file(lock, server_file(dir)) do
        {:error, text} ->
          Lock.release(lock)
          {:error, "could not remove the stale server file: " <> text}

        :ok ->
          signals(lock, dir, opts)
      end
    end
  end

  # The state of the signal server is the guard of one server in a VM: the
  # swap takes the place of the OTP handler only (`Signal.init/1`). The
  # serve process supervises its handler, so the signal server removes it
  # when the process ends, and a removal that is not this give-back puts
  # the OTP handler back (`Signal.terminate/2`). The give-back adds the OTP
  # handler with no supervisor, since a swap would pass the supervision on.
  defp signals(lock, dir, opts) do
    case :gen_event.swap_sup_handler(
           :erl_signal_server,
           {:erl_signal_handler, []},
           {{__MODULE__.Signal, self()}, self()}
         ) do
      :ok ->
        :ok = :os.set_signal(:sighup, :handle)
        result = start(lock, dir, opts)

        :ok =
          :gen_event.delete_handler(:erl_signal_server, {__MODULE__.Signal, self()}, :give_back)

        :ok = :gen_event.add_handler(:erl_signal_server, :erl_signal_handler, [])
        :ok = :os.set_signal(:sighup, :default)
        result

      {:error, _taken} ->
        Lock.release(lock)
        {:error, "a server runs in this VM already"}
    end
  end

  defp server_file(dir), do: Path.join(dir, "server.json")

  # The sessions folder gets mode 0700 when this makes it, as at a start.
  # Another user who can write the folder could replace the server file or
  # its temporary file, so such a folder is refused.
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
    case read(server_file(dir)) do
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
    token = token()

    case WebSocket.start_link(core: Helyx.Core, ip: ip, port: port, token: token) do
      {:ok, transport} ->
        port = WebSocket.port(transport)

        case write_file(lock, dir, ip, port, token) do
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

  # The token of a start, in a closure: no frame, argument, or process
  # state holds it as a binary (docs/agents/review-checklist.md).
  defp token do
    token = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    fn -> token end
  end

  # The holder of the lock writes the file with mode 0600 and a rename, so a
  # reader sees no partial file; the text with the token is made in the one
  # call that sends it.
  defp write_file(lock, dir, ip, port, token) do
    json = fn ->
      JSON.encode!(%{
        address: List.to_string(:inet.ntoa(ip)),
        port: port,
        token: token.(),
        protocol: WebSocket.protocol(),
        pid: String.to_integer(System.pid())
      })
    end

    with {:error, text} <- Lock.write_file(lock, server_file(dir), json),
         do: {:error, "could not write the server file: " <> text}
  end

  defp url({_, _, _, _} = ip, port), do: "ws://#{:inet.ntoa(ip)}:#{port}"
  defp url(ip, port), do: "ws://[#{:inet.ntoa(ip)}]:#{port}"

  defp wait(lock, core, transport, dir) do
    receive do
      :stop ->
        stop([transport, core], lock, dir, :ok)

      # The file stays: the remove of the stop goes to an ended lock.
      {:EXIT, ^lock, _reason} ->
        error = {:error, "the lock of the data folder is lost; the server stopped"}
        stop([transport, core], lock, dir, error)

      {:EXIT, pid, reason} when pid in [core, transport] ->
        error = {:error, "the server stopped: " <> Helyx.Reason.text(reason)}
        stop([transport, core], lock, dir, error)

      # The handler ended (it crashed): the OTP handler is back, and a
      # signal would no longer give a Core stop.
      {:gen_event_EXIT, {__MODULE__.Signal, _pid}, reason} ->
        error = {:error, "the signal handler ended: " <> Helyx.Reason.text(reason)}
        stop([transport, core], lock, dir, error)

      _other ->
        wait(lock, core, transport, dir)
    end
  end

  # The file goes first, so no new client finds a server that stops; a
  # lock that ended removes nothing, since the file can be the file of the
  # next server. The parts stop in order, the transport before Core; a part
  # that ended already is skipped. A signal during the stop does nothing:
  # the handler goes back after it.
  defp stop(parts, lock, dir, result) do
    _ = Lock.remove_file(lock, server_file(dir))
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
    # The handler in `:erl_signal_server` while a server runs. SIGTERM and
    # SIGHUP send the serve process its stop; it stops at the first and
    # ends. Other signals keep the OTP default.
    @behaviour :gen_event

    # Only the OTP handler hands over: its `terminate/2` gives `:ok`. The
    # handler of another server, or none, is refused.
    @impl true
    def init({pid, :ok}), do: {:ok, pid}
    def init({_pid, _not_otp}), do: {:error, :taken}

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

    # A removal that is not the give-back of the serve process (its end, or
    # a crash of this handler) puts the OTP handler back, from another
    # process: a call to the signal server from here would wait on itself.
    @impl true
    def terminate(:give_back, _pid), do: :ok

    def terminate(_reason, _pid) do
      spawn(fn ->
        :gen_event.add_handler(:erl_signal_server, :erl_signal_handler, [])
        :os.set_signal(:sighup, :default)
      end)

      :ok
    end
  end
end
