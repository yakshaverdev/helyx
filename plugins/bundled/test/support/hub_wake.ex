defmodule Helyx.Test.HubWake do
  @moduledoc false
  # Helpers of the wake-up tests of `Helyx.Hub` (decision 12): a Core with a
  # data folder, a Hub on a file, and a transport; reads and writes of the
  # store run in the Hub process, its only caller.

  import ExUnit.Assertions

  alias Helyx.Hub
  alias Helyx.Test.WireClient, as: Client
  alias Helyx.Transport.WebSocket

  def serve(%{tmp_dir: dir}, hub_opts \\ []) do
    data = Path.join(dir, "data")
    File.mkdir_p!(data)
    File.chmod!(data, 0o700)
    core = :"core_#{System.unique_integer([:positive])}"

    ExUnit.Callbacks.start_supervised!(
      {Helyx.Core,
       name: core, plugins: [Helyx.Provider.Fake, Helyx.Test.Tool.Block], sessions_dir: data},
      id: :core
    )

    opts = [core: core, default_owner: "owner", path: Path.join(dir, "hub.db")] ++ hub_opts
    hub = ExUnit.Callbacks.start_supervised!(Supervisor.child_spec({Hub, opts}, id: :hub))

    transport =
      ExUnit.Callbacks.start_supervised!(
        {WebSocket, core: core, port: 0, authority: Hub.authority(hub)}
      )

    {:ok, [%{id: owner}]} = Hub.users(hub)

    %{
      hub: hub,
      core: core,
      data: data,
      owner: owner,
      hub_opts: opts,
      port: WebSocket.port(transport)
    }
  end

  # A user with a connection of its own token.
  def user(context, name) do
    {:ok, %{id: id}} = Hub.add_user(context.hub, name)
    {:ok, token} = Hub.create_token(context.hub, id, "laptop")
    {:ok, socket} = Client.upgrade(context.port)
    nonce = Client.challenge(socket)
    hello = Map.put(Client.hello(nonce, token), "token", hd(String.split(token, ".")))
    Client.send_frame(socket, hello)
    {:frame, %{"type" => "welcome"}} = Client.recv(socket)
    {id, socket}
  end

  def start(socket, model \\ "fake/echo") do
    start = %{"cwd" => File.cwd!(), "model" => model}
    %{"result" => %{"session" => id}} = Client.request(socket, "s", "start", start)
    id
  end

  def now, do: System.os_time(:second)

  # A schedule of `user` whose first wake-up is due now.
  def due(context, user, session_id, fields \\ %{}) do
    params =
      Map.merge(%{"session" => session_id, "at" => now() + 600, "prompt" => "wake up"}, fields)

    {:ok, %{id: id}} = Hub.schedule(context.hub, user, params)
    set(context.hub, id, at: now() - 1, due_at: now() - 1, next_try_at: now() - 1)
    id
  end

  # Runs `fun` on the state in the Hub process and gives its answer. The
  # answer comes before the reply of the system call, from the same sender.
  def in_hub(hub, fun) do
    test = self()

    :sys.replace_state(hub, fn state ->
      send(test, {:in_hub, fun.(state)})
      state
    end)

    assert_received {:in_hub, answer}
    answer
  end

  def row(hub, id) do
    in_hub(hub, fn s ->
      case s.store.schedule(s.db, id) do
        {:ok, row} -> row
        {:error, :not_found} -> nil
      end
    end)
  end

  def set(hub, id, columns) do
    sets = Enum.map_join(columns, ", ", fn {key, value} -> "#{key} = #{value}" end)

    :ok =
      in_hub(
        hub,
        &Exqlite.Sqlite3.execute(
          conn(&1.db),
          "UPDATE schedules SET #{sets} WHERE id = '#{id}'"
        )
      )
  end

  # The connection inside the handle of the store, for the row of a schedule
  # that only SQL writes.
  defp conn(%{db: db}), do: db

  def poll(hub), do: send(hub, :wake_poll)

  def wait_row(hub, id, check) do
    Helyx.Test.Events.wait_until(fn -> check.(row(hub, id)) end)
    row(hub, id)
  end

  def idle?(hub), do: in_hub(hub, &(map_size(&1.wake.tasks) == 0))

  # The user messages of a session with a product origin.
  def woken(core, session_id) do
    session = %Helyx.Session{id: session_id, core: core}

    for %Helyx.Message{role: :user, origin: %{kind: :product} = origin} = m <-
          Helyx.Test.Events.snapshot(session).messages,
        do: {Helyx.Message.text(m), origin.id}
  end
end
