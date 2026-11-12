defmodule CodingAgent.HandsTest do
  # `helyx hands --pair` and `helyx hands --name` against a real
  # `helyx serve --public` (`docs/features/remote-hands.md`, "The runner
  # state"). Not async: one command runs per VM, as `serve` does.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO
  import Helyx.Test.Events, only: [wait_until: 1]

  alias CodingAgent.{CLI, Serve}
  alias Helyx.Test.WireClient

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    sessions = Path.join(dir, "sessions")
    project = Path.join(dir, "project")
    File.mkdir_p!(project)
    Application.put_env(:coding_agent, :sessions_dir, sessions)
    on_exit(fn -> Application.delete_env(:coding_agent, :sessions_dir) end)

    on_exit(fn ->
      if server = Process.whereis(Serve),
        do: Task.Supervisor.terminate_child(CodingAgent.Servers, server)

      if runner = Process.whereis(CodingAgent.Hands),
        do: Supervisor.stop(runner)
    end)

    %{sessions: sessions, project: project, home: dir}
  end

  test "hands --pair connects, pair.list shows it, and --name connects again", context do
    {_server, link} = start_server(context)
    {task, io} = start_hands(["--pair", link, "--folder", context.project])

    wait_output(io, "is paired with")
    assert String.contains?(state_output(io), "helyx: the runner mac is paired with")
    assert list_connected(context.sessions) == true

    stop_hands()
    assert Task.await(task, 30_000) == 0

    state_file = Path.join([context.home, "hands", "mac.json"])
    assert File.exists?(state_file)

    {task, io} = start_hands(["--name", "mac"])
    wait_output(io, "is connected to")
    assert list_connected(context.sessions) == true

    stop_hands()
    assert Task.await(task, 30_000) == 0
  end

  test "the switches and the faults are one line and exit 1", context do
    {_server, link} = start_server(context)

    for {argv, text} <- [
          {["--pair", link, "--name", "mac"], "--pair does not combine with --name"},
          {[], "hands needs --pair <link> or --name <name>"},
          {["--pair", link, "--model", "fake/echo"], "--model does not combine with hands"},
          {["--pair", "nope"], "the pair link does not start with helyx-pair:1:"},
          {["--pair", bad_port(link)], "the pair link has a port outside 1 to 65535"},
          {["--pair", link, "--folder", "/nonexistent/helyx"], "not a directory"},
          {["--name", "mac"], "no saved runner state for"},
          {["--name", "Mac"], "--name takes 1 to 64 bytes"},
          {["--name", "mac", "--folder", context.project], "no saved runner state for"},
          {["--name", link], "--name takes 1 to 64 bytes"},
          {["x"], "hands takes no directory argument, got 1 argument(s)"}
        ] do
      {status, out, err} = run(["hands" | argv])
      assert status == 1
      assert out == ""
      assert err =~ text
    end
  end

  test "a positional link is not printed", context do
    {_server, link} = start_server(context)
    %{"t" => token} = link_parts(link)

    {status, out, err} = run(["hands", link])
    assert status == 1
    assert out == ""
    assert err =~ "a pair link goes after --pair"
    refute err =~ token
    refute err =~ Base.encode64(token)
  end

  test "a second --pair over an existing state file refuses and keeps it", context do
    {_server, link} = start_server(context)
    {task, io} = start_hands(["--pair", link, "--folder", context.project])
    wait_output(io, "is paired with")
    stop_hands()
    assert Task.await(task, 30_000) == 0

    path = Path.join([context.home, "hands", "mac.json"])
    before = File.read!(path)

    {status, out, err} = run(["hands", "--pair", link, "--folder", context.project])
    assert status == 1
    assert out == ""
    assert err =~ "already exists"
    assert err =~ path
    assert File.read!(path) == before
  end

  test "a bad link shows no token", context do
    {_server, link} = start_server(context)
    %{"t" => token} = link_parts(link)
    bad = relink(link, &Map.put(&1, "k", "client"))

    {status, out, err} = run(["hands", "--pair", bad])
    assert status == 1
    assert out == ""
    assert err =~ "the pair link is not for a runner"
    refute err =~ token
    refute err =~ Base.encode64(token)
  end

  test "a used link is one line and exit 1", context do
    {_server, link} = start_server(context)
    {task, io} = start_hands(["--pair", link, "--folder", context.project])
    wait_output(io, "is paired with")
    stop_hands()
    assert Task.await(task, 30_000) == 0

    # Another home has no state file, so the link reaches the server.
    Application.put_env(
      :coding_agent,
      :sessions_dir,
      Path.join([context.home, "other", "sessions"])
    )

    {status, out, err} = run(["hands", "--pair", link, "--folder", context.project])
    assert status == 1
    assert out == ""
    assert err =~ "the server refused the runner key"
  end

  test "a wrong pin is one line and exit 1", context do
    {_server, link} = start_server(context)
    bad = relink(link, &Map.put(&1, "p", "not-the-pin"))

    {status, out, err} = run(["hands", "--pair", bad, "--folder", context.project])
    assert status == 1
    assert out == ""
    assert err =~ "does not match the pin of the link"
  end

  test "the folder defaults to the current directory", context do
    {_server, link} = start_server(context)

    File.cd!(context.project, fn ->
      {task, io} = start_hands(["--pair", link])
      wait_output(io, "is paired with")

      json = JSON.decode!(File.read!(Path.join([context.home, "hands", "mac.json"])))
      assert json["folder"] == Path.expand(context.project)

      stop_hands()
      assert Task.await(task, 30_000) == 0
    end)
  end

  test "a stop ends the command with 0", context do
    {_server, link} = start_server(context)
    {task, io} = start_hands(["--pair", link, "--folder", context.project])
    wait_output(io, "is paired with")
    stop_hands()
    assert Task.await(task, 30_000) == 0
  end

  defp start_server(context) do
    {:ok, output} = StringIO.open("")
    port = free_port()
    public = {{127, 0, 0, 1}, port, "127.0.0.1:#{port}"}

    server =
      Serve.start(
        [
          sessions_dir: context.sessions,
          model: "fake/echo",
          ip: {127, 0, 0, 1},
          port: 0,
          public: public
        ],
        output
      )

    wait_until(fn -> match?({:ok, _ip, _port, _token}, Serve.read_file(context.sessions)) end)

    out = capture_io(fn -> assert CLI.main(["pair", "--runner", "mac"]) == 0 end)
    [link, _line] = String.split(out, "\n", trim: true)
    {server, link}
  end

  defp start_hands(argv) do
    {:ok, io} = StringIO.open("")

    task =
      Task.async(fn ->
        Process.group_leader(self(), io)
        CLI.main(["hands" | argv])
      end)

    {task, io}
  end

  defp stop_hands do
    case Process.whereis(CodingAgent.Hands) do
      nil -> :ok
      pid -> Supervisor.stop(pid)
    end
  end

  defp state_output(io) do
    {_input, output} = StringIO.contents(io)
    output
  end

  defp wait_output(io, text), do: wait_until(fn -> state_output(io) =~ text end)

  defp list_connected(sessions) do
    {:ok, _ip, port, token} = Serve.read_file(sessions)
    socket = WireClient.open(port, token.())

    %{"ok" => true, "result" => %{"peers" => peers}} =
      WireClient.request(socket, "1", "pair.list", %{})

    :gen_tcp.close(socket)
    Enum.any?(peers, &(&1["name"] == "mac" and &1["connected"] == true))
  end

  defp run(argv) do
    {{status, out}, err} =
      with_io(:stderr, fn -> with_io(fn -> CLI.main(argv) end) end)

    {status, out, err}
  end

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end

  defp link_parts(link) do
    "helyx-pair:1:" <> encoded = link
    JSON.decode!(Base.url_decode64!(encoded, padding: false))
  end

  defp bad_port(link), do: relink(link, &Map.put(&1, "a", "127.0.0.1:0"))

  defp relink(link, fun) do
    json = link_parts(link)
    "helyx-pair:1:" <> Base.url_encode64(JSON.encode!(fun.(json)), padding: false)
  end
end
