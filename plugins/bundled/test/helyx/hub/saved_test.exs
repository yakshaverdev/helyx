defmodule Helyx.Hub.SavedTest do
  use ExUnit.Case, async: true

  alias Helyx.Hub
  alias Helyx.Provider.Fake
  alias Helyx.Test.WireClient, as: Client
  alias Helyx.Transport.WebSocket

  @moduletag :tmp_dir

  @server_token "the server token"

  setup %{tmp_dir: dir} do
    folders = for name <- ~w(one two), do: Path.join(dir, name) |> tap(&File.mkdir_p!/1)
    Map.put(start_hub(dir, "data", []), :folders, folders)
  end

  # A Core with the data folder `name` of `dir`, its Hub with `opts`, and a
  # transport under the Hub.
  defp start_hub(dir, name, opts) do
    data = Path.join(dir, name)
    File.mkdir_p!(data)
    File.chmod!(data, 0o700)
    core = :"core_#{System.unique_integer([:positive])}"
    core_opts = [name: core, plugins: [Fake], sessions_dir: data]
    start_supervised!({Helyx.Core, core_opts}, id: {:core, name})
    hub_opts = [core: core, default_owner: "owner", server_token: fn -> @server_token end] ++ opts
    hub = start_supervised!({Hub, hub_opts}, id: {:hub, name})

    transport =
      start_supervised!({WebSocket, core: core, port: 0, authority: Hub.authority(hub)},
        id: {:transport, name}
      )

    %{hub: hub, port: WebSocket.port(transport)}
  end

  defp open(port, token \\ nil) do
    {:ok, socket} = Client.upgrade(port)
    nonce = Client.challenge(socket)

    hello =
      case token do
        nil -> Client.hello(nonce, @server_token)
        _ -> Map.put(Client.hello(nonce, token), "token", hd(String.split(token, ".")))
      end

    Client.send_frame(socket, hello)
    {:frame, %{"type" => "welcome"}} = Client.recv(socket)
    socket
  end

  defp user(context, name) do
    {:ok, %{id: id}} = Hub.add_user(context.hub, name)
    {:ok, token} = Hub.create_token(context.hub, id, "laptop")
    open(context.port, token)
  end

  defp req(socket, op, params), do: Client.request(socket, "r", op, params)

  # A stopped session of the folder `cwd` with one user message, so the scan
  # of Core lists it.
  defp session(socket, cwd) do
    %{"result" => %{"session" => id}} =
      req(socket, "start", %{"cwd" => cwd, "model" => "fake/echo"})

    %{"ok" => true} = req(socket, "prompt", %{"session" => id, "text" => "hello"})
    %{"ok" => true} = req(socket, "stop", %{"session" => id})
    id
  end

  # Every page with `limit`, following `next`, as one list of ids, and the
  # cursors.
  defp pages(socket, limit, extra) do
    Stream.unfold({nil, 0}, fn
      :done ->
        nil

      {cursor, n} ->
        params = Map.merge(extra, %{"limit" => limit})
        params = if cursor, do: Map.put(params, "after", cursor), else: params
        %{"result" => %{"items" => items, "next" => next}} = req(socket, "sessions.saved", params)
        assert length(items) <= limit
        assert n < 64, "pages do not end"
        {{items, next}, if(next, do: {next, n + 1}, else: :done)}
    end)
    |> Enum.to_list()
  end

  test "sessions.saved: a user gets every session it may read, and none of another", context do
    [one, two] = context.folders
    ann = user(context, "ann")
    bob = user(context, "bob")
    owner = open(context.port)

    bobs = for cwd <- [one, two, one, two, one], do: session(bob, cwd)
    anns = for cwd <- [one, two, one], do: session(ann, cwd)
    shared = session(ann, one)

    %{"ok" => true} =
      req(ann, "hub.records.update", %{"session" => shared, "visibility" => "hub"})

    owners = for cwd <- [one, two], do: session(owner, cwd)

    readable = bobs ++ [shared]

    for extra <- [%{}, %{"cwd" => one}] do
      expected =
        if extra == %{},
          do: MapSet.new(readable),
          else: MapSet.new(Enum.take_every(bobs, 2) ++ [shared])

      for limit <- 1..(length(readable) + 1) do
        pages = pages(bob, limit, extra)
        ids = Enum.flat_map(pages, fn {items, _} -> Enum.map(items, & &1["id"]) end)
        assert MapSet.new(ids) == expected, "limit #{limit} #{inspect(extra)}"
        assert length(ids) == MapSet.size(expected)

        cursors = for {_, next} <- pages, next, do: next
        for id <- anns ++ owners, cursor <- cursors, do: refute(cursor =~ id)

        # The order is the order of the keys, newest first.
        keys =
          Enum.flat_map(pages, fn {items, _} -> Enum.map(items, &{&1["mtime"], &1["id"]}) end)

        assert keys == Enum.sort(keys, :desc)
      end
    end

    # The default owner gets its sessions with no record and the hub record,
    # and none of the private ones of ann and bob.
    ids =
      pages(owner, 50, %{})
      |> Enum.flat_map(fn {items, _} -> Enum.map(items, & &1["id"]) end)

    assert MapSet.new(ids) == MapSet.new(owners ++ [shared])
  end

  test "resume of a folder: the newest session of the folder that the user owns", context do
    [one, two] = context.folders
    ann = user(context, "ann")
    bob = user(context, "bob")
    owner = open(context.port)
    for _ <- 1..2, do: session(bob, one)
    _anns = session(ann, one)
    for _ <- 1..2, do: session(owner, one)

    # Newest is the order of sessions.saved: the largest `{mtime, id}`, of
    # the sessions of the folder that the user owns.
    newest = fn socket ->
      %{"result" => %{"items" => items}} = req(socket, "sessions.saved", %{"cwd" => one})
      items |> Enum.max_by(&{&1["mtime"], &1["id"]}) |> Map.fetch!("id")
    end

    bobs_newest = newest.(bob)
    owners_newest = newest.(owner)

    assert %{"result" => %{"session" => ^bobs_newest}} = req(bob, "resume", %{"cwd" => one})
    assert %{"result" => %{"session" => ^owners_newest}} = req(owner, "resume", %{"cwd" => one})
    assert %{"error" => %{"code" => "not_found"}} = req(bob, "resume", %{"cwd" => two})
  end

  test "the default owner: every limit over its two sources, the item fields, next null on a full page",
       context do
    [one, two] = context.folders
    owner = open(context.port)
    stored = for cwd <- [one, two], do: session(owner, cwd)

    for id <- stored,
        do: %{"ok" => true} = req(owner, "hub.records.update", %{"session" => id, "title" => "t"})

    derived = for cwd <- [one, two, one], do: session(owner, cwd)
    all = MapSet.new(stored ++ derived)

    for limit <- 1..(MapSet.size(all) + 1) do
      pages = pages(owner, limit, %{})
      ids = Enum.flat_map(pages, fn {items, _} -> Enum.map(items, & &1["id"]) end)
      assert MapSet.new(ids) == all and length(ids) == MapSet.size(all), "limit #{limit}"
      keys = Enum.flat_map(pages, fn {items, _} -> Enum.map(items, &{&1["mtime"], &1["id"]}) end)
      assert keys == Enum.sort(keys, :desc)
    end

    # A page that holds every item exactly has no next.
    assert %{"result" => %{"items" => items, "next" => nil}} =
             req(owner, "sessions.saved", %{"limit" => MapSet.size(all)})

    for item <- items do
      assert Enum.sort(Map.keys(item)) == ~w(cwd id model mtime prompt)
      assert %{"model" => "fake/echo", "cwd" => cwd} = item
      assert cwd in [one, two]
    end
  end

  test "an answer before the Hub call still checks the credential", context do
    {:ok, [%{id: owner_id}]} = Hub.users(context.hub)

    for {op, params} <- [
          {"sessions.saved", %{"cwd" => "a\u0000b"}},
          {"resume", %{"cwd" => "a\u0000b"}},
          {"sessions.saved", %{"limit" => 0}}
        ] do
      {:ok, token} = Hub.create_token(context.hub, owner_id, "phone")
      socket = open(context.port, token)
      :ok = Hub.revoke_token(context.hub, hd(String.split(token, ".")))
      Client.send_request(socket, "1", op, params)
      assert {:close, 4403} = Client.until_close(socket), op
    end
  end

  # A store whose touch of a record at a resume (no text) answers that its
  # deadline passed.
  defmodule LateTouch do
    @behaviour Helyx.Hub.Store
    alias Helyx.Hub.Store.SQLite

    for {name, arity} <- Helyx.Hub.Store.behaviour_info(:callbacks), name != :touch_record do
      args = Macro.generate_arguments(arity, __MODULE__)
      @impl true
      def unquote(name)(unquote_splicing(args)), do: SQLite.unquote(name)(unquote_splicing(args))
    end

    @impl true
    def touch_record(_db, _id, _at, nil, _deadline), do: {:error, :timeout}

    def touch_record(db, id, at, prompt, deadline),
      do: SQLite.touch_record(db, id, at, prompt, deadline)
  end

  test "a timeout of the Hub call of a resume of a folder makes no second Hub call",
       %{tmp_dir: dir} = context do
    [one, _two] = context.folders
    %{hub: hub} = late = start_hub(dir, "late", store: LateTouch)
    bob = user(late, "bob")
    session(bob, one)

    # The trace of the calls that the Hub took is complete after
    # `trace_delivered`.
    :erlang.trace(hub, true, [:receive])
    assert %{"error" => %{"code" => "timeout"}} = req(bob, "resume", %{"cwd" => one})
    ref = :erlang.trace_delivered(hub)
    assert_receive {:trace_delivered, ^hub, ^ref}
    :erlang.trace(hub, false, [:receive])

    assert_received {:trace, ^hub, :receive, {:"$gen_call", _, {:hub, _, {:newest, _, _, _}}}}
    refute_received {:trace, ^hub, :receive, {:"$gen_call", _, {:hub, _, _}}}
  end

  test "a cwd that Core refuses is invalid_cwd for every user", context do
    bob = user(context, "bob")
    owner = open(context.port)

    for socket <- [bob, owner] do
      assert %{"error" => %{"code" => "invalid_cwd"}} =
               req(socket, "sessions.saved", %{"cwd" => "a\u0000b"})

      assert %{"error" => %{"code" => "invalid_cwd"}} =
               req(socket, "resume", %{"cwd" => "a\u0000b"})
    end
  end

  test "bad params of sessions.saved are bad_params for every user", context do
    bob = user(context, "bob")
    owner = open(context.port)

    for socket <- [bob, owner],
        params <- [
          %{"limit" => 0},
          %{"limit" => 257},
          %{"after" => "x"},
          %{"after" => "1:short"},
          %{"cwd" => 7},
          %{"cwd" => nil},
          %{"after" => nil},
          %{"limit" => nil},
          %{"other" => 1}
        ] do
      assert %{"error" => %{"code" => "bad_params"}} = req(socket, "sessions.saved", params),
             inspect(params)
    end

    for socket <- [bob, owner] do
      assert %{"ok" => true} = req(socket, "sessions.saved", %{"limit" => 256})

      assert %{"ok" => true} =
               req(socket, "sessions.saved", %{"after" => "99999999999999999999:AAAAAAAAAAAA"})
    end
  end
end
