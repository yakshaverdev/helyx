defmodule Helyx.Hub.ConnectionsTest do
  use ExUnit.Case, async: true

  alias Helyx.Hub
  alias Helyx.Provider.Fake
  alias Helyx.Test.Events
  alias Helyx.Test.WireClient, as: Client
  alias Helyx.Transport.WebSocket

  @moduletag :tmp_dir

  @server_token "the server token"

  setup %{tmp_dir: dir} = context do
    core = :"core_#{System.unique_integer([:positive])}"
    start_supervised!({Helyx.Core, name: core, plugins: [Fake]}, id: :core)

    opts = [
      core: core,
      default_owner: "owner",
      path: Path.join(dir, "hub.db"),
      server_token: fn -> @server_token end,
      store: Map.get(context, :store, Helyx.Hub.Store.SQLite)
    ]

    hub = start_supervised!(Supervisor.child_spec({Hub, opts}, id: :hub))
    transport = start_supervised!({WebSocket, core: core, port: 0, authority: Hub.authority(hub)})
    %{hub: hub, port: WebSocket.port(transport)}
  end

  defp open(port, token) do
    {:ok, socket} = Client.upgrade(port)
    nonce = Client.challenge(socket)
    Client.send_frame(socket, Map.put(Client.hello(nonce, token), "token", token_id(token)))
    {:frame, %{"type" => "welcome"}} = Client.recv(socket)
    socket
  end

  defp user(context, name) do
    {:ok, %{id: id}} = Hub.add_user(context.hub, name)
    {:ok, token} = Hub.create_token(context.hub, id, "laptop")
    {id, token}
  end

  defp open_server(port) do
    {:ok, socket} = Client.upgrade(port)
    Client.send_frame(socket, Client.hello(Client.challenge(socket), @server_token))
    {:frame, %{"type" => "welcome"}} = Client.recv(socket)
    socket
  end

  defp token_id(token), do: hd(String.split(token, "."))
  defp req(socket, op, params), do: Client.request(socket, "r", op, params)

  test "an operator revoke closes the connection of the token at once, with a subscription open",
       context do
    {_ann, token} = user(context, "ann")
    socket = open(context.port, token)

    %{"result" => %{"session" => id}} =
      req(socket, "start", %{"cwd" => File.cwd!(), "model" => "fake/echo"})

    %{"ok" => true} = req(socket, "subscribe", %{"session" => id})

    :ok = Hub.revoke_token(context.hub, token_id(token))
    assert {:close, 4403} = Client.until_close(socket)
  end

  test "a remove of a user closes its connections", context do
    {ann, token} = user(context, "ann")
    {:ok, phone} = Hub.create_token(context.hub, ann, "phone")
    sockets = [open(context.port, token), open(context.port, phone)]
    :ok = Hub.remove_user(context.hub, ann)
    for socket <- sockets, do: assert({:close, 4403} = Client.until_close(socket))
  end

  test "a revoke over the wire of another token of the user closes the connection of that token",
       context do
    {ann, laptop} = user(context, "ann")
    {:ok, phone} = Hub.create_token(context.hub, ann, "phone")
    on_laptop = open(context.port, laptop)
    on_phone = open(context.port, phone)

    assert %{"ok" => true} = req(on_laptop, "hub.tokens.revoke", %{"token" => token_id(phone)})
    assert {:close, 4403} = Client.until_close(on_phone)
    assert %{"ok" => true} = req(on_laptop, "hub.me", %{})
  end

  test "a hub record made private, then deleted: the readers close, the owner stays", context do
    {_ann, ann_token} = user(context, "ann")
    {_bob, bob_token} = user(context, "bob")
    ann = open(context.port, ann_token)

    %{"result" => %{"session" => id}} =
      req(ann, "start", %{"cwd" => File.cwd!(), "model" => "fake/echo"})

    %{"ok" => true} = req(ann, "hub.records.update", %{"session" => id, "visibility" => "hub"})

    bob = open(context.port, bob_token)
    %{"ok" => true} = req(bob, "subscribe", %{"session" => id})

    assert %{"ok" => true} =
             req(ann, "hub.records.update", %{"session" => id, "visibility" => "private"})

    assert {:close, 4403} = Client.until_close(bob)
    assert %{"ok" => true} = req(ann, "hub.me", %{})

    %{"ok" => true} = req(ann, "hub.records.update", %{"session" => id, "visibility" => "hub"})
    bob = open(context.port, bob_token)
    %{"ok" => true} = req(bob, "hub.records.get", %{"session" => id})
    assert %{"ok" => true} = req(ann, "hub.records.delete", %{"session" => id})
    assert {:close, 4403} = Client.until_close(bob)
    assert %{"ok" => true} = req(ann, "hub.me", %{})
  end

  test "a remove of the owner of a hub record closes its readers; the default owner stays",
       context do
    {ann_id, ann_token} = user(context, "ann")
    {_bob, bob_token} = user(context, "bob")
    ann = open(context.port, ann_token)

    %{"result" => %{"session" => id}} =
      req(ann, "start", %{"cwd" => File.cwd!(), "model" => "fake/echo"})

    %{"ok" => true} = req(ann, "hub.records.update", %{"session" => id, "visibility" => "hub"})
    bob = open(context.port, bob_token)
    %{"ok" => true} = req(bob, "subscribe", %{"session" => id})
    owner = open_server(context.port)

    :ok = Hub.remove_user(context.hub, ann_id)
    assert {:close, 4403} = Client.until_close(bob)
    assert %{"ok" => true} = req(owner, "hub.me", %{})
  end

  # A store that fails one read of a record after the flag of the test is set.
  defmodule FailOnce do
    @behaviour Helyx.Hub.Store
    alias Helyx.Hub.Store.SQLite

    for {name, arity} <- Helyx.Hub.Store.behaviour_info(:callbacks), name != :record do
      args = Macro.generate_arguments(arity, __MODULE__)
      @impl true
      def unquote(name)(unquote_splicing(args)), do: SQLite.unquote(name)(unquote_splicing(args))
    end

    @impl true
    def record(db, id) do
      if :persistent_term.get({__MODULE__, db}, false) do
        :persistent_term.erase({__MODULE__, db})
        {:error, :failed}
      else
        SQLite.record(db, id)
      end
    end
  end

  @tag store: FailOnce
  test "a read that fails before a change that commits closes every user but its maker",
       context do
    {_ann, ann_token} = user(context, "ann")
    {_bob, bob_token} = user(context, "bob")
    ann = open(context.port, ann_token)

    %{"result" => %{"session" => id}} =
      req(ann, "start", %{"cwd" => File.cwd!(), "model" => "fake/echo"})

    %{"ok" => true} = req(ann, "hub.records.update", %{"session" => id, "visibility" => "hub"})
    bob = open(context.port, bob_token)
    %{"ok" => true} = req(bob, "subscribe", %{"session" => id})

    %{db: db} = :sys.get_state(context.hub)
    :persistent_term.put({FailOnce, db}, true)

    assert %{"ok" => true} =
             req(ann, "hub.records.update", %{"session" => id, "visibility" => "private"})

    assert {:close, 4403} = Client.until_close(bob)
    assert %{"ok" => true} = req(ann, "hub.me", %{})
  end

  test "a revoke of the token of the connection closes it before any reply", context do
    {_ann, token} = user(context, "ann")
    socket = open(context.port, token)
    Client.send_request(socket, "1", "hub.tokens.revoke", %{"token" => token_id(token)})
    assert {:close, 4403} = Client.recv(socket)
  end

  test "a connection whose proof fails leaves no entry", context do
    {_ann, token} = user(context, "ann")
    {:ok, socket} = Client.upgrade(context.port)
    nonce = Client.challenge(socket)
    hello = Map.put(Client.hello(nonce, "wrong"), "token", token_id(token))
    Client.send_frame(socket, hello)
    assert {:close, 4401} = Client.recv(socket)
    Events.wait_until(fn -> :sys.get_state(context.hub).connections == %{} end)
  end

  test "a change that takes no access closes nothing; a closed connection leaves the set",
       context do
    {_ann, ann_token} = user(context, "ann")
    {_bob, bob_token} = user(context, "bob")
    ann = open(context.port, ann_token)
    bob = open(context.port, bob_token)

    %{"result" => %{"session" => id}} =
      req(ann, "start", %{"cwd" => File.cwd!(), "model" => "fake/echo"})

    %{"ok" => true} = req(ann, "hub.records.update", %{"session" => id, "title" => "t"})
    assert %{"ok" => true} = req(bob, "hub.me", %{})

    Events.wait_until(fn -> map_size(:sys.get_state(context.hub).connections) == 2 end)
    :gen_tcp.close(bob)
    Events.wait_until(fn -> map_size(:sys.get_state(context.hub).connections) == 1 end)
  end
end
