defmodule CodingAgent.ServeTest do
  # Not async: the server runs Core under its default name, and a VM runs
  # one server.
  use ExUnit.Case, async: false

  import Bitwise
  import ExUnit.CaptureIO
  import ExUnit.CaptureLog, only: [with_log: 1]
  import Helyx.Test.Secret, only: [refute_secret: 2]
  import Helyx.Test.Events, only: [wait_until: 1, wait_until: 3]

  alias CodingAgent.{CLI, Serve}
  alias Helyx.Session.Lock
  alias Helyx.Test.WireClient
  alias Helyx.Transport.WebSocket

  @moduletag :tmp_dir

  # The boot of a VM up to its server file, on a machine that runs other
  # tests and projects in parallel.
  @load_boot_ms 20_000
  # The run of a second start around its waits, on a loaded machine.
  @load_ms 1_000

  setup %{tmp_dir: dir} do
    sessions = Path.join(dir, "sessions")
    Application.put_env(:coding_agent, :sessions_dir, sessions)
    on_exit(fn -> Application.delete_env(:coding_agent, :sessions_dir) end)

    # A test that fails leaves no server for the next one.
    on_exit(fn ->
      if server = Process.whereis(Serve),
        do: Task.Supervisor.terminate_child(CodingAgent.Servers, server)
    end)

    %{sessions: sessions, server_file: Path.join(sessions, "server.json")}
  end

  # Runs `helyx serve` with `args` in a task; its result is the status,
  # stdout, and stderr.
  defp serve(args) do
    Task.async(fn -> run(args) end)
  end

  defp run(args) do
    {{status, out}, err} =
      with_io(:stderr, fn -> with_io(fn -> CLI.main(["serve" | args]) end) end)

    {status, out, err}
  end

  # A data folder of the test, with the mode that the server makes.
  defp data_folder(sessions) do
    File.mkdir_p!(sessions)
    File.chmod!(sessions, 0o700)
  end

  # The perl process of the lock that the serve process took.
  defp lock_port(before) do
    Enum.find(Port.list() -- before, fn port ->
      case Port.info(port, :name) do
        {:name, name} -> Path.basename(to_string(name)) == "perl"
        nil -> false
      end
    end)
  end

  defp kill_lock(port) do
    {:os_pid, os_pid} = Port.info(port, :os_pid)
    {_, 0} = System.cmd("kill", ["-KILL", Integer.to_string(os_pid)])
  end

  # The name goes with the serve process, after it sent its result.
  defp free, do: wait_until(fn -> Process.whereis(Serve) == nil end)

  # The server file once a server wrote it.
  defp ready(file) do
    wait_until(fn -> match?({:ok, "{" <> _}, File.read(file)) end)
    JSON.decode!(File.read!(file))
  end

  # The serve process, and the Core and the transport that it links; its
  # other links are its supervisor and the port of the lock.
  defp parts do
    server = Process.whereis(Serve)
    core = Process.whereis(Helyx.Core)
    {:links, links} = Process.info(server, :links)
    supervisor = Process.whereis(CodingAgent.Servers)
    [transport] = for pid <- links, is_pid(pid), pid not in [core, supervisor], do: pid
    {server, core, transport}
  end

  # The stop of the VM reaches the server as the stop of its supervisor,
  # which `init:stop/0` runs: the slow test sends a real SIGTERM.
  defp stop(task) do
    :ok = Task.Supervisor.terminate_child(CodingAgent.Servers, Process.whereis(Serve))
    Task.await(task, 60_000)
  end

  # The calls of `functions` that the processes which the run starts make,
  # in their order; `fun` runs with the trace on.
  defp calls(functions, fun) do
    for {m, f, a} <- functions do
      Code.ensure_loaded!(m)
      :erlang.trace_pattern({m, f, a}, true, [:local])
    end

    :erlang.trace(:new_processes, true, [:call])

    try do
      result = fun.()
      :erlang.trace(:new_processes, false, [:call])
      {result, traces()}
    after
      :erlang.trace(:new_processes, false, [:call])
      for {m, f, a} <- functions, do: :erlang.trace_pattern({m, f, a}, false, [:local])
    end
  end

  # The trace messages that the VM has sent so far, all of them.
  defp traces do
    ref = :erlang.trace_delivered(:all)

    receive do
      {:trace_delivered, :all, ^ref} -> :ok
    end

    drain()
  end

  defp drain do
    receive do
      {:trace, _, _, _} = trace -> [trace | drain()]
      {:trace, _, _, _, _} = trace -> [trace | drain()]
    after
      0 -> []
    end
  end

  test "serve replaces a stale file, takes a client with the token, and the stop of the VM stops it",
       %{tmp_dir: dir, sessions: sessions, server_file: file} do
    data_folder(sessions)
    # The files of a server that was killed.
    File.write!(file, "stale")
    File.write!(file <> ".tmp", "stale")

    handlers = :gen_event.which_handlers(:erl_signal_server)
    task = serve(["--model", "fake/echo"])
    info = ready(file)
    # The server leaves the signal server as it is.
    assert :gen_event.which_handlers(:erl_signal_server) == handlers

    assert %{"address" => "127.0.0.1", "port" => port, "token" => token} = info
    assert info["protocol"] == WebSocket.protocol()
    assert info["pid"] == String.to_integer(System.pid())
    assert map_size(info) == 5
    assert byte_size(Base.url_decode64!(token, padding: false)) == 32
    assert (File.stat!(file).mode &&& 0o777) == 0o600
    refute File.exists?(file <> ".tmp")

    socket = WireClient.open(port, token)
    assert %{"ok" => true} = WireClient.request(socket, "1", "start", %{"cwd" => dir})

    assert %{"ok" => true, "result" => %{"sessions" => [%{"model" => "fake/echo", "id" => id}]}} =
             WireClient.request(socket, "2", "sessions.live", %{})

    assert {0, out, ""} = stop(task)
    assert out == "helyx: serving on ws://127.0.0.1:#{port}\n"
    refute File.exists?(file)
    assert {:close, _code} = WireClient.until_close(socket)

    # The session persists, the lock is free, and the guard is free.
    assert [_] = Path.wildcard(Path.join([sessions, "*", id <> ".jsonl"]))
    assert {:ok, lock} = Lock.take(Path.join(sessions, "server"))
    Lock.release(lock)
    free()
  end

  # A stale file goes once the lock is held, before Core and the listener;
  # the stop runs the transport, Core, the remove of the file by the holder
  # of the lock, and the release, in this order (docs/features/serve.md).
  test "the start and the stop run their steps in order", %{sessions: sessions, server_file: file} do
    data_folder(sessions)
    File.write!(file, "stale")

    {{core, transport}, traces} =
      calls(
        [
          {Lock, :remove_file, 2},
          {Lock, :write_file, 3},
          {Lock, :release, 1},
          {Helyx.Core, :start_link, 1},
          {Supervisor, :stop, 1}
        ],
        fn ->
          task = serve(["--model", "fake/echo"])
          ready(file)
          {_server, core, transport} = parts()
          assert {0, _out, ""} = stop(task)
          {core, transport}
        end
      )

    steps =
      for {:trace, _pid, :call, {m, f, args}} <- traces, m in [Lock, Helyx.Core, Supervisor] do
        case {f, args} do
          {:remove_file, [_lock, ^file]} -> :remove
          {:write_file, [_lock, ^file, _data]} -> :write
          {:release, [_lock]} -> :release
          {:start_link, [_opts]} -> :core
          {:stop, [^transport]} -> :stop_transport
          {:stop, [^core]} -> :stop_core
          _other -> nil
        end
      end

    assert Enum.reject(steps, &is_nil/1) ==
             [:remove, :core, :write, :stop_transport, :stop_core, :remove, :release]
  end

  # A second serve in another VM meets the lock: the slow test and the next
  # one check its line.
  test "a second serve in the VM exits 1 before any step", %{tmp_dir: dir, server_file: file} do
    task = serve(["--model", "fake/echo"])
    ready(file)
    before = File.read!(file)
    other = Path.join(dir, "other")
    Application.put_env(:coding_agent, :sessions_dir, other)

    # The port at its limit, and an IPv6 host: the arguments pass, and the
    # server of the VM stops the start before the data folder and the lock.
    line = "helyx: a server runs in this VM already\n"
    assert {1, "", ^line} = run(["--host", "::1", "--port", "65535"])
    refute File.exists?(other)
    assert File.read!(file) == before

    assert {0, _out, _second_err} = stop(task)
    refute File.exists?(file)
  end

  # The text of the server file of a server at `port` on loopback.
  defp server_json(port),
    do: JSON.encode!(%{address: "127.0.0.1", port: port, token: "the-token"})

  defp write_file(file, port), do: File.write!(file, server_json(port))

  # A fake server of the token `token`. It passes the upgrade and the
  # challenge, and reads the hello. When the proof is right, it answers with
  # the frame `frame`. Else it closes with 4401, as the transport does. It
  # tells the caller, with its port, when it has the hello and when the
  # client closed.
  defp fake(frame, token \\ "the-token") do
    caller = self()

    WireClient.fake_server(fn socket ->
      {:ok, {_ip, port}} = :inet.sockname(socket)
      WireClient.fake_upgrade(socket)
      nonce = WireClient.fake_challenge(socket)
      hello = WireClient.client_frame(socket)
      send(caller, {:hello, port})

      reply =
        if hello["proof"] == WireClient.proof(Base.encode64(nonce), token),
          do: frame,
          else: WireClient.server_frame(1, 8, <<4401::16>>)

      :ok = :gen_tcp.send(socket, reply)
      {:error, :closed} = :gen_tcp.recv(socket, 0)
      send(caller, {:closed, port})
    end)
  end

  defp welcome do
    json = JSON.encode!(%{type: "welcome", protocol: WebSocket.protocol()})
    WireClient.server_frame(1, 1, json)
  end

  # Server files that a read refuses, each with a token: one byte over the
  # bound, an address that is not an IP address, and a port out of its range
  # on each side. The first two name `port`.
  defp invalid_files(port) do
    json = server_json(port)

    [
      json <> String.duplicate(" ", Serve.max_file_bytes() + 1 - byte_size(json)),
      JSON.encode!(%{address: "\e[2J", port: port, token: "the-token"}),
      server_json(0),
      server_json(65_536)
    ]
  end

  # A port with no listener, as the port of a server that was killed.
  defp closed_port do
    {:ok, listen} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, port} = :inet.port(listen)
    :gen_tcp.close(listen)
    port
  end

  # Counts each connection that it takes, closes it at once, and tells
  # `caller` the count when the listen socket ends.
  defp close_each(listen, caller, count \\ 0) do
    case :gen_tcp.accept(listen) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        close_each(listen, caller, count + 1)

      {:error, :closed} ->
        send(caller, {:closed_each, count})
    end
  end

  test "a second start reads a server file of #{Serve.max_file_bytes()} bytes",
       %{sessions: sessions, server_file: file} do
    data_folder(sessions)
    {:ok, lock} = Lock.take(Path.join(sessions, "server"))
    port = fake(welcome())
    json = server_json(port)
    File.write!(file, json <> String.duplicate(" ", Serve.max_file_bytes() - byte_size(json)))

    line = "helyx: a server runs for #{sessions} at ws://127.0.0.1:#{port}\n"
    assert {1, "", ^line} = run([])

    # The port at each end of its range, and an IPv6 address.
    for port <- [1, 65_535] do
      File.write!(file, JSON.encode!(%{address: "::1", port: port}))
      assert {:ok, {0, 0, 0, 0, 0, 0, 0, 1} = ip, ^port, nil} = Serve.read_file(sessions)
      assert Serve.url(ip, port) == "ws://[::1]:#{port}"
    end

    # The files that a read refuses, each with a token. The slow test gives
    # each to a second start.
    for text <- invalid_files(port) do
      File.write!(file, text)
      assert Serve.read_file(sessions) == :error
    end

    Lock.release(lock)
  end

  # The server file is a hint and the handshake is the proof (#777): from
  # the `flock` of a new server to its remove of a stale file, the file
  # names a server that was killed.
  test "a second start names an address only after the handshake with its token",
       %{sessions: sessions, server_file: file} do
    data_folder(sessions)
    {:ok, lock} = Lock.take(Path.join(sessions, "server"))
    refused = %{type: "refused", code: "protocol", server_protocol: WebSocket.protocol() + 1}
    # A server of another token, which refuses the proof, a server of
    # another protocol, whose refusal comes before the check of the proof,
    # and the server of the lock.
    proof = fake(welcome(), "another-token")
    protocol = fake(WireClient.server_frame(1, 1, JSON.encode!(refused)))
    live = fake(welcome())

    # The file of a server that was killed comes first; the slow test below
    # checks it alone. Each fake takes one connection, so the next file is
    # written after the hello of the fake before it.
    write_file(file, closed_port())
    task = serve([])
    Process.sleep(300)
    write_file(file, proof)
    assert_receive {:hello, ^proof}
    write_file(file, protocol)
    assert_receive {:hello, ^protocol}
    write_file(file, live)

    line = "helyx: a server runs for #{sessions} at ws://127.0.0.1:#{live}\n"
    assert {1, "", ^line} = Task.await(task, 60_000)
    # The second start closes its connection after `welcome`.
    assert_receive {:closed, ^live}
    Lock.release(lock)
  end

  @tag :slow
  test "a second start with no valid server file gives up after the wait",
       %{sessions: sessions, server_file: file} do
    data_folder(sessions)
    {:ok, lock} = Lock.take(Path.join(sessions, "server"))

    line =
      "helyx: a server holds the lock of #{sessions} and gave no address in #{Serve.wait_ms()} ms\n"

    # A server that would welcome the token of the files.
    live = fake(welcome())

    # The files that a read refuses, the file of a server that was killed,
    # and a file with no token.
    for text <-
          invalid_files(live) ++
            [
              server_json(closed_port()),
              JSON.encode!(%{address: "127.0.0.1", port: live})
            ] do
      File.write!(file, text)
      assert {1, "", ^line} = run([])
    end

    # No second start connected to the server.
    refute_received {:hello, ^live}
    Lock.release(lock)
  end

  # The attempts are at least 100 ms apart, and none starts after the wait,
  # so there are at most 50. Each attempt ends within the bound of its
  # connect.
  @tag :slow
  test "a second start tries again every 100 ms, each connect within its bound",
       %{sessions: sessions, server_file: file} do
    data_folder(sessions)
    {:ok, lock} = Lock.take(Path.join(sessions, "server"))

    line =
      "helyx: a server holds the lock of #{sessions} and gave no address in #{Serve.wait_ms()} ms\n"

    # A program on the port that closes each connection at once.
    {:ok, listen} = :gen_tcp.listen(0, ip: {127, 0, 0, 1}, active: false)
    {:ok, port} = :inet.port(listen)
    caller = self()
    spawn_link(fn -> close_each(listen, caller) end)
    write_file(file, port)
    assert {1, "", ^line} = run([])
    :gen_tcp.close(listen)
    assert_receive {:closed_each, attempts}
    assert attempts in 2..50

    # A program on the port that never answers.
    {:ok, mute} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, port} = :inet.port(mute)
    write_file(file, port)
    start = System.monotonic_time(:millisecond)
    assert {1, "", ^line} = run([])
    elapsed = System.monotonic_time(:millisecond) - start
    # The last attempt starts before the wait ends. Its connect has the
    # bound of 5,000 ms, and a poll of 100 ms comes before it.
    assert elapsed >= Serve.wait_ms()
    assert elapsed < Serve.wait_ms() + 100 + 5_000 + @load_ms
    :gen_tcp.close(mute)
    Lock.release(lock)
  end

  test "the end of the lock stops the server with 1", %{server_file: file} do
    before = Port.list()
    task = serve(["--model", "fake/echo"])
    ready(file)

    kill_lock(lock_port(before))

    line = "helyx: the lock of the data folder is lost; the server stopped\n"
    assert {1, _out, ^line} = Task.await(task, 60_000)
    # With no lock, the file can be the file of the next server: it stays.
    assert File.exists?(file)
    free()
  end

  test "a data folder that other users can write is refused", %{sessions: sessions} do
    data_folder(sessions)

    for mode <- [0o720, 0o702] do
      File.chmod!(sessions, mode)
      line = "helyx: other users can write the data folder #{sessions}; run chmod go-w on it\n"
      assert {1, "", ^line} = run(["--model", "fake/echo"])
    end

    refute File.exists?(Path.join(sessions, "server.lock"))
  end

  # The token passes through the serve process only to the transport and
  # the server file: no log of the end of a part and no frame of the serve
  # process holds it (docs/agents/review-checklist.md, the secret in data
  # that a dependency can log). The kill of Core logs the ends of its
  # children.
  @tag capture_log: true
  test "the end of Core or of the transport stops the server with 1; each start has a new token",
       %{server_file: file} do
    tokens =
      for part <- [:core, :transport] do
        task = serve(["--model", "fake/echo"])
        %{"token" => token} = ready(file)
        {server, core, transport} = parts()
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
        free()
        token
      end

    assert [token, next] = tokens
    assert next != token
  end

  # The crash of the serve process ends Core and the transport, which log
  # their ends.
  @tag capture_log: true
  test "a killed serve process ends the run with 1 and frees the guard", %{server_file: file} do
    task = serve(["--model", "fake/echo"])
    ready(file)
    {server, core, transport} = parts()
    refs = for pid <- [core, transport], do: Process.monitor(pid)
    Process.exit(server, :kill)

    assert {1, _out, "helyx: " <> _} = Task.await(task, 60_000)
    # A supervisor ends after its children, so their logs come in the test.
    for ref <- refs, do: assert_receive({:DOWN, ^ref, :process, _, _})
    free()
  end

  # A closed output fails the ready line: the server stops in order, and the
  # holder of the lock removes the file with the token.
  test "a closed output at the ready line stops the server with 1",
       %{sessions: sessions, server_file: file} do
    {:ok, closed} = StringIO.open("")
    {:ok, _} = StringIO.close(closed)

    {status, err} =
      with_io(:stderr, fn ->
        Process.group_leader(self(), closed)
        CLI.main(["serve", "--model", "fake/echo"])
      end)

    assert status == 1
    assert err == "helyx: could not print the address: the output is closed\n"
    refute File.exists?(file)
    free()
    assert {:ok, lock} = Lock.take(Path.join(sessions, "server"))
    Lock.release(lock)
  end

  test "a stale server file that the server cannot remove ends the start with 1",
       %{sessions: sessions, server_file: file} do
    data_folder(sessions)
    File.write!(Path.join(sessions, "server.lock"), "")
    File.write!(file, "stale")
    File.chmod!(sessions, 0o500)
    on_exit(fn -> File.chmod(sessions, 0o700) end)

    line = "helyx: could not remove the stale server file: Permission denied\n"
    assert {1, "", ^line} = run(["--model", "fake/echo"])
    File.chmod!(sessions, 0o700)
    assert {:ok, lock} = Lock.take(Path.join(sessions, "server"))
    Lock.release(lock)
  end

  # The guard is the name of the serve process, which its supervisor owns:
  # a caller that ends leaves its server, and a second server, in another
  # data folder, is refused until the first one ends.
  test "a second server in the VM is refused, also after its caller ended",
       %{tmp_dir: dir, server_file: file} do
    task = serve(["--model", "fake/echo"])
    ready(file)
    nil = Task.shutdown(task, :brutal_kill)
    other = Path.join(dir, "other")

    assert {:error, "a server runs in this VM already"} =
             Serve.run(sessions_dir: other, model: "fake/echo", ip: {127, 0, 0, 1}, port: 0)

    refute File.exists?(other)

    # The first server still serves, and stops with the VM.
    server = Process.whereis(Serve)
    ref = Process.monitor(server)
    :ok = Task.Supervisor.terminate_child(CodingAgent.Servers, server)
    assert_receive {:DOWN, ^ref, :process, _, _}
    refute File.exists?(file)
  end

  # The token is in one call only, the command that writes the server file
  # in the holder of the lock, and the stack of the serve process holds it
  # at no wait for an answer of the lock. A start that fails during the
  # write (perl cannot make the file) gives no crash report; its line and
  # its logs hold no form of the token.
  test "a start that fails during the write keeps the token out of every output",
       %{sessions: sessions} do
    data_folder(sessions)
    File.write!(Path.join(sessions, "server.lock"), "")
    File.chmod!(sessions, 0o500)
    on_exit(fn -> File.chmod(sessions, 0o700) end)

    # Each wait of the serve process for an answer of the lock sends its
    # stack; every port command shows its data.
    dump = [{:_, [], [{:message, {:process_dump}}]}]
    Code.ensure_loaded!(Lock)
    :erlang.trace_pattern({Lock, :read_answer, 2}, dump, [:local])
    :erlang.trace_pattern({:erlang, :port_command, :_}, true, [])
    :erlang.trace(:new_processes, true, [:call])

    {{result, traces}, log} =
      try do
        with_log(fn ->
          result = run(["--model", "fake/echo"])
          :erlang.trace(:new_processes, false, [:call])
          {result, traces()}
        end)
      after
        :erlang.trace(:new_processes, false, [:call])
        :erlang.trace_pattern({Lock, :read_answer, 2}, false, [:local])
        :erlang.trace_pattern({:erlang, :port_command, :_}, false, [])
      end

    line = "helyx: could not write the server file: Permission denied\n"
    assert {1, "", ^line} = result

    commands =
      for {:trace, _pid, :call, {:erlang, :port_command, [_port, data | _]}} <- traces,
          do: IO.iodata_to_binary(data)

    [token] =
      for <<"w", n::32, _path::binary-size(n), m::32, json::binary-size(m)>> <- commands,
          do: JSON.decode!(json)["token"]

    stacks = for {:trace, _pid, :call, {Lock, :read_answer, _}, stack} <- traces, do: stack
    assert length(stacks) >= 3
    assert [_] = Enum.filter(commands, &String.contains?(&1, token))
    refute_secret(Enum.join(stacks) <> line <> log, token)
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

  # A VM with no launcher, as `mix helyx serve`: the OTP answer to SIGTERM
  # stops it in order. A second start in this VM meets the lock of the other
  # VM and names its address.
  @tag :slow
  test "a real SIGTERM stops a serve VM with 0; a start in another VM names its address",
       %{tmp_dir: dir} do
    paths = Enum.flat_map(:code.get_path(), &["-pa", List.to_string(&1)])
    code = ~s|System.halt(CodingAgent.CLI.main(["serve", "--model", "fake/echo"]))|
    script = ~S|"$@" >"$0/out" 2>"$0/err" </dev/null; echo $? >"$0/status"|

    Port.open({:spawn_executable, System.find_executable("sh")}, [
      :binary,
      :nouse_stdio,
      args: ["-c", script, dir, System.find_executable("elixir")] ++ paths ++ ["-e", code],
      env: [{~c"HOME", String.to_charlist(dir)}]
    ])

    sessions = Path.join(dir, ".helyx/sessions")
    file = Path.join(sessions, "server.json")
    status = Path.join(dir, "status")
    wait_until(fn -> File.exists?(file) end, @load_boot_ms, "no server file")
    %{"pid" => pid, "port" => port} = JSON.decode!(File.read!(file))

    # A test that fails before the stop leaves no VM; a VM that wrote its
    # status has ended.
    on_exit(fn ->
      if not File.exists?(status),
        do: System.cmd("kill", ["-KILL", "#{pid}"], stderr_to_stdout: true)
    end)

    Application.put_env(:coding_agent, :sessions_dir, sessions)
    line = "helyx: a server runs for #{sessions} at ws://127.0.0.1:#{port}\n"
    assert {1, "", ^line} = run([])

    {_, 0} = System.cmd("kill", ["-TERM", Integer.to_string(pid)])
    wait_until(fn -> File.read(status) == {:ok, "0\n"} end, @load_boot_ms, "no status 0")
    refute File.exists?(file)

    # The OTP handler logs the SIGTERM after the ready line.
    ready = "helyx: serving on ws://127.0.0.1:#{port}\n"
    assert ^ready <> rest = File.read!(Path.join(dir, "out"))
    assert rest =~ "SIGTERM received - shutting down"
  end
end
