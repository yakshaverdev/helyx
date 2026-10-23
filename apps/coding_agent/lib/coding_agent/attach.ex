defmodule CodingAgent.Attach do
  @moduledoc """
  The client side of `helyx serve`: finds the server of a data folder by its
  server file and its lock, or starts one with the launcher, and connects
  to it over the wire (`Helyx.TUI.Wire`). The rules are in
  `docs/features/tui-attach.md`.
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
    with :ok <- folder(dir), do: attempt(dir, deadline(), :none)
  end

  @doc """
  Starts `helyx serve` for the data folder `dir` in the background with
  the launcher at the path `launcher`, then connects to it as
  `connect/1` does while a server starts; until the server takes the lock,
  a free lock means that it is starting too
  (`docs/features/tui-attach.md`, decision 10). The server runs in a
  session of its own, so no signal of the terminal reaches it, with stdin
  on `/dev/null` and its output added to `<dir>/server.log`, which must be
  a regular file or not there. The folder is made with mode 0700 when it
  is not there. perl must be on the PATH: `CodingAgent.CLI` checks it
  before a start. Returns `{:ok, socket}` or `{:error, text}`.
  """
  @spec start(Path.t(), Path.t()) :: {:ok, :gen_tcp.socket()} | {:error, String.t()}
  def start(dir, launcher) do
    log = Path.join(dir, "server.log")

    with :ok <- Serve.mkdir(dir),
         :ok <- spawn_server(launcher, log),
         do: attempt(dir, deadline(), {:starting, "the server did not start; see #{log}"})
  end

  defp deadline, do: System.monotonic_time(:millisecond) + Serve.wait_ms()

  # perl forks the server and exits at once; the child leaves the session
  # of the terminal (`setsid`), so it is in a new process group too, and
  # execs the launcher. An error of the child goes to the log. The open
  # does not wait, as the lock does not: a FIFO at the path of the log
  # fails it, or the check of a regular file.
  @spawn ~S"""
  use POSIX ();
  use Fcntl;
  my ($launcher, $log) = @ARGV;
  sysopen(my $out, $log, O_WRONLY | O_APPEND | O_CREAT | O_NONBLOCK, 0600) or die "$log: $!\n";
  -f $out or die "$log: not a regular file\n";
  my $pid = fork // die "fork: $!\n";
  exit 0 if $pid;
  POSIX::setsid();
  open(STDIN, "<", "/dev/null") && open(STDOUT, ">&", $out) && open(STDERR, ">&", $out)
    or die "helyx: $!\n";
  exec { $launcher } $launcher, "serve" or die "helyx: $launcher: $!\n";
  """

  # `CodingAgent.CLI` starts a server only with perl on the PATH. `--`
  # keeps a launcher path that starts with `-` an argument.
  defp spawn_server(launcher, log) do
    case System.cmd("perl", ["-e", @spawn, "--", launcher, log], stderr_to_stdout: true) do
      {_out, 0} -> :ok
      {out, _status} -> {:error, "could not start a server: " <> last_line(out)}
    end
  end

  # perl dies with one line, after any warning of its own, such as one of
  # a locale that is not there.
  defp last_line(out) do
    out |> String.trim() |> String.split("\n") |> List.last()
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

  # `free` is the answer to a free lock: `:none`, or for a server that the
  # client started `{:starting, reason}`, an attempt again.
  defp attempt(dir, deadline, free) do
    case {test_lock(dir), free} do
      {true, _free} -> read(dir, deadline, free)
      {false, :none} -> :none
      {false, {:starting, text}} -> again(dir, deadline, free, text)
      {error, _free} -> error
    end
  end

  defp read(dir, deadline, free) do
    case Serve.read_file(dir) do
      {:ok, ip, port, token} when is_function(token) -> open(dir, deadline, free, ip, port, token)
      {:ok, _ip, _port, nil} -> again(dir, deadline, free, "the server file holds no token")
      :error -> again(dir, deadline, free, "no valid server file")
    end
  end

  defp open(dir, deadline, free, ip, port, token) do
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
        again(dir, deadline, free, text)
    end
  end

  # The deadline is checked after the sleep, so no attempt starts past it.
  defp again(dir, deadline, free, text) do
    Process.sleep(@poll_ms)

    if System.monotonic_time(:millisecond) < deadline,
      do: attempt(dir, deadline, free),
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
