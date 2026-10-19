defmodule CodingAgent.AttachTest do
  # Not async: the server runs Core under its default name, and a VM runs
  # one server.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO
  import Helyx.Test.Events, only: [wait_until: 1]

  import Helyx.Test.WireClient,
    only: [fake_challenge: 1, fake_server: 1, fake_upgrade: 1, server_frame: 3, client_frame: 1]

  alias CodingAgent.{Attach, CLI, Serve}
  alias Helyx.Session.Lock
  alias Helyx.Test.WireClient
  alias Helyx.Transport.WebSocket

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    sessions = Path.join(dir, "sessions")
    Application.put_env(:coding_agent, :sessions_dir, sessions)
    on_exit(fn -> Application.delete_env(:coding_agent, :sessions_dir) end)

    on_exit(fn ->
      if server = Process.whereis(Serve),
        do: Task.Supervisor.terminate_child(CodingAgent.Servers, server)
    end)

    %{sessions: sessions, server_file: Path.join(sessions, "server.json")}
  end

  defp data_folder(sessions) do
    File.mkdir_p!(sessions)
    File.chmod!(sessions, 0o700)
  end

  # The server file of a server at `port` on loopback.
  defp write_file(file, port, token \\ "the-token"),
    do: File.write!(file, JSON.encode!(%{address: "127.0.0.1", port: port, token: token}))

  # A fake server that passes the upgrade and the challenge, reads the
  # hello, and answers `frame`.
  defp fake(frame) do
    fake_server(fn socket ->
      fake_upgrade(socket)
      fake_challenge(socket)
      _hello = client_frame(socket)
      :ok = :gen_tcp.send(socket, server_frame(1, 1, JSON.encode!(frame)))
      Process.sleep(:infinity)
    end)
  end

  defp hold_lock(sessions) do
    {:ok, lock} = Lock.take(Path.join(sessions, "server"))
    lock
  end

  # A run of `helyx` that ends with one line on stderr and the status 1.
  defp helyx(argv) do
    assert {1, line} = with_io(:stderr, fn -> CLI.main(argv) end)
    line
  end

  test "attaches to a running server, and the socket takes requests; a stopped server is none",
       %{sessions: sessions, server_file: file} do
    task =
      Task.async(fn ->
        with_io(:stderr, fn -> with_io(fn -> CLI.main(["serve", "--model", "fake/echo"]) end) end)
      end)

    wait_until(fn -> match?({:ok, "{" <> _}, File.read(file)) end)

    assert {:ok, socket} = Attach.connect(sessions)

    assert %{"ok" => true, "result" => %{"sessions" => []}} =
             WireClient.request(socket, "1", "sessions.live", %{})

    :ok = Task.Supervisor.terminate_child(CodingAgent.Servers, Process.whereis(Serve))
    assert {{0, _out}, ""} = Task.await(task, 60_000)

    assert Attach.connect(sessions) == :none
  end

  # The TUI needs a terminal, so these runs of `helyx` end before it. The
  # server runs its Core in this VM under the default name, so a run in the
  # node would fail its start: each line comes over the wire, or from the
  # find of a `--session` id, as in the node.
  test "helyx attaches to a running server: the start and the resume go over the wire",
       %{tmp_dir: dir, sessions: sessions, server_file: file} do
    task =
      Task.async(fn ->
        with_io(:stderr, fn -> with_io(fn -> CLI.main(["serve", "--model", "fake/echo"]) end) end)
      end)

    wait_until(fn -> match?({:ok, "{" <> _}, File.read(file)) end)

    missing = Helyx.Session.Id.new()
    assert helyx(["--session", missing]) == ~s(helyx: no session "#{missing}"\n)
    assert helyx(["--session", "../x"]) == ~s(helyx: not a session id: "../x"\n)

    assert helyx([dir, "--model", "nope/m"]) ==
             ~s(helyx: could not start the agent: no provider has the id "nope"\n)

    assert helyx([dir, "--resume"]) ==
             "helyx: could not start the agent: no saved session for this directory; " <>
               "start one without --resume\n"

    # `--session` runs in the folder of the header of its session, which
    # is checked before the resume: the live session stays as it was.
    gone = Path.join(dir, "gone")
    File.mkdir_p!(gone)
    {:ok, socket} = Attach.connect(sessions)

    assert %{"ok" => true, "result" => %{"session" => id}} =
             WireClient.request(socket, "1", "start", %{"cwd" => gone})

    File.rmdir!(gone)

    assert helyx(["--session", id]) ==
             ~s(helyx: not a directory: "#{String.slice(gone, -80, 80)}"\n)

    # The capture of the server gets the lines of stderr too.
    :ok = Task.Supervisor.terminate_child(CodingAgent.Servers, Process.whereis(Serve))
    assert {{0, _out}, _stderr} = Task.await(task, 60_000)
  end

  test "with the lock free, a server file is no server and stays; a missing data folder is none",
       %{tmp_dir: dir, sessions: sessions, server_file: file} do
    missing = Path.join(dir, "missing")
    assert Attach.connect(missing) == :none
    refute File.exists?(missing)

    data_folder(sessions)
    port = fake(%{type: "welcome", protocol: WebSocket.protocol()})
    write_file(file, port)
    before = File.read!(file)

    assert Attach.connect(sessions) == :none
    assert File.read!(file) == before
    # The lock is free after the test of it.
    Lock.release(hold_lock(sessions))
  end

  test "a data folder that its group or other users can write is refused", %{sessions: sessions} do
    data_folder(sessions)

    for mode <- [0o720, 0o702] do
      File.chmod!(sessions, mode)

      assert Attach.connect(sessions) ==
               {:error, "other users can write the data folder #{sessions}; run chmod go-w on it"}
    end

    File.chmod!(sessions, 0o755)
    assert Attach.connect(sessions) == :none
  end

  # The Task of the lock test traps exits, so a perl that ends with no
  # answer is seen at its exit, not at the 5,000 ms of the answer. PATH is
  # global to the VM; the module is not async.
  test "a perl that ends with no answer fails the lock test at its exit",
       %{tmp_dir: dir, sessions: sessions} do
    data_folder(sessions)
    path = System.get_env("PATH")
    bin = Path.join(dir, "bin")
    File.mkdir_p!(bin)
    File.write!(Path.join(bin, "perl"), "#!/bin/sh\nexit 0\n")
    File.chmod!(Path.join(bin, "perl"), 0o755)
    System.put_env("PATH", bin)
    on_exit(fn -> System.put_env("PATH", path) end)

    assert Attach.connect(sessions) ==
             {:error, "could not test the lock of the data folder: perl ended with no answer: "}
  end

  test "a lock that is free at a later attempt is no server", %{sessions: sessions} do
    data_folder(sessions)
    lock = hold_lock(sessions)
    test = self()

    spawn_link(fn ->
      Process.sleep(300)
      send(test, :released)
    end)

    # The test process owns the port of the lock, so it releases it.
    task = Task.async(fn -> Attach.connect(sessions) end)
    assert_receive :released
    Lock.release(lock)
    assert Task.await(task, 30_000) == :none
  end

  test "refused gives one line with both protocol numbers, and any other value one line of a contract break, at once",
       %{sessions: sessions, server_file: file} do
    data_folder(sessions)
    lock = hold_lock(sessions)
    ours = WebSocket.protocol()

    # The fake takes one connection, so a retry would end in the wait line.
    write_file(file, fake(%{type: "refused", code: "protocol", server_protocol: ours + 1}))

    assert {:error, line} = Attach.connect(sessions)

    assert line ==
             "the server speaks protocol #{ours + 1}, this client speaks #{ours}; install the same build"

    refute line =~ "the-token"

    # `helyx` prints the line and exits 1.
    write_file(file, fake(%{type: "refused", code: "protocol", server_protocol: ours + 1}))
    assert helyx([]) == "helyx: #{line}\n"

    port = fake(%{type: "refused", code: "protocol", server_protocol: "#{ours + 1}"})
    write_file(file, port)

    assert Attach.connect(sessions) ==
             {:error,
              "could not attach to the server at ws://127.0.0.1:#{port}: the server broke the wire contract"}

    Lock.release(lock)
  end

  test "while the server starts, a refused connection and a file with no token are tried again",
       %{sessions: sessions, server_file: file} do
    data_folder(sessions)
    lock = hold_lock(sessions)

    {:ok, listen} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, closed} = :inet.port(listen)
    :gen_tcp.close(listen)
    write_file(file, closed)

    test = self()

    spawn_link(fn ->
      # The attach finds the closed port first.
      Process.sleep(300)
      File.write!(file, JSON.encode!(%{address: "127.0.0.1", port: closed}))
      Process.sleep(300)
      write_file(file, fake(%{type: "welcome", protocol: WebSocket.protocol()}))
      send(test, :written)
    end)

    assert {:ok, _socket} = Attach.connect(sessions)
    assert_receive :written
    Lock.release(lock)
  end

  @tag :slow
  test "with the lock held and no valid server file, the attach gives up after the wait",
       %{sessions: sessions, server_file: file} do
    data_folder(sessions)
    lock = hold_lock(sessions)

    for {content, reason} <- [
          {nil, "no valid server file"},
          {JSON.encode!(%{address: "127.0.0.1", port: 1}), "the server file holds no token"}
        ] do
      if content, do: File.write!(file, content)

      assert Attach.connect(sessions) ==
               {:error,
                "could not attach to the server of #{sessions} in #{Serve.wait_ms()} ms: #{reason}"}
    end

    Lock.release(lock)
  end
end
