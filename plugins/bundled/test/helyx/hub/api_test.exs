defmodule Helyx.Hub.ApiTest do
  # The Elixir API of the session (`docs/features/hub.md`, decision 5):
  # `start_session/3`, `authorize/4`, and `owner/2` run the checks of the
  # wire for the coordinator tools (`docs/features/coordinator.md`).
  use ExUnit.Case, async: true

  alias Helyx.{Hub, Session}
  alias Helyx.Provider.Fake

  @moduletag :tmp_dir

  # A session id with no session and no file.
  @missing "AAAAAAAAAAAA"

  setup %{tmp_dir: dir} = context do
    data = Path.join(dir, "data")
    File.mkdir_p!(data)
    File.chmod!(data, 0o700)
    core = :"core_#{System.unique_integer([:positive])}"
    start_supervised!({Helyx.Core, name: core, plugins: [Fake], sessions_dir: data}, id: :core)
    max = Map.get(context, :max_live, 64)
    hub_opts = [core: core, default_owner: "owner", max_live_sessions: max]
    hub = start_supervised!(Supervisor.child_spec({Hub, hub_opts}, id: :hub))
    {:ok, users} = Hub.users(hub)
    owner = Enum.find(users, &(&1.name == "owner")).id
    {:ok, %{id: ann}} = Hub.add_user(hub, "ann")
    {:ok, %{id: bob}} = Hub.add_user(hub, "bob")
    %{hub: hub, core: core, owner: owner, ann: ann, bob: bob, dir: dir}
  end

  defp start(context, user, opts \\ []),
    do:
      Hub.start_session(
        context.hub,
        user,
        Keyword.merge([cwd: context.dir, model: "fake/echo"], opts)
      )

  test "a start writes the record of its user, and the owner is that user", context do
    {:ok, %Session{id: id} = session} = start(context, context.ann)
    assert is_pid(Session.pid(session))
    assert Hub.owner(context.hub, id) == {:ok, context.ann}
  end

  test "a session with no record is the default owner's; a missing id has no owner", context do
    {:ok, session} = Session.start(context.core, model: "fake/echo", cwd: context.dir)
    assert Hub.owner(context.hub, session.id) == {:ok, context.owner}
    assert Hub.owner(context.hub, @missing) == {:error, :session_not_found}
  end

  @tag max_live: 1
  test "the cap of live sessions of a user, and a failed Core start gives its place back",
       context do
    assert {:error, {:invalid_model_ref, _}} = start(context, context.ann, model: "bad")
    {:ok, _session} = start(context, context.ann)
    assert start(context, context.ann) == {:error, :too_many_sessions}
    # The cap is the user's own.
    assert {:ok, _} = start(context, context.bob)
  end

  test "a start needs a cwd string and a user that exists", context do
    assert Hub.start_session(context.hub, context.ann, model: "fake/echo") ==
             {:error, :invalid_cwd}

    :ok = Hub.remove_user(context.hub, context.bob)
    assert start(context, context.bob) == {:error, :unknown_user}
    assert Helyx.Sessions.list_live(context.core) == []
  end

  test "authorize: the owner may, another user gets the answer of a missing session",
       context do
    {:ok, %Session{id: id}} = start(context, context.ann)
    text = %{"session" => id, "text" => "hi"}

    for op <- ~w(history subscribe),
        do: assert(Hub.authorize(context.hub, context.ann, op, %{"session" => id}) == :ok)

    assert Hub.authorize(context.hub, context.ann, "prompt", text) == :ok

    for {op, params} <- [
          {"history", %{"session" => id}},
          {"steer", text},
          {"stop", %{"session" => id}}
        ] do
      assert Hub.authorize(context.hub, context.bob, op, params) == {:error, :session_not_found}

      assert Hub.authorize(context.hub, context.bob, op, Map.put(params, "session", @missing)) ==
               {:error, :session_not_found}
    end
  end

  test "a Hub that is gone answers timeout", context do
    {:ok, hub} =
      Hub.start_link(
        core: context.core,
        default_owner: "owner",
        path: Path.join(context.dir, "other.db")
      )

    GenServer.stop(hub)
    assert Hub.owner(hub, @missing) == {:error, :timeout}
    assert Hub.start_session(hub, context.ann, cwd: context.dir) == {:error, :timeout}

    assert Hub.authorize(hub, context.ann, "history", %{"session" => @missing}) ==
             {:error, :timeout}
  end
end
