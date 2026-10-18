defmodule CodingAgent.ServeTest do
  # Not async: the server swaps the handler of the VM's signal server, and
  # runs Core under its default name.
  use ExUnit.Case, async: false

  import Bitwise
  import ExUnit.CaptureIO
  import ExUnit.CaptureLog, only: [with_log: 1]
  import Helyx.Test.Secret, only: [refute_secret: 2]
  import Helyx.Test.Events, only: [wait_until: 1, wait_until: 3]

  alias CodingAgent.{CLI, Serve}
  alias Helyx.Session.Lock
  alias Helyx.Test.WireClient

  @moduletag :tmp_dir

  # The boot of a VM up to its server file, on a machine that runs other
  # tests and projects in parallel.
  @load_boot_ms 20_000

  setup %{tmp_dir: dir} do
    sessions = Path.join(dir, "sessions")
    Application.put_env(:coding_agent, :sessions_dir, sessions)
    on_exit(fn -> Application.delete_env(:coding_agent, :sessions_dir) end)
    %{sessions: sessions, server_file: Path.join(sessions, "server.json")}
  end

  # Runs `helyx serve` with `args` in a task; its result is the status,
  # stdout, and stderr.
  defp serve(args) do
    Task.async(fn -> run(args) end)
  end

  defp run(args) do
    parent = self()

    err =
      capture_io(:stderr, fn ->
        out = capture_io(fn -> send(parent, {:status, CLI.main(["serve" | args])}) end)
        send(parent, {:out, out})
      end)

    assert_received {:status, status}
    assert_received {:out, out}
    {status, out, err}
  end

  # The server file once a server wrote it.
  defp ready(file) do
    wait_until(fn -> match?({:ok, "{" <> _}, File.read(file)) end)
    JSON.decode!(File.read!(file))
  end

  # The serve process started Core, and links Core, the transport, and the
  # port of the lock.
  defp serve_process(core) do
    {:parent, server} = Process.info(core, :parent)
    {:links, links} = Process.info(server, :links)
    {server, links}
  end

  # The OTP handler is back, and no handler of a server is left.
  defp assert_otp_handler do
    handlers = :gen_event.which_handlers(:erl_signal_server)
    assert :erl_signal_handler in handlers
    refute Enum.any?(handlers, &match?({Serve.Signal, _}, &1))
  end

  defp stop(task, signal \\ :sigterm) do
    :ok = :gen_event.notify(:erl_signal_server, signal)
    Task.await(task, 60_000)
  end

  test "serve replaces a stale file, takes a client with the token, and a SIGTERM stops it",
       %{tmp_dir: dir, sessions: sessions, server_file: file} do
    File.mkdir_p!(sessions)
    # The files of a server that was killed.
    File.write!(file, "stale")
    File.mkdir_p!(Path.join(sessions, ".server.tmp"))
    File.write!(Path.join(sessions, ".server.tmp/server.json"), "stale")

    task = serve(["--model", "fake/echo"])
    info = ready(file)

    assert %{"address" => "127.0.0.1", "port" => port, "token" => token} = info
    assert info["protocol"] == Helyx.Transport.WebSocket.protocol()
    assert info["pid"] == String.to_integer(System.pid())
    assert map_size(info) == 5
    assert byte_size(Base.url_decode64!(token, padding: false)) == 32
    assert (File.stat!(file).mode &&& 0o777) == 0o600
    refute File.exists?(Path.join(sessions, ".server.tmp"))

    socket = WireClient.open(port, token)
    assert %{"ok" => true} = WireClient.request(socket, "1", "start", %{"cwd" => dir})

    assert %{"ok" => true, "result" => %{"sessions" => [%{"model" => "fake/echo", "id" => id}]}} =
             WireClient.request(socket, "2", "sessions.live", %{})

    # A second signal during the stop does nothing.
    :ok = :gen_event.notify(:erl_signal_server, :sigterm)
    assert {0, out, ""} = stop(task)
    assert out == "helyx: serving on ws://127.0.0.1:#{port}\n"
    refute File.exists?(file)
    assert {:close, _code} = WireClient.until_close(socket)

    # The session persists, the lock is free, and the OTP handler is back.
    assert [_] = Path.wildcard(Path.join([sessions, "*", id <> ".jsonl"]))
    assert {:ok, lock} = Lock.take(Path.join(sessions, "server"))
    Lock.release(lock)
    assert_otp_handler()
  end

  test "a second serve exits 1 and names the address of the first; SIGHUP stops the first",
       %{sessions: sessions, server_file: file} do
    task = serve(["--model", "fake/echo"])
    %{"port" => port} = ready(file)

    # The port at its limit, and an IPv6 host: the arguments pass, and the
    # lock stops the start.
    line = "helyx: a server runs for #{sessions} at ws://127.0.0.1:#{port}\n"
    assert {1, "", ^line} = run(["--host", "::1", "--port", "65535"])

    assert {0, _out, _second_err} = stop(task, :sighup)
    refute File.exists?(file)
  end

  test "a second start reads a server file of #{Serve.max_file_bytes()} bytes",
       %{sessions: sessions, server_file: file} do
    File.mkdir_p!(sessions)
    {:ok, lock} = Lock.take(Path.join(sessions, "server"))

    for port <- [1, 65_535] do
      json = JSON.encode!(%{address: "::1", port: port})
      File.write!(file, json <> String.duplicate(" ", Serve.max_file_bytes() - byte_size(json)))

      line = "helyx: a server runs for #{sessions} at ws://[::1]:#{port}\n"
      assert {1, "", ^line} = run([])
    end

    Lock.release(lock)
  end

  test "a server removes a stale server file once it holds the lock",
       %{sessions: sessions, server_file: file} do
    File.mkdir_p!(sessions)
    File.write!(file, JSON.encode!(%{address: "127.0.0.1", port: 1}))

    # The handler swap comes after the lock: a suspended signal server holds
    # the start there, before the listener.
    signals = Process.whereis(:erl_signal_server)
    :erlang.suspend_process(signals)

    task =
      try do
        task = serve(["--model", "fake/echo"])
        wait_until(fn -> not File.exists?(file) end)
        task
      after
        :erlang.resume_process(signals)
      end

    ready(file)
    assert {0, _out, ""} = stop(task)
  end

  @tag :slow
  test "a second start with no valid server file gives up after the wait",
       %{sessions: sessions, server_file: file} do
    File.mkdir_p!(sessions)
    {:ok, lock} = Lock.take(Path.join(sessions, "server"))
    json = JSON.encode!(%{address: "::1", port: 1})

    line =
      "helyx: a server holds the lock of #{sessions} and gave no address in #{Serve.wait_ms()} ms\n"

    # One byte over the bound, an address that is not an IP address, and a
    # port out of its range on each side.
    for text <- [
          json <> String.duplicate(" ", Serve.max_file_bytes() + 1 - byte_size(json)),
          JSON.encode!(%{address: "\e[2J", port: 1}),
          JSON.encode!(%{address: "::1", port: 0}),
          JSON.encode!(%{address: "::1", port: 65_536})
        ] do
      File.write!(file, text)
      assert {1, "", ^line} = run([])
    end

    Lock.release(lock)
  end

  test "the end of the lock stops the server with 1", %{server_file: file} do
    before = Port.list()
    task = serve(["--model", "fake/echo"])
    ready(file)

    [perl] =
      for port <- Port.list() -- before,
          {:name, name} <- [Port.info(port, :name)],
          Path.basename(to_string(name)) == "perl",
          do: port

    {:os_pid, os_pid} = Port.info(perl, :os_pid)
    {_, 0} = System.cmd("kill", ["-KILL", Integer.to_string(os_pid)])

    line = "helyx: the lock of the data folder is lost; the server stopped\n"
    assert {1, _out, ^line} = Task.await(task, 60_000)
    # With no lock, the file can be the file of the next server: it stays.
    assert File.exists?(file)
    assert_otp_handler()
  end

  # The kill ends Core and the transport, which log their ends.
  @tag capture_log: true
  test "a crash of the serve process gives back the OTP handler", %{server_file: file} do
    task = serve(["--model", "fake/echo"])
    ready(file)
    {server, links} = serve_process(Process.whereis(Helyx.Core))
    refs = for pid <- links, is_pid(pid), do: Process.monitor(pid)
    Process.exit(server, :kill)
    for ref <- refs, do: assert_receive({:DOWN, ^ref, :process, _, _}, 30_000)

    assert {1, _out, "helyx: " <> _} = Task.await(task, 60_000)
    assert_otp_handler()
  end

  test "a data folder that other users can write is refused", %{sessions: sessions} do
    File.mkdir_p!(sessions)

    for mode <- [0o720, 0o702] do
      File.chmod!(sessions, mode)
      line = "helyx: other users can write the data folder #{sessions}; run chmod go-w on it\n"
      assert {1, "", ^line} = run(["--model", "fake/echo"])
    end

    refute File.exists?(Path.join(sessions, "server.lock"))
  end

  # The kill of a part logs the ends of its children.
  @tag capture_log: true
  # The token passes through the serve process only to the transport and
  # the server file: no log of the end of a part and no frame of the serve
  # process holds it (docs/agents/review-checklist.md, the secret in data
  # that a dependency can log).
  test "the end of Core or of the transport stops the server with 1; each start has a new token",
       %{server_file: file} do
    tokens =
      for part <- [:core, :transport] do
        task = serve(["--model", "fake/echo"])
        %{"token" => token} = ready(file)
        core = Process.whereis(Helyx.Core)

        {server, links} = serve_process(core)
        [transport] = for pid <- links, is_pid(pid), pid != core, do: pid
        {:backtrace, frames} = Process.info(server, :backtrace)

        # A stop of the transport ends its listener with no late crash log.
        {result, log} =
          with_log(fn ->
            if part == :core,
              do: Process.exit(core, :kill),
              else: Supervisor.stop(transport, :shutdown)

            Task.await(task, 60_000)
          end)

        assert {1, _out, "helyx: the server stopped: " <> _} = result
        refute File.exists?(file)
        refute_secret(frames <> log, token)
        token
      end

    assert [token, next] = tokens
    assert next != token
  end

  test "a stale server file that the server cannot remove ends the start with 1",
       %{sessions: sessions, server_file: file} do
    File.mkdir_p!(sessions)
    File.write!(Path.join(sessions, "server.lock"), "")
    File.write!(file, "stale")
    File.chmod!(sessions, 0o500)
    on_exit(fn -> File.chmod(sessions, 0o700) end)

    line = "helyx: could not remove the stale server file: permission denied\n"
    assert {1, "", ^line} = run(["--model", "fake/echo"])
    File.chmod!(sessions, 0o700)
    assert {:ok, lock} = Lock.take(Path.join(sessions, "server"))
    Lock.release(lock)
  end

  # The listener logs the port in use.
  @tag capture_log: true
  test "a port in use ends the start with 1 and leaves no file and no lock",
       %{sessions: sessions, server_file: file} do
    {:ok, listen} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, port} = :inet.port(listen)

    line = "helyx: could not listen on ws://127.0.0.1:#{port}: address already in use\n"
    assert {1, "", ^line} = run(["--model", "fake/echo", "--port", "#{port}"])

    refute File.exists?(file)
    assert {:ok, lock} = Lock.take(Path.join(sessions, "server"))
    Lock.release(lock)
    :gen_tcp.close(listen)
  end

  test "a bad default model ends the start with 1; the data folder it made has mode 0700",
       %{sessions: sessions, server_file: file} do
    line = "helyx: could not start the agent: the model ref is not valid; use provider/model\n"
    assert {1, "", ^line} = run(["--model", "nope"])
    refute File.exists?(file)
    assert (File.stat!(sessions).mode &&& 0o777) == 0o700
  end

  test "the arguments of serve are checked before any start", %{tmp_dir: dir, sessions: sessions} do
    for {argv, text} <- [
          {["--port", "1"], "--port needs serve"},
          {["--host", "::1", dir], "--host needs serve"},
          {["serve", "x"], ~s(serve takes no directory argument, got: ["x"])},
          {["serve", "--port", "65536"], "--port takes 0 to 65535, got: 65536"},
          {["serve", "--port=-1"], "--port takes 0 to 65535, got: -1"},
          {["serve", "--host", "localhost"], ~s(--host takes an IP address, got: "localhost")},
          {["serve", "--resume"], "--resume does not combine with serve"},
          {["serve", "-p", "x"], "--print does not combine with serve"}
        ] do
      assert capture_io(:stderr, fn -> assert CLI.main(argv) == 1 end) == "helyx: #{text}\n"
    end

    refute File.exists?(sessions)
  end

  @tag :slow
  test "a real SIGTERM or SIGHUP stops a serve VM with 0 and removes its file", %{tmp_dir: dir} do
    for signal <- ["TERM", "HUP"], do: real_stop(Path.join(dir, signal), signal)
  end

  defp real_stop(dir, signal) do
    File.mkdir_p!(dir)
    paths = Enum.flat_map(:code.get_path(), &["-pa", List.to_string(&1)])
    code = ~s|System.halt(CodingAgent.CLI.main(["serve", "--model", "fake/echo"]))|
    script = ~S|"$@" >"$0/out" 2>"$0/err" </dev/null; echo $? >"$0/status"|

    Port.open({:spawn_executable, System.find_executable("sh")}, [
      :binary,
      :nouse_stdio,
      args: ["-c", script, dir, System.find_executable("elixir")] ++ paths ++ ["-e", code],
      env: [{~c"HOME", String.to_charlist(dir)}]
    ])

    file = Path.join(dir, ".helyx/sessions/server.json")
    wait_until(fn -> File.exists?(file) end, @load_boot_ms, "no server file")
    %{"pid" => pid, "port" => port} = JSON.decode!(File.read!(file))
    {_, 0} = System.cmd("kill", ["-" <> signal, Integer.to_string(pid)])

    status = Path.join(dir, "status")
    wait_until(fn -> File.read(status) == {:ok, "0\n"} end, @load_boot_ms, "no status 0")
    refute File.exists?(file)
    assert File.read!(Path.join(dir, "out")) == "helyx: serving on ws://127.0.0.1:#{port}\n"
  end
end
