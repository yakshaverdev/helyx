defmodule Helyx.Test.HubStub do
  @moduledoc false
  # A Hub process for the tests of the load: it answers the `{:hub, deadline,
  # request}` protocol of `Helyx.Hub.call` with the function that it was
  # started with.
  use GenServer

  def start_link(fun), do: GenServer.start_link(__MODULE__, fun)

  @impl true
  def init(fun), do: {:ok, fun}

  @impl true
  def handle_call({:hub, _deadline, request}, _from, fun), do: {:reply, fun.(request), fun}
end

defmodule Helyx.Hub.LoadTest do
  # The load of a stopped session under a Hub (docs/features/idle-unload.md):
  # one function for the wire and the Elixir API, the place, the resume, the
  # starter, and the cleanup that stops only a process that its own resume
  # started.
  use ExUnit.Case, async: true

  import Helyx.Test.Events, only: [snapshot: 1, wait_until: 1]

  alias Helyx.Hub.Access
  alias Helyx.Session
  alias Helyx.Test.HubStub

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    core = :"core_#{System.unique_integer([:positive])}"

    start_supervised!(
      {Helyx.Core, name: core, plugins: [Helyx.Provider.Fake], sessions_dir: dir},
      id: :core
    )

    %{core: core, dir: dir, auth: %{user: "ann", token: nil}}
  end

  # A session of the Core with a file, idle after its first turn.
  defp session(core) do
    {:ok, session} = Helyx.Sessions.start(core, cwd: File.cwd!(), model: "fake/echo")
    :ok = Session.prompt(session, "hi")
    wait_until(fn -> snapshot(session).turn == nil end)
    session
  end

  defp stop(session) do
    :ok = Helyx.Sessions.stop(session)
    session
  end

  defp arg(core, dir, stub), do: %{core: core, dir: dir, hub: stub}

  # A stub that lets the check pass and fails the starter bind.
  defp failing_bind do
    stub(fn
      {:resume, _auth, _id, _exists?, _running?} -> :ok
      {:resumed, _auth, _id, _pid} -> {:error, :failed}
      :release -> :ok
    end)
  end

  # A stub under the test supervisor, so an exit in one answer ends only it.
  defp stub(fun),
    do: start_supervised!(%{id: make_ref(), start: {HubStub, :start_link, [fun]}})

  test "a bind that fails stops a session that the load started", %{
    core: core,
    dir: dir,
    auth: auth
  } do
    session = session(core) |> stop()
    stub = failing_bind()

    assert Access.resume(arg(core, dir, stub), auth, session.id) == {:error, :failed}
    assert Session.pid(session) == nil
  end

  test "a bind that fails leaves a session that another loader started", %{
    core: core,
    dir: dir,
    auth: auth
  } do
    # The session runs: this load attaches and must not stop it.
    session = session(core)
    stub = failing_bind()

    assert Access.resume(arg(core, dir, stub), auth, session.id) == {:error, :failed}
    assert is_pid(Session.pid(session))
  end

  test "a check refused at the cap attaches to the session that another loader started", %{
    core: core,
    dir: dir,
    auth: auth
  } do
    session = session(core) |> stop()
    counters = :counters.new(1, [])
    test = self()

    stub =
      stub(fn
        {:resume, _auth, _id, _exists?, _running?} ->
          if :counters.get(counters, 1) == 0 do
            :counters.add(counters, 1, 1)
            send(test, {:placing, self()})

            receive do
              :placed -> {:error, :too_many_sessions}
            end
          else
            :ok
          end

        {:resumed, _auth, _id, _pid} ->
          :ok

        :release ->
          :ok
      end)

    task = Task.async(fn -> Access.resume(arg(core, dir, stub), auth, session.id) end)

    assert_receive {:placing, ^stub}
    assert {:ok, _session, :started} = Helyx.Sessions.resume(core, id: session.id)
    send(stub, :placed)

    assert {:ok, loaded} = Task.await(task)
    assert loaded.id == session.id
    assert is_pid(Session.pid(session))
  end

  test "the wire and the Elixir API load with one function, each with its own error", %{
    core: core,
    dir: dir,
    auth: auth
  } do
    session = session(core) |> stop()

    wire_stub = failing_bind()

    assert Access.load(arg(core, dir, wire_stub), auth, "prompt", %{"session" => session.id}) ==
             {:error, "failed"}

    api_stub = failing_bind()

    assert Helyx.Hub.Api.resume(arg(core, dir, api_stub), auth.user, session.id) ==
             {:error, :failed}
  end

  test "an exit of the starter bind is a timeout in both paths, and the session stays", %{
    core: core,
    dir: dir,
    auth: auth
  } do
    session = session(core)

    stub =
      stub(fn
        {:resume, _auth, _id, _exists?, _running?} -> :ok
        {:resumed, _auth, _id, _pid} -> exit(:boom)
        :release -> :ok
      end)

    assert Access.resume(arg(core, dir, stub), auth, session.id) == {:error, :timeout}
    assert is_pid(Session.pid(session))

    api_stub =
      stub(fn
        {:resume, _auth, _id, _exists?, _running?} -> :ok
        {:resumed, _auth, _id, _pid} -> exit(:boom)
        :release -> :ok
      end)

    assert Helyx.Hub.Api.resume(arg(core, dir, api_stub), auth.user, session.id) ==
             {:error, :timeout}
  end
end
