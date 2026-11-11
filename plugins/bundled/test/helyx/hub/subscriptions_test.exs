defmodule Helyx.Hub.SubscriptionsTest do
  # The event subscriptions of a Hub (`docs/features/hub.md`, decision 17):
  # the API and the wire, the secret once, the caps, and access. The
  # webhook endpoint is in `webhook_test.exs`.
  use ExUnit.Case, async: true

  import Helyx.Test.HubWake, only: [serve: 1, user: 2, start: 1]

  alias Helyx.Hub
  alias Helyx.Test.WireClient, as: Client

  @moduletag :tmp_dir

  @missing "AAAAAAAAAAAA"
  @max_template 16_384

  defp template, do: %{"prompt" => "A webhook said: {{payload}}", "label" => "github"}

  defp create(socket, session, fields \\ %{}) do
    params = Map.merge(%{"session" => session}, Map.merge(template(), fields))
    Client.request(socket, "c", "hub.subscriptions.create", params)
  end

  defp code(%{"error" => %{"code" => code}}), do: code

  test "create returns the secret once; no listing holds it; delete ends it", context do
    context = serve(context)
    {ann, ann_socket} = user(context, "ann")
    session = start(ann_socket)

    {:ok, created} = Hub.subscribe(context.hub, ann, Map.put(template(), "session", session))

    assert %{secret: secret, path: path, subscription: subscription} = created
    assert byte_size(secret) == 43
    assert path == "/hooks/" <> subscription.id
    assert subscription.session == session
    assert subscription.label == "github"

    # The API listing has no secret.
    {:ok, [listed]} = Hub.subscriptions(context.hub, ann, nil)
    assert listed.id == subscription.id
    refute Map.has_key?(listed, :secret)

    # The wire create reply holds it once, and the wire list never does.
    {_bob, socket} = user(context, "bob")

    assert %{"result" => %{"secret" => wire_secret, "path" => wire_path}} =
             Client.request(socket, "c", "hub.subscriptions.create", %{
               "session" => start(socket),
               "prompt" => "{{payload}}"
             })

    assert byte_size(wire_secret) == 43
    assert wire_path =~ "/hooks/"

    assert %{"result" => %{"subscriptions" => items}} =
             Client.request(socket, "r", "hub.subscriptions.list", %{})

    assert length(items) == 1
    refute Enum.any?(items, &Map.has_key?(&1, "secret"))

    assert %{"result" => %{}} =
             Client.request(socket, "r", "hub.subscriptions.delete", %{
               "subscription" => hd(items)["id"]
             })

    assert %{"result" => %{"subscriptions" => []}} =
             Client.request(socket, "r", "hub.subscriptions.list", %{})

    assert code(
             Client.request(socket, "r", "hub.subscriptions.delete", %{
               "subscription" => hd(items)["id"]
             })
           ) == "unknown_subscription"
  end

  test "the template bounds: one placeholder, 1 to 16,384 bytes, a label of 0 to 64", context do
    context = serve(context)
    {_ann, socket} = user(context, "ann")
    session = start(socket)
    ok = &assert(%{"ok" => true} = create(socket, session, &1))
    bad = &assert(code(create(socket, session, &1)) == "bad_params", inspect(&1))

    ok.(%{"prompt" => "{{payload}}"})
    ok.(%{"prompt" => String.duplicate("p", @max_template - 12) <> "{{payload}}"})
    ok.(%{"prompt" => String.duplicate("p", @max_template - 15) <> "é{{payload}}"})
    bad.(%{"prompt" => ""})
    bad.(%{"prompt" => "no placeholder"})
    bad.(%{"prompt" => "{{payload}}{{payload}}"})
    bad.(%{"prompt" => 7})
    bad.(%{"label" => String.duplicate("l", 65)})
    bad.(%{"label" => "line\nbreak"})
    bad.(%{"label" => 7})
    bad.(%{"extra" => 1})

    ok.(%{"label" => ""})
    ok.(%{"label" => String.duplicate("l", 64)})

    over =
      create(socket, session, %{
        "prompt" => String.duplicate("p", @max_template + 1) <> "{{payload}}"
      })

    assert code(over) == "text_too_large"

    multibyte =
      create(socket, session, %{
        "prompt" => String.duplicate("p", @max_template - 1) <> "é{{payload}}"
      })

    assert code(multibyte) == "text_too_large"
  end

  test "16 subscriptions of a session", context do
    context = serve(context)
    {_ann, socket} = user(context, "ann")
    session = start(socket)
    for _ <- 1..16, do: %{"ok" => true} = create(socket, session)
    assert code(create(socket, session)) == "too_many_event_subscriptions"
    # Another session has room.
    assert %{"ok" => true} = create(socket, start(socket))
  end

  test "the store counts 256 subscriptions of a user across sessions" do
    {:ok, db} = Helyx.Hub.Store.SQLite.open(path: nil)

    :ok =
      Helyx.Hub.Store.SQLite.add_user(db, %{id: "u1", name: "u", created_at: 1}, 64, :infinity)

    row = fn n ->
      %{
        id: "s#{n}",
        owner: "u1",
        session_id: "session#{n}",
        template: "{{payload}}",
        label: "",
        secret: "secret#{n}",
        created_at: n,
        last_at: nil,
        last_outcome: nil
      }
    end

    for n <- 1..2,
        do: :ok = Helyx.Hub.Store.SQLite.put_subscription(db, row.(n), 16, 2, :infinity)

    assert Helyx.Hub.Store.SQLite.put_subscription(db, row.(3), 16, 2, :infinity) ==
             {:error, :too_many_event_subscriptions}

    :ok = Helyx.Hub.Store.SQLite.close(db)
  end

  test "a session of another user: refused as a missing one, forbidden when shared", context do
    context = serve(context)
    {_ann, ann} = user(context, "ann")
    {_bob, bob} = user(context, "bob")
    private = start(ann)
    shared = start(ann)

    %{"ok" => true} =
      Client.request(ann, "r", "hub.records.update", %{"session" => shared, "visibility" => "hub"})

    assert create(bob, private)["error"] == create(bob, @missing)["error"]
    assert code(create(bob, private)) == "session_not_found"

    assert Client.request(bob, "r", "hub.subscriptions.list", %{"session" => private})["error"] ==
             Client.request(bob, "r", "hub.subscriptions.list", %{"session" => @missing})["error"]

    assert code(create(bob, shared)) == "forbidden"

    # A reader of a shared session lists no subscription of its owner.
    assert %{"result" => %{"subscriptions" => []}} =
             Client.request(bob, "r", "hub.subscriptions.list", %{"session" => shared})

    %{"result" => %{"subscription" => %{"id" => id}}} = create(ann, private)

    assert code(Client.request(bob, "r", "hub.subscriptions.delete", %{"subscription" => id})) ==
             "unknown_subscription"

    # The same bad params for an object of another user and a missing one.
    assert code(create(bob, private, %{"prompt" => "no placeholder"})) == "bad_params"
    assert code(create(bob, @missing, %{"prompt" => "no placeholder"})) == "bad_params"
  end

  test "Hub.subscribe/3: the rules of hub.subscriptions.create for a user", context do
    context = serve(context)
    {:ok, session} = Helyx.Sessions.start(context.core, cwd: File.cwd!(), model: "fake/echo")
    {:ok, [%{id: owner}]} = Hub.users(context.hub)
    params = Map.put(template(), "session", session.id)

    assert {:ok, %{subscription: %{session: session_id, pending: false}, secret: secret}} =
             Hub.subscribe(context.hub, owner, params)

    assert session_id == session.id
    assert byte_size(secret) == 43

    {:ok, %{id: ann}} = Hub.add_user(context.hub, "ann")
    assert Hub.subscribe(context.hub, ann, params) == {:error, :session_not_found}
    assert Hub.subscribe(context.hub, "nobody", params) == {:error, :unknown_user}
    assert Hub.subscribe(context.hub, owner, %{params | "prompt" => "x"}) == {:error, :bad_params}
    assert Hub.unsubscribe(context.hub, ann, "AAAAAAAAAAAA") == {:error, :unknown_subscription}
  end

  test "an exit of the Hub call of subscribe, subscriptions, or unsubscribe is a timeout",
       context do
    context = serve(context)
    params = Map.put(template(), "session", @missing)
    :ok = stop_supervised(Helyx.Transport.WebSocket)
    :ok = stop_supervised(:hub)

    assert Hub.subscribe(context.hub, "anyone", params) == {:error, :timeout}
    assert Hub.subscriptions(context.hub, "anyone", nil) == {:error, :timeout}
    assert Hub.unsubscribe(context.hub, "anyone", @missing) == {:error, :timeout}
  end
end
