defmodule Helyx.Transport.WebSocket.RunnerTest do
  # The runner of a paired hands connection (`docs/features/remote-hands.md`,
  # "The runner state"): the link, the state file, the pairing and the
  # paired handshake, the registration, `hands.live`, and the reconnect.
  use ExUnit.Case, async: true

  import Bitwise
  import ExUnit.CaptureLog
  import Helyx.Test.Events, only: [wait_until: 1, wait_until: 2]

  alias Helyx.Hub
  alias Helyx.Provider.Fake
  alias Helyx.Transport.WebSocket
  alias Helyx.Transport.WebSocket.{Pairing, TLS}
  alias Helyx.Transport.WebSocket.Runner
  alias Helyx.Transport.WebSocket.Runner.{Connection, Link, State}

  @moduletag :tmp_dir

  # A wait that must happen, past three lease durations of 30,000 ms, on a
  # loaded machine.
  @load_ms 30_000

  defp serve(context, id \\ :server, opts \\ []) do
    core = :"core_#{System.unique_integer([:positive])}"
    start_supervised!({Helyx.Core, name: core, plugins: [Fake]}, id: {id, :core})
    {:ok, tls} = TLS.ensure(context.tmp_dir)

    hub =
      start_supervised!(
        Supervisor.child_spec(
          {Hub,
           core: core,
           default_owner: "owner",
           path: Keyword.get(opts, :hub_path, Path.join(context.tmp_dir, "hub.db"))},
          id: {id, :hub}
        )
      )

    port = Keyword.get(opts, :port, free_port())
    ip = Keyword.get(opts, :public_ip, {127, 0, 0, 1})
    address = Keyword.get(opts, :address, address_text(ip, port))
    public = [ip: ip, port: port, address: address]

    transport =
      start_supervised!(
        {WebSocket,
         [
           core: core,
           port: 0,
           token: "secret",
           public: public,
           tls: tls,
           pairing: hub
         ] ++ Keyword.drop(opts, [:port, :public_ip, :address, :hub_path])},
        id: {id, :transport}
      )

    %{
      core: core,
      hub: hub,
      tls: tls,
      transport: transport,
      port: port,
      address: address,
      pairing: pairing(transport),
      id: id
    }
  end

  defp address_text(ip, port) when tuple_size(ip) == 8,
    do: "[#{:inet.ntoa(ip)}]:#{port}"

  defp address_text(ip, port), do: "#{:inet.ntoa(ip)}:#{port}"

  defp stop_server(id) do
    stop_supervised!({id, :transport})
    stop_supervised!({id, :hub})
    stop_supervised!({id, :core})
  end

  defp pairing(transport) do
    {_, pid, :worker, _} = List.keyfind(Supervisor.which_children(transport), Pairing, 0)
    pid
  end

  defp conn_pid(pairing, name) do
    %{connections: connections} = :sys.get_state(pairing)
    {conn, _monitor} = Map.fetch!(connections, {"hands", name})
    conn
  end

  defp conn_state(pairing, name) do
    {_socket, %{connection: %Bandit.WebSocket.Connection{websock_state: state}}} =
      :sys.get_state(conn_pid(pairing, name))

    state
  end

  defp link(context, name \\ "mac") do
    {:ok, %{"link" => link}} = Pairing.create(context.pairing, "hands", name)
    link
  end

  defp runner_opts(context, opts) do
    folder = Path.join(context.tmp_dir, "project")
    File.mkdir_p!(folder)

    opts
    |> Keyword.put_new(:home, Path.join(context.tmp_dir, "home"))
    |> Keyword.put_new(:folder, folder)
    |> Keyword.put_new(:notify, self())
  end

  defp start_runner(context, opts) do
    {pid, _prepared} = start_prepared(context, opts)
    pid
  end

  defp start_prepared(context, opts) do
    {id, opts} = Keyword.pop(opts, :id, :runner)
    {:ok, prepared} = Runner.prepare(runner_opts(context, opts))
    pid = start_supervised!({Runner, prepared}, id: id)
    {pid, prepared}
  end

  defp ipv6_loopback? do
    match?({:ok, _ip}, :inet.getaddr(~c"::1", :inet6))
  end

  defp wait_connected(pairing, name) do
    wait_until(fn ->
      case Pairing.list(pairing) do
        {:ok, peers} -> Enum.any?(peers, &(&1["name"] == name and &1["connected"] == true))
        _other -> false
      end
    end)
  end

  defp state_json(context, name) do
    JSON.decode!(File.read!(State.path(Path.join(context.tmp_dir, "home"), name)))
  end

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end

  describe "a pairing with a link" do
    setup context, do: Map.merge(context, serve(context))

    test "the runner is connected, and the state file has the modes and the fields", context do
      link = link(context)
      start_runner(context, link: link)
      wait_connected(context.pairing, "mac")
      assert_receive {:hands, {:connected, %{first?: true}}}, 30_000

      assert {:ok, [%{"kind" => "hands", "name" => "mac", "connected" => true}]} =
               Pairing.list(context.pairing)

      path = State.path(Path.join(context.tmp_dir, "home"), "mac")
      assert (File.stat!(path).mode &&& 0o777) == 0o600
      assert (File.stat!(State.dir(Path.join(context.tmp_dir, "home"))).mode &&& 0o777) == 0o700

      json = state_json(context, "mac")
      assert json["address"] == "127.0.0.1:#{context.port}"
      assert json["pin"] == context.tls.pin
      assert json["name"] == "mac"
      assert json["folder"] == Path.join(context.tmp_dir, "project")
      assert byte_size(Base.decode64!(json["key"])) == 32
    end

    test "a second runner connects with the saved key alone", context do
      link = link(context)
      first = start_runner(context, link: link)
      wait_connected(context.pairing, "mac")
      assert_receive {:hands, {:connected, %{first?: true}}}

      stop_supervised!(:runner)
      refute Process.alive?(first)

      start_runner(context, name: "mac", id: :second)
      wait_connected(context.pairing, "mac")
      assert_receive {:hands, {:connected, %{first?: true, name: "mac"}}}
    end

    test "a used link ends with unauthorized and writes no state file", context do
      link = link(context)
      start_runner(context, link: link)
      wait_connected(context.pairing, "mac")

      other = Path.join(context.tmp_dir, "other_home")

      pid = start_runner(context, link: link, home: other, id: :second)

      assert {:error, :unauthorized} = Runner.await(pid)
      refute File.exists?(State.path(other, "mac"))
    end

    test "a wrong pin refuses the connection before any frame", context do
      pin = "not-the-pin"
      link = relink(link(context), &Map.put(&1, "p", pin))
      pid = start_runner(context, link: link)

      assert {:error, :bad_pin} = Runner.await(pid)
      refute File.exists?(State.path(Path.join(context.tmp_dir, "home"), "mac"))
      assert {:ok, []} = Pairing.list(context.pairing)
    end

    test "a folder over the bound is refused before a connection", context do
      link = link(context)
      folder = String.duplicate("a", Pairing.max_folder_bytes() + 1)

      assert {:error, {:folder, :too_long, _folder}} =
               Runner.prepare(
                 link: link,
                 folder: folder,
                 home: Path.join(context.tmp_dir, "home")
               )

      assert {:ok, []} = Pairing.list(context.pairing)
    end

    test "a folder that is not UTF-8 is refused before a connection", context do
      link = link(context)
      folder = Path.join(context.tmp_dir, <<"project", 0xFF>>)

      assert {:error, {:folder, :invalid_utf8, _folder}} =
               Runner.prepare(
                 link: link,
                 folder: folder,
                 home: Path.join(context.tmp_dir, "home")
               )

      assert {:ok, []} = Pairing.list(context.pairing)
    end

    test "a second pairing over an existing state file refuses and keeps it", context do
      first_link = link(context)
      start_runner(context, link: first_link)
      wait_connected(context.pairing, "mac")
      assert_receive {:hands, {:connected, %{first?: true}}}, 30_000

      home = Path.join(context.tmp_dir, "home")
      path = State.path(home, "mac")
      before = File.read!(path)

      second_link = link(context)

      assert {:error, {:state_file, ^path, :exists}} =
               Runner.prepare(
                 link: second_link,
                 folder: Path.join(context.tmp_dir, "project"),
                 home: home
               )

      assert File.read!(path) == before

      # The refused link was not used: it pairs from another home.
      other = Path.join(context.tmp_dir, "other_home")
      start_runner(context, link: second_link, home: other, id: :other)
      wait_connected(context.pairing, "mac")
      assert_receive {:hands, {:connected, %{first?: true}}}, 30_000
    end

    test "a pairing over an IPv6 literal host connects", context do
      if ipv6_loopback?() do
        server =
          serve(context, :v6,
            public_ip: {0, 0, 0, 0, 0, 0, 0, 1},
            hub_path: Path.join(context.tmp_dir, "hub_v6.db")
          )

        link = link(server)

        assert {:ok, %{host: {0, 0, 0, 0, 0, 0, 0, 1}}} = Link.parse(link)

        start_runner(context, link: link)
        wait_connected(server.pairing, "mac")
        assert_receive {:hands, {:connected, %{first?: true}}}, 30_000
      end
    end
  end

  describe "the link" do
    @fields %{
      "a" => "127.0.0.1:4040",
      "t" => "token",
      "p" => "pin",
      "k" => "hands",
      "n" => "mac"
    }

    test "a good link gives its fields" do
      assert {:ok, link} = Link.parse(link_json(@fields))
      assert link.address == "127.0.0.1:4040"
      assert link.host == "127.0.0.1"
      assert link.port == 4040
      assert link.token == "token"
      assert link.pin == "pin"
      assert link.kind == "hands"
      assert link.name == "mac"
    end

    test "each fault has its atom" do
      for {link, atom} <- [
            {"nope", :bad_prefix},
            {"helyx-pair:2:abc", :bad_prefix},
            {"helyx-pair:1:%%%", :bad_encoding},
            {encoded("not json"), :bad_encoding},
            {encoded("[]"), :bad_field},
            {link_json(Map.delete(@fields, "n")), :bad_field},
            {link_json(Map.put(@fields, "n", 1)), :bad_field},
            {link_json(Map.put(@fields, "k", "client")), :bad_kind},
            {link_json(Map.put(@fields, "n", "Mac")), :bad_name},
            {link_json(Map.put(@fields, "n", String.duplicate("a", 65))), :bad_name},
            {link_json(Map.put(@fields, "a", "127.0.0.1:0")), :bad_port},
            {link_json(Map.put(@fields, "a", "127.0.0.1:65536")), :bad_port},
            {link_json(Map.put(@fields, "a", "nope")), :bad_address},
            {link_json(Map.put(@fields, "a", "[::1:4040")), :bad_address}
          ] do
        assert Link.parse(link) == {:error, atom}
      end
    end

    test "the bound counts bytes" do
      at = "h" <> String.duplicate("a", Link.max_bytes() - 1)
      over = "h" <> String.duplicate("a", Link.max_bytes())
      assert Link.parse(at) == {:error, :bad_prefix}
      assert Link.parse(over) == {:error, :link_too_long}
    end

    test "an error holds no token" do
      token = "secret-token-of-the-link"
      bad = link_json(%{@fields | "t" => token, "k" => "client"})

      assert {:error, :bad_kind} = Link.parse(bad)
      refute inspect(Link.parse(bad)) =~ token
    end
  end

  describe "the saved state" do
    setup context do
      home = Path.join(context.tmp_dir, "home")
      name = "mac"

      :ok =
        State.write(
          home,
          name,
          %{address: "127.0.0.1:4040", pin: "pin", folder: "/project"},
          fn ->
            :crypto.strong_rand_bytes(32)
          end
        )

      %{home: home, name: name, path: State.path(home, name)}
    end

    test "a second write never replaces the saved key", %{home: home, name: name, path: path} do
      before = File.read!(path)
      fields = %{address: "127.0.0.1:4041", pin: "pin2", folder: "/other"}

      assert State.write(home, name, fields, fn -> :crypto.strong_rand_bytes(32) end) ==
               {:error, {:state_file, path, :exists}}

      assert File.read!(path) == before
      assert File.ls!(Path.dirname(path)) == [Path.basename(path)]
    end

    test "a good file reads its fields", %{home: home, name: name, path: path} do
      assert {:ok, read} = State.read(home, name)
      assert read.address == "127.0.0.1:4040"
      assert read.pin == "pin"
      assert read.name == "mac"
      assert read.folder == "/project"
      assert is_function(read.sign, 1)
      assert byte_size(read.public_key) == 32

      json = JSON.decode!(File.read!(path))
      signature = read.sign.("the text")
      assert :crypto.verify(:eddsa, :none, "the text", signature, [read.public_key, :ed25519])
      assert byte_size(Base.decode64!(json["key"])) == 32
    end

    test "a symlink is refused and removed", %{path: path, home: home, name: name} do
      real = path <> ".real"
      File.rename!(path, real)
      File.ln_s!(real, path)
      on_exit(fn -> File.rm(path) end)

      assert {:error, {:state_file, ^path, :symlink}} = State.read(home, name)
    end

    test "a loose mode is refused", %{path: path, home: home, name: name} do
      File.chmod!(path, 0o644)
      assert {:error, {:state_file, ^path, :loose_mode}} = State.read(home, name)
      File.chmod!(path, 0o600)
      assert {:ok, _read} = State.read(home, name)
    end

    test "a cut JSON, a missing field, and another name are refused", %{
      path: path,
      home: home,
      name: name
    } do
      write(path, "{")
      assert {:error, {:state_file, ^path, :bad_json}} = State.read(home, name)

      write(path, JSON.encode!(Map.delete(json_fields(), "folder")))
      assert {:error, {:state_file, ^path, :bad_field}} = State.read(home, name)

      write(path, JSON.encode!(Map.put(json_fields(), "name", "other")))
      assert {:error, {:state_file, ^path, :name_mismatch}} = State.read(home, name)
    end

    test "a file over the bound and one that is not regular are refused", %{
      path: path,
      home: home,
      name: name
    } do
      write(path, String.duplicate("a", State.max_bytes() + 1))
      assert {:error, {:state_file, ^path, :too_large}} = State.read(home, name)

      File.rm!(path)
      File.mkdir!(path)
      assert {:error, {:state_file, ^path, :not_regular}} = State.read(home, name)
    end
  end

  describe "the registration and the lease" do
    setup context do
      server = serve(context, :server, hands_lease_ms: 30_000)
      Map.merge(context, server)
    end

    @tag :slow
    @tag timeout: 180_000
    test "the runner answers hands.live past three lease durations", context do
      start_runner(context, link: link(context))
      wait_connected(context.pairing, "mac")

      # The server sends a request each third of the lease and closes the
      # connection at the lease when no answer renews it.
      lease = WebSocket.hands_lease_ms()
      wait_until(fn -> conn_state(context.pairing, "mac").live_seq >= 9 end, 3 * lease + @load_ms)

      assert {:ok, [%{"name" => "mac", "connected" => true}]} = Pairing.list(context.pairing)
      assert conn_state(context.pairing, "mac").lease_at != nil
    end
  end

  describe "the reconnect" do
    test "a server restart connects the runner again alone", context do
      port = free_port()
      server = serve(context, :first, port: port)
      link = link(server)
      runner = start_runner(context, link: link, reconnect_ms: 100, max_reconnect_ms: 200)
      wait_connected(server.pairing, "mac")
      assert_receive {:hands, {:connected, %{first?: true}}}

      stop_server(:first)
      assert_receive {:hands, :waiting}, 30_000

      second = serve(context, :second, port: port)
      wait_connected(second.pairing, "mac")
      assert_receive {:hands, {:connected, %{first?: false}}}, 30_000

      # A connection that reached its registration resets the wait.
      assert :sys.get_state(runner).attempts == 0
    end

    test "a revoke ends the runner with unauthorized", context do
      server = serve(context)
      runner = start_runner(context, link: link(server))
      wait_connected(server.pairing, "mac")
      assert_receive {:hands, {:connected, %{first?: true}}}, 30_000

      assert :ok = Pairing.revoke(server.pairing, "hands", "mac")
      assert {:error, :unauthorized} = Runner.await(runner)
    end

    @tag :slow
    @tag timeout: 90_000
    test "a server that goes silent after a live closes at the lease and reconnects", context do
      server = serve(context, :server, hands_lease_ms: 30_000)

      start_runner(context, link: link(server), lease_ms: 11_000, reconnect_ms: 100)
      wait_connected(server.pairing, "mac")
      assert_receive {:hands, {:connected, %{first?: true}}}

      # The first request comes at a third of the lease. The runner answers
      # it, so the test isolates a server that goes silent afterwards.
      wait_until(fn -> conn_state(server.pairing, "mac").live_seq >= 1 end, 20_000)
      conn = conn_pid(server.pairing, "mac")

      try do
        :sys.suspend(conn)
        assert_receive {:hands, :waiting}, 30_000
        assert_receive {:hands, {:connected, %{first?: false}}}, 30_000
        wait_connected(server.pairing, "mac")
      after
        resume(conn)
      end
    end

    test "a lease over the maximum is a bad frame" do
      max = Connection.max_lease_ms()

      assert Connection.lease_ms(max) == {:ok, max}
      assert Connection.lease_ms(max + 1) == :bad_frame
      assert Connection.lease_ms(0) == :bad_frame
    end

    test "the wait doubles to the cap, and a registration resets it" do
      assert Runner.connect_ms() >= TLS.handshake_ms()
      assert Runner.frame_ms() > 0

      assert Runner.wait_ms(1) == Runner.reconnect_ms()
      assert Runner.wait_ms(2) == 2 * Runner.reconnect_ms()
      assert Runner.wait_ms(3) == 4 * Runner.reconnect_ms()
      assert Runner.wait_ms(100) == Runner.max_reconnect_ms()

      assert Runner.wait_ms(1, 10, 40) == 10
      assert Runner.wait_ms(2, 10, 40) == 20
      assert Runner.wait_ms(3, 10, 40) == 40
      assert Runner.wait_ms(4, 10, 40) == 40
    end
  end

  test "the private key and the link are out of the state, the child spec, and a crash report",
       context do
    server = serve(context)
    link = link(server)
    {runner, prepared} = start_prepared(context, link: link)
    wait_connected(server.pairing, "mac")
    assert_receive {:hands, {:connected, %{first?: true}}}, 30_000

    key = Base.decode64!(state_json(context, "mac")["key"])
    token = token(link)

    forms = [
      Base.encode64(key),
      Base.encode16(key),
      Base.encode16(key, case: :lower),
      inspect(key),
      inspect(key, binaries: :as_strings)
    ]

    for text <- [inspect(:sys.get_state(runner)), inspect(Runner.child_spec(prepared))] do
      refute Enum.any?(forms, &String.contains?(text, &1))
      refute text =~ token
      refute text =~ "helyx-pair:"
    end

    ref = Process.monitor(runner)

    log =
      capture_log(fn ->
        send(runner, :boom)
        assert_receive {:DOWN, ^ref, :process, ^runner, _reason}
      end)

    refute Enum.any?(forms, &String.contains?(log, &1))
    refute log =~ token
  end

  defp resume(pid) do
    if Process.alive?(pid), do: :sys.resume(pid)
  catch
    :exit, _reason -> :ok
  end

  defp json_fields do
    %{
      "address" => "127.0.0.1:4040",
      "pin" => "pin",
      "name" => "mac",
      "folder" => "/project",
      "key" => Base.encode64(:crypto.strong_rand_bytes(32))
    }
  end

  defp write(path, data) do
    File.write!(path, data)
    File.chmod!(path, 0o600)
  end

  defp relink(link, fun) do
    "helyx-pair:1:" <> encoded = link
    json = JSON.decode!(Base.url_decode64!(encoded, padding: false))
    "helyx-pair:1:" <> Base.url_encode64(JSON.encode!(fun.(json)), padding: false)
  end

  defp link_json(fields), do: encoded(JSON.encode!(fields))

  defp token(link) do
    "helyx-pair:1:" <> encoded = link
    JSON.decode!(Base.url_decode64!(encoded, padding: false))["t"]
  end

  defp encoded(json), do: "helyx-pair:1:" <> Base.url_encode64(json, padding: false)
end
