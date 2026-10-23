defmodule CodingAgent.AttachTest do
  # Not async: the server runs Core under its default name, and a VM runs
  # one server.
  use ExUnit.Case, async: false

  import Bitwise
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

    # A folder that is not UTF-8 (no JSON form, so no request) or holds a
    # NUL byte gets the answer of the node, and no session starts.
    live = Helyx.Sessions.list_live(Helyx.Core)

    for cwd <- [dir <> <<0xFF>>, dir <> <<0>>] do
      {:ok, socket} = Attach.connect(sessions)
      opts = [resume: false, sessions_dir: sessions, cwd: cwd]
      assert CodingAgent.attach(socket, opts) == {:error, :invalid_cwd}
    end

    assert Helyx.Sessions.list_live(Helyx.Core) == live

    assert helyx(["--session", id]) ==
             ~s(helyx: not a directory: "#{String.slice(gone, -80, 80)}"\n)

    # The capture of the server gets the lines of stderr too.
    :ok = Task.Supervisor.terminate_child(CodingAgent.Servers, Process.whereis(Serve))
    assert {{0, _out}, _stderr} = Task.await(task, 60_000)
  end

  # Each run ends at the model of its session, before the TUI: the default
  # model of the server and the models of the saved sessions name no
  # provider, so the line tells a start from a resume, and which session.
  # The server logs the failed resume of the locked session.
  @tag :capture_log
  test "helyx reattaches to the newest session of its folder; --new and --model start one",
       %{tmp_dir: dir, sessions: sessions, server_file: file} do
    task =
      Task.async(fn ->
        with_io(:stderr, fn -> with_io(fn -> CLI.main(["serve", "--model", "none/m"]) end) end)
      end)

    wait_until(fn -> match?({:ok, "{" <> _}, File.read(file)) end)

    for model <- ["older/m", "newest/m"] do
      {:ok, session} = Helyx.Session.File.create(sessions, Helyx.Session.Id.new(), dir, model)
      Helyx.Test.SessionFile.append_message(session, Helyx.Message.user("p"))
    end

    # A session with no message is not picked, as for --resume.
    empty = Path.join(dir, "empty")
    File.mkdir_p!(empty)
    {:ok, _} = Helyx.Session.File.create(sessions, Helyx.Session.Id.new(), empty, "empty/m")

    no_provider = &"helyx: could not start the agent: no provider has the id \"#{&1}\"\n"

    assert helyx([dir]) ==
             "helyx: could not reattach to the newest session (helyx --new starts one): " <>
               ~s(no provider has the id "newest"\n)

    assert helyx([dir, "--resume"]) == no_provider.("newest")
    assert helyx([dir, "--new"]) == no_provider.("none")
    assert helyx([dir, "--model", "nope/m"]) == no_provider.("nope")
    assert helyx([empty]) == no_provider.("none")

    # A newest session that another OS process has open is not skipped.
    locked = Path.join(dir, "locked")
    File.mkdir_p!(locked)
    {:ok, session} = Helyx.Session.File.create(sessions, Helyx.Session.Id.new(), locked, "x/m")
    Helyx.Test.SessionFile.append_message(session, Helyx.Message.user("p"))
    {:ok, lock} = Lock.take(Path.rootname(session.path))

    assert helyx([locked]) =~
             ~r/^helyx: could not reattach to the newest session \(helyx --new starts one\): .*session_locked/

    Lock.release(lock)

    assert helyx([empty, "--resume"]) ==
             "helyx: could not start the agent: no saved session for this directory; " <>
               "start one without --resume\n"

    assert Helyx.Sessions.list_live(Helyx.Core) == []
    :ok = Task.Supervisor.terminate_child(CodingAgent.Servers, Process.whereis(Serve))
    assert {{0, _out}, _stderr} = Task.await(task, 60_000)
  end

  # A launcher of the test: it writes its arguments, its pid and process
  # group, and its stdin to files of `dir`, prints one line, and then
  # writes `ready`. With a `serve` model, a process of the test runs
  # `helyx serve` in this VM after `ready`, in the place of the server of
  # the launcher.
  defp launcher(dir, serve \\ nil) do
    path = Path.join(dir, "launcher")

    File.write!(path, """
    #!/bin/sh
    printf '%s\\n' "$@" > '#{dir}/args'
    echo $$ $(ps -o pgid= -p $$) > '#{dir}/group'
    cat > '#{dir}/stdin'
    echo launcher output
    : > '#{dir}/ready'
    """)

    File.chmod!(path, 0o755)
    if serve, do: spawn_link(fn -> serve_when_ready(dir, serve) end)
    path
  end

  defp serve_when_ready(dir, model) do
    wait_until(fn -> File.exists?(Path.join(dir, "ready")) end)
    with_io(:stderr, fn -> with_io(fn -> CLI.main(["serve", "--model", model]) end) end)
  end

  test "with no server, a start runs the launcher in the background and attaches to its server",
       %{tmp_dir: dir, sessions: sessions} do
    assert {:ok, socket} = Attach.start(sessions, launcher(dir, "fake/echo"))

    assert %{"ok" => true, "result" => %{"sessions" => []}} =
             WireClient.request(socket, "1", "sessions.live", %{})

    # The launcher got `serve`, a process group and a session of its own,
    # stdin on /dev/null, and its output in the log of the data folder,
    # which the start made with mode 0700.
    assert File.read!(Path.join(dir, "args")) == "serve\n"
    assert [pid, pid] = dir |> Path.join("group") |> File.read!() |> String.split()
    assert File.read!(Path.join(dir, "stdin")) == ""
    assert File.read!(Path.join(sessions, "server.log")) == "launcher output\n"
    assert (File.stat!(sessions).mode &&& 0o777) == 0o700
  end

  # The TUI needs a terminal, so the run ends at the model of the server,
  # which names no provider, before it.
  test "helyx starts a server with the launcher of the release; mix helyx, with none, runs in the node",
       %{tmp_dir: dir, sessions: sessions} do
    System.put_env("HELYX_LAUNCHER", launcher(dir, "none/m"))
    on_exit(fn -> System.delete_env("HELYX_LAUNCHER") end)

    assert helyx([dir]) == ~s(helyx: could not start the agent: no provider has the id "none"\n)
    assert File.read!(Path.join(dir, "args")) == "serve\n"
    assert System.get_env("HELYX_LAUNCHER") == nil

    # With no launcher and no server, the TUI runs in the node, which ends
    # at its model too.
    :ok = Task.Supervisor.terminate_child(CodingAgent.Servers, Process.whereis(Serve))
    wait_until(fn -> Attach.connect(sessions) == :none end)
    File.rm!(Path.join(dir, "args"))

    assert helyx([dir, "--model", "nope/m"]) ==
             ~s(helyx: could not start the agent: no provider has the id "nope"\n)

    refute File.exists?(Path.join(dir, "args"))
  end

  # The open of the log does not wait: a FIFO with no reader would hold
  # it with no bound.
  test "a server.log that is not a regular file fails the start at once",
       %{tmp_dir: dir, sessions: sessions} do
    data_folder(sessions)
    log = Path.join(sessions, "server.log")
    {_, 0} = System.cmd("mkfifo", [log])

    assert {:error, "could not start a server: " <> reason} =
             Attach.start(sessions, launcher(dir))

    assert reason =~ log
    refute File.exists?(Path.join(dir, "args"))
  end

  # A server needs perl, as the node does: the line is that of today.
  test "with no perl on the PATH, helyx gives the line of the node and starts no server",
       %{tmp_dir: dir, sessions: sessions} do
    path = System.get_env("PATH")
    on_exit(fn -> System.put_env("PATH", path) end)
    on_exit(fn -> System.delete_env("HELYX_LAUNCHER") end)
    launcher = launcher(dir)
    empty = Path.join(dir, "bin")
    File.mkdir_p!(empty)
    System.put_env("PATH", empty)

    node = helyx([dir])
    System.put_env("HELYX_LAUNCHER", launcher)
    assert helyx([dir]) == node
    assert node =~ "perl"
    refute File.exists?(Path.join(dir, "args"))
    refute File.exists?(Path.join(sessions, "server.log"))
  end

  # perl writes a warning of a locale that is not there before its error.
  test "the reason of a failed start is the last line of perl", %{
    tmp_dir: dir,
    sessions: sessions
  } do
    data_folder(sessions)
    log = Path.join(sessions, "server.log")
    {_, 0} = System.cmd("mkfifo", [log])
    locale = System.get_env("LC_ALL")
    System.put_env("LC_ALL", "xx_XX.UTF-8")

    on_exit(fn ->
      if locale, do: System.put_env("LC_ALL", locale), else: System.delete_env("LC_ALL")
    end)

    assert {:error, "could not start a server: " <> reason} =
             Attach.start(sessions, launcher(dir))

    assert reason =~ ~r/\A#{Regex.escape(log)}: [^\n]+\z/
  end

  @tag :slow
  test "a launcher that starts no server gives one line after the wait", %{
    tmp_dir: dir,
    sessions: sessions
  } do
    log = Path.join(sessions, "server.log")

    assert Attach.start(sessions, launcher(dir)) ==
             {:error,
              "could not attach to the server of #{sessions} in #{Serve.wait_ms()} ms: " <>
                "the server did not start; see #{log}"}

    assert Attach.start(sessions, Path.join(dir, "missing")) ==
             {:error,
              "could not attach to the server of #{sessions} in #{Serve.wait_ms()} ms: " <>
                "the server did not start; see #{log}"}

    assert File.read!(log) =~ ~r/launcher output\nhelyx: .*missing: No such file or directory\n/
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
