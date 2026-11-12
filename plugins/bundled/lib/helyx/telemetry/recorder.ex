defmodule Helyx.Telemetry.Recorder do
  @moduledoc """
  Records the events of `events/0` as JSON lines in a file that a product
  opens. It implements no interface: a product starts it, and a server keeps
  its events with no collector (`docs/features/provider-telemetry.md`).

      children = [
        {Helyx.Telemetry.Recorder, []},
        # ...
      ]

  The recorder starts closed: it drops every event until `open/3`, and
  again after `close/1`. Each line holds the time, the event name, the
  duration of the measurement, and only the keys of the event contract, so
  content that an event carries in a later slice cannot leak through it. One
  older file, `<path>.0`, is kept at each rotation.
  """

  use GenServer
  require Logger

  # The longest that a provider call waits on a write: past it the line is
  # dropped and the call goes on.
  @call_ms 1_000

  # The range of a file cap. A cap under a kilobyte holds no useful history,
  # and a cap over a gibibyte is not a log file.
  @min_max_bytes 4_096
  @max_max_bytes 1_073_741_824

  # The keys of an event that the recorder writes. A key outside the list is
  # not written: the recorder writes only what the contract names.
  @keys ~w(provider model attempt status error decision wait_ms)a

  @typedoc "The name of the recorder that a caller uses."
  @type server() :: GenServer.server()

  @doc """
  The events that the recorder writes. This is the one list of recorded
  events; a later slice adds names here.
  """
  @spec events() :: [[atom()]]
  def events, do: [[:helyx, :provider, :attempt]]

  @doc """
  Starts the recorder with the name `opts[:name]`, default `#{inspect(__MODULE__)}`.
  It attaches one handler to `events/0` and starts closed.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, name, name: name)
  end

  @doc """
  Opens `path` for the lines of the recorder `server`, and keeps at most
  `max_bytes` bytes in the file before a rotation to `<path>.0`. `path` must
  be absolute and a regular file, or not exist; `max_bytes` must be an
  integer from `#{@min_max_bytes}` to `#{@max_max_bytes}`. A file that is
  open is closed first.
  """
  @spec open(server(), Path.t(), pos_integer()) ::
          :ok | {:error, File.posix() | :not_regular}
  def open(server \\ __MODULE__, path, max_bytes),
    do: GenServer.call(server, {:open, path, max_bytes})

  @doc """
  Closes the file of the recorder `server`. The recorder stays, and drops
  the lines that follow.
  """
  @spec close(server()) :: :ok
  def close(server \\ __MODULE__), do: GenServer.call(server, :close)

  @doc "The file of the recorder `server`, or nil when none is open."
  @spec path(server()) :: Path.t() | nil
  def path(server \\ __MODULE__), do: GenServer.call(server, :path)

  @doc false
  # One JSON object and a newline: the time with milliseconds, the event
  # name, the duration in milliseconds, then the keys of the contract.
  @spec line([atom()], map(), map()) :: iodata()
  def line(event, measurements, metadata) do
    event
    |> base()
    |> put_ms(measurements)
    |> put_meta(metadata)
    |> JSON.encode!()
    |> then(&[&1, "\n"])
  end

  @doc false
  # A handler must never raise: `:telemetry` detaches a handler that raises.
  # The line is built in the caller, which keeps the call short.
  @spec handle_event([atom()], map(), map(), %{server: server()}) :: :ok
  def handle_event(event, measurements, metadata, %{server: server}) do
    line = line(event, measurements, metadata)
    GenServer.call(server, {:write, line}, @call_ms)
  catch
    :exit, _ -> :ok
  end

  @impl true
  def init(name) do
    # The supervisor stops the recorder with a shutdown exit, and the file
    # and the handler go with it.
    Process.flag(:trap_exit, true)

    :ok =
      :telemetry.attach_many(
        {__MODULE__, name},
        events(),
        &__MODULE__.handle_event/4,
        %{server: name}
      )

    {:ok, new(name)}
  end

  @impl true
  def handle_call({:open, path, max_bytes}, _from, state) do
    state = close_file(state)

    with :ok <- check_path(path),
         :ok <- check_max_bytes(max_bytes),
         {:ok, size} <- size(path),
         {:ok, file} <- File.open(path, [:append, :binary, :raw]) do
      {:reply, :ok, %{state | file: file, path: path, size: size, max_bytes: max_bytes}}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:close, _from, state), do: {:reply, :ok, close_file(state)}

  def handle_call(:path, _from, state), do: {:reply, state.path, state}

  def handle_call({:write, line}, _from, state), do: {:reply, :ok, write(state, line)}

  @impl true
  def terminate(_reason, state) do
    _ = :telemetry.detach({__MODULE__, state.server})
    _ = close_file(state)
    :ok
  end

  defp base(event) do
    ts = DateTime.utc_now() |> DateTime.truncate(:millisecond) |> DateTime.to_iso8601()
    %{"ts" => ts, "event" => Enum.join(event, ".")}
  end

  defp put_ms(object, %{duration: duration}) when is_integer(duration),
    do: Map.put(object, "ms", System.convert_time_unit(duration, :native, :millisecond))

  defp put_ms(object, _measurements), do: object

  # Every key of the contract is written, and nil goes as JSON null.
  defp put_meta(object, metadata) do
    Enum.reduce(@keys, object, fn key, object ->
      Map.put(object, Atom.to_string(key), text(Map.get(metadata, key)))
    end)
  end

  defp text(nil), do: nil
  defp text(value) when is_atom(value), do: Atom.to_string(value)
  defp text(value), do: value

  defp check_path(path) do
    if Path.type(path) == :absolute, do: :ok, else: {:error, :einval}
  end

  defp check_max_bytes(max_bytes)
       when is_integer(max_bytes) and max_bytes >= @min_max_bytes and
              max_bytes <= @max_max_bytes,
       do: :ok

  defp check_max_bytes(_max_bytes), do: {:error, :einval}

  # The stat opens nothing, so a FIFO or a folder is refused before an
  # append could block. `:enoent` is the file that the append makes.
  defp size(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular, size: size}} -> {:ok, size}
      {:error, :enoent} -> {:ok, 0}
      {:ok, %File.Stat{}} -> {:error, :not_regular}
      {:error, reason} -> {:error, reason}
    end
  end

  defp write(%{file: nil} = state, _line), do: state

  defp write(state, line) do
    bytes = IO.iodata_length(line)

    state =
      if state.size + bytes > state.max_bytes, do: rotate(state), else: state

    write_line(state, line, bytes)
  end

  defp write_line(%{file: nil} = state, _line, _bytes), do: state

  defp write_line(state, line, bytes) do
    case :file.write(state.file, line) do
      :ok -> %{state | size: state.size + bytes}
      {:error, reason} -> drop(state, state.path, reason)
    end
  end

  # One older file, as the log of the app keeps. The rename replaces an
  # older `.0`; a rename that fails ends the recording with the warning, so
  # the file stays at the cap.
  defp rotate(%{file: file, path: path} = state) do
    _ = :file.close(file)

    with :ok <- File.rename(path, path <> ".0"),
         {:ok, file} <- File.open(path, [:append, :binary, :raw]) do
      %{state | file: file, size: 0}
    else
      {:error, reason} -> drop(closed(state), path, reason)
    end
  end

  # One warning for each open, not one for each line that fails.
  defp drop(%{warned: true} = state, _path, _reason), do: state

  defp drop(state, path, reason) do
    Logger.warning("telemetry: the write of #{path} failed: #{posix(reason)}")
    %{state | warned: true}
  end

  defp posix(reason), do: to_string(:file.format_error(reason))

  defp close_file(%{file: nil} = state), do: state

  defp close_file(%{file: file} = state) do
    _ = :file.close(file)
    closed(state)
  end

  defp new(server),
    do: %{server: server, file: nil, path: nil, size: 0, max_bytes: nil, warned: false}

  defp closed(state),
    do: %{state | file: nil, path: nil, size: 0, max_bytes: nil, warned: false}
end
