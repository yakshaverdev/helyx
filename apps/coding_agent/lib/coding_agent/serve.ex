defmodule CodingAgent.Serve do
  @moduledoc """
  `helyx serve`: Core with the plugins of the agent and
  `Helyx.Transport.WebSocket`, up until the stop of the VM, which the OTP
  answer to SIGTERM starts; the launcher of the release sends SIGTERM for
  each signal that it catches. One server runs for each data
  folder, the sessions folder: it holds the lock `server.lock` there. When
  it is ready, it writes `server.json` with mode 0600, which holds its
  address, port, token, protocol number, and OS pid, and prints one line
  with its address. The design is in `docs/features/serve.md`.
  """

  import Bitwise

  alias Helyx.Session.Lock
  alias Helyx.Transport.WebSocket

  # A second start reads the server file of the holder of the lock and
  # connects to it this long, once each poll: the holder writes it when its
  # listener is up.
  @wait_ms 5_000
  @poll_ms 100
  # The TCP connect and the handshake of one attempt, as in
  # `CodingAgent.Attach`.
  @connect_ms 5_000
  # The server file is about 150 bytes.
  @max_file_bytes 4_096

  @doc """
  The bound of the wait of a second start for the server file and its
  handshake, in milliseconds: no attempt starts after it.
  """
  @spec wait_ms() :: pos_integer()
  def wait_ms, do: @wait_ms

  @doc "The bound of the read of the server file by a second start, in bytes."
  @spec max_file_bytes() :: pos_integer()
  def max_file_bytes, do: @max_file_bytes

  @doc """
  Runs the server until the stop of the VM, then returns `:ok`. Returns
  `{:error, text}` when a server runs in this VM already, when another
  server holds the data folder, when the start fails, or when Core, the
  transport, or the lock ends while the server runs. The options are
  `:sessions_dir` (the data folder, an absolute path), `:model` (the
  default model ref), `:ip`, and `:port`. A data folder that other users
  can write is refused. The server runs under the supervisor
  `CodingAgent.Servers` of the application, so the stop of the VM
  (`init:stop/0`, the OTP answer to SIGTERM) stops it in order; the
  caller waits for its result and does not own it.
  """
  @spec run(keyword()) :: :ok | {:error, String.t()}
  def run(opts) do
    group_leader = Process.group_leader()

    # A task of the supervisor prints where its supervisor prints, so the
    # serve process takes the group leader of the caller.
    task =
      Task.Supervisor.async_nolink(
        CodingAgent.Servers,
        fn ->
          Process.group_leader(self(), group_leader)
          serve(opts)
        end,
        # Each step of the stop has its own bound; a kill would skip the
        # stop of Core.
        shutdown: :infinity
      )

    case Task.yield(task, :infinity) do
      {:ok, result} -> result
      {:exit, reason} -> {:error, Helyx.Reason.text(reason)}
    end
  end

  # The serve process traps exits: the end of Core, of the transport, or of
  # the port of the lock, and the stop of its supervisor, are messages of
  # its wait. Its name is the guard of one server in a VM, taken first and
  # held until the process ends, after its stop. The perl process that
  # holds the lock does every operation on `server.json`, so a server whose
  # lock ended does none (`Helyx.Session.Lock.write_file/3`).
  defp serve(opts) do
    Process.flag(:trap_exit, true)
    dir = Keyword.fetch!(opts, :sessions_dir)

    with :ok <- register(),
         :ok <- mkdir(dir),
         {:ok, lock} <- lock(dir) do
      # The file of a server that was killed would pass for this one.
      case Lock.remove_file(lock, server_file(dir)) do
        {:error, text} ->
          Lock.release(lock)
          {:error, "could not remove the stale server file: " <> text}

        :ok ->
          start(lock, dir, opts)
      end
    end
  end

  defp register do
    Process.register(self(), __MODULE__)
    :ok
  rescue
    ArgumentError -> {:error, "a server runs in this VM already"}
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

  # The address of the server that holds the lock. The server file is a
  # hint and the handshake with its token is the proof: from the `flock` of
  # a new server to its remove of a stale file, the file names a server
  # that was killed (#777). Any failure means that the server is starting.
  # The deadline is checked after the sleep, so no attempt starts past it.
  defp running(dir, deadline) do
    with {:ok, ip, port, token} when is_function(token) <- read_file(dir),
         {:ok, socket} <- Helyx.TUI.Wire.connect(ip, port, token, @connect_ms) do
      :gen_tcp.close(socket)
      {:error, "a server runs for #{dir} at #{url(ip, port)}"}
    else
      _starting ->
        Process.sleep(@poll_ms)

        if System.monotonic_time(:millisecond) < deadline do
          running(dir, deadline)
        else
          {:error, "a server holds the lock of #{dir} and gave no address in #{@wait_ms} ms"}
        end
    end
  end

  @doc false
  # The server file of the data folder `dir`, for a second start and for a
  # client (docs/features/tui-attach.md): `{:ok, ip, port, token}` or
  # `:error`. The disk is a boundary: the file is read up to its bound, and
  # only a parsed address and port reach a line. The token is in a closure,
  # or nil when the file holds no string token. `read_up_to/2` opens only a
  # regular file (accepted hole: a FIFO swapped in after its stat).
  @spec read_file(Path.t()) ::
          {:ok, :inet.ip_address(), 1..65_535, (-> String.t()) | nil} | :error
  def read_file(dir) do
    with {:ok, data} when byte_size(data) <= @max_file_bytes <-
           Helyx.Session.File.Scan.read_up_to(server_file(dir), @max_file_bytes + 1),
         {:ok, %{"address" => text, "port" => port} = json}
         when is_binary(text) and port in 1..65_535 <- JSON.decode(data),
         {:ok, ip} <- :inet.parse_address(String.to_charlist(text)) do
      {:ok, ip, port, token(json["token"])}
    else
      _ -> :error
    end
  end

  defp token(token) when is_binary(token), do: fn -> token end
  defp token(_other), do: nil

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

        with :ok <- write_file(lock, dir, ip, port, token),
             :ok <- print("helyx: serving on " <> url(ip, port)) do
          wait(lock, core, transport, dir)
        else
          error -> stop([transport, core], lock, dir, error)
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

  @doc false
  # The URL of a parsed address and a port, for a line.
  @spec url(:inet.ip_address(), :inet.port_number()) :: String.t()
  def url({_, _, _, _} = ip, port), do: "ws://#{:inet.ntoa(ip)}:#{port}"
  def url(ip, port), do: "ws://[#{:inet.ntoa(ip)}]:#{port}"

  # A closed output fails the print: the stop then runs, with an error.
  defp print(line) do
    IO.puts(line)
  catch
    kind, _reason when kind in [:error, :exit] ->
      {:error, "could not print the address: the output is closed"}
  end

  defp wait(lock, core, transport, dir) do
    {:parent, supervisor} = Process.info(self(), :parent)

    result =
      receive do
        # The file stays: the remove of the stop goes to an ended lock.
        {:EXIT, ^lock, _reason} ->
          {:error, "the lock of the data folder is lost; the server stopped"}

        {:EXIT, pid, reason} when pid in [core, transport] ->
          {:error, "the server stopped: " <> Helyx.Reason.text(reason)}

        # The stop of the supervisor is the stop of the VM.
        {:EXIT, ^supervisor, _reason} ->
          :ok
      end

    stop([transport, core], lock, dir, result)
  end

  # The parts stop in order, the transport before Core, so no client is
  # served while Core stops; a part that ended already is skipped. Then the
  # holder of the lock removes the file, which a lock that ended does not
  # do, since the file can be the file of the next server, and the lock
  # goes last.
  defp stop(parts, lock, dir, result) do
    Enum.each(parts, &stop_supervisor/1)
    _ = Lock.remove_file(lock, server_file(dir))
    Lock.release(lock)
    result
  end

  # Each part stops with the bound of its own stop, with no kill: Core
  # stops only after the last connection (docs/features/serve.md, Bounds).
  defp stop_supervisor(pid) do
    Supervisor.stop(pid)
  catch
    :exit, _gone -> :ok
  end
end
