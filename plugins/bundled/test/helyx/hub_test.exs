defmodule Helyx.HubTest do
  use ExUnit.Case, async: true

  alias Helyx.Hub
  alias Helyx.Hub.Store.SQLite

  @moduletag :tmp_dir

  # A Core with no data folder: each test gives the store its own :path.
  setup do
    core = :"hub_core_#{System.unique_integer([:positive])}"
    start_supervised!({Helyx.Core, name: core, plugins: [Helyx.Provider.Fake]}, id: :core)
    Process.put(:core, core)
    :ok
  end

  defp core, do: Process.get(:core)

  defp start_hub(dir, opts \\ []) do
    opts =
      Keyword.merge(
        [core: core(), default_owner: "owner", path: Path.join(dir, "hub.db")],
        opts
      )

    hub = start_supervised!(Supervisor.child_spec({Hub, opts}, id: :hub))
    # The Hub handled its start, so no message of it comes later.
    :sys.get_state(hub)
    hub
  end

  describe "start" do
    test "makes the default owner once and keeps it across a restart", %{tmp_dir: dir} do
      hub = start_hub(dir)
      assert {:ok, [%{name: "owner", id: id}]} = Hub.users(hub)
      assert byte_size(id) == 12
      :ok = stop_supervised(:hub)

      hub = start_hub(dir)
      assert {:ok, [%{name: "owner", id: ^id}]} = Hub.users(hub)
    end

    test "a bad option gives its key", %{tmp_dir: dir} do
      path = Path.join(dir, "hub.db")

      for {key, value} <- [
            core: "core",
            core: :not_running,
            name: "hub",
            store: :not_a_store,
            store: "store",
            store: File,
            name: {:via, :no_such_module, :x},
            name: {:global, :hub},
            name: {:via, :global, :hub},
            default_owner: "",
            default_owner: "a\nb",
            server_token: "secret",
            server_token: fn _ -> "x" end,
            max_live_sessions: 0,
            max_live_sessions: 65,
            path: ""
          ] do
        opts = Keyword.merge([core: core(), default_owner: "o", path: path], [{key, value}])
        assert Hub.start_link(opts) == {:error, {:invalid_option, key}}
      end

      assert Hub.start_link(default_owner: "o", path: path) ==
               {:error, {:invalid_option, :core}}

      assert Hub.start_link(core: core(), path: path) ==
               {:error, {:invalid_option, :default_owner}}

      refute File.exists?(path)
    end

    test "the cap of live sessions takes 1 and 64", %{tmp_dir: dir} do
      for {cap, folder} <- [{1, "a"}, {64, "b"}] do
        path = Path.join([dir, folder, "hub.db"])
        File.mkdir!(Path.dirname(path))

        assert {:ok, hub} =
                 Hub.start_link(
                   core: core(),
                   default_owner: "o",
                   path: path,
                   max_live_sessions: cap
                 )

        GenServer.stop(hub)
      end
    end

    test "a folder that its group or other users can write is refused", %{tmp_dir: dir} do
      for mode <- [0o775, 0o757] do
        File.chmod!(dir, mode)

        assert start(Path.join(dir, "hub.db")) ==
                 {:error, :unsafe_folder}
      end

      File.chmod!(dir, 0o755)
      refute File.exists?(Path.join(dir, "hub.db"))
    end

    test "the default path is in the data folder of the Core", %{tmp_dir: dir} do
      core = :"core_#{System.unique_integer([:positive])}"
      File.chmod!(dir, 0o700)

      start_supervised!(
        {Helyx.Core, name: core, plugins: [Helyx.Provider.Fake], sessions_dir: dir}
      )

      hub = start_supervised!({Hub, core: core, default_owner: "owner"})
      assert {:ok, [_]} = Hub.users(hub)
      assert File.exists?(Path.join(dir, "hub.db"))
    end

    test "a Core with no data folder gets a store in memory" do
      core = :"core_#{System.unique_integer([:positive])}"
      start_supervised!({Helyx.Core, name: core, plugins: [Helyx.Provider.Fake]})
      hub = start_supervised!({Hub, core: core, default_owner: "owner"})
      {:ok, _} = Hub.add_user(hub, "ann")
      assert {:ok, [_, _]} = Hub.users(hub)
    end

    @tag :slow
    test "a second Hub on the store file fails its start with :store_locked", %{tmp_dir: dir} do
      start_hub(dir)

      assert start(Path.join(dir, "hub.db")) ==
               {:error, :store_locked}
    end

    test "a Core that does not run is a bad :core" do
      assert Hub.start_link(core: :not_running, default_owner: "o") ==
               {:error, {:invalid_option, :core}}
    end
  end

  describe "users" do
    test "the name bounds: 1 to 64 bytes of UTF-8 with no control character", %{tmp_dir: dir} do
      hub = start_hub(dir)
      at_limit = String.duplicate("a", 64)
      multibyte_at_limit = String.duplicate("a", 62) <> "é"
      multibyte_over = String.duplicate("a", 63) <> "é"

      assert {:ok, %{name: ^at_limit}} = Hub.add_user(hub, at_limit)
      assert {:ok, _} = Hub.add_user(hub, String.duplicate("b", 63))
      assert {:ok, _} = Hub.add_user(hub, multibyte_at_limit)
      assert {:ok, _} = Hub.add_user(hub, "z")

      for bad <- [
            "",
            String.duplicate("c", 65),
            multibyte_over,
            "a\tb",
            "a\x7fb",
            "a\u0085b",
            <<0xFF>>,
            :atom
          ] do
        assert Hub.add_user(hub, bad) == {:error, :invalid_name}
      end

      assert Hub.add_user(hub, "owner") == {:error, :invalid_name}
      assert {:ok, users} = Hub.users(hub)
      names = Enum.map(users, & &1.name)
      assert names == Enum.sort(names)
    end

    test "a Hub holds at most 64 users, the default owner among them", %{tmp_dir: dir} do
      hub = start_hub(dir)
      for i <- 1..63, do: {:ok, _} = Hub.add_user(hub, "u#{i}")
      assert Hub.add_user(hub, "u64") == {:error, :too_many_users}
      assert {:ok, users} = Hub.users(hub)
      assert length(users) == 64
    end

    test "remove: the default owner stays; an unknown id; tokens go with the user", %{
      tmp_dir: dir
    } do
      hub = start_hub(dir)
      {:ok, [%{id: owner}]} = Hub.users(hub)
      assert Hub.remove_user(hub, owner) == {:error, :default_owner}
      assert Hub.remove_user(hub, "missing") == {:error, :unknown_user}

      {:ok, %{id: ann}} = Hub.add_user(hub, "ann")
      {:ok, text} = Hub.create_token(hub, ann, "laptop")
      assert Hub.remove_user(hub, ann) == :ok
      assert Hub.revoke_token(hub, token_id(text)) == {:error, :unknown_token}
      assert {:ok, [%{id: ^owner}]} = Hub.users(hub)
    end
  end

  describe "tokens" do
    test "the text is <id>.<secret>, 56 characters, and the store keeps its SHA-256", %{
      tmp_dir: dir
    } do
      hub = start_hub(dir)
      {:ok, [%{id: owner}]} = Hub.users(hub)
      {:ok, text} = Hub.create_token(hub, owner, "laptop")

      assert byte_size(text) == 56
      assert [id, secret] = String.split(text, ".")
      assert id =~ ~r/\A[A-Za-z0-9_-]{12}\z/
      assert secret =~ ~r/\A[A-Za-z0-9_-]{43}\z/
      assert byte_size(Base.url_decode64!(secret, padding: false)) == 32

      :ok = stop_supervised(:hub)
      {:ok, db} = SQLite.open(path: Path.join(dir, "hub.db"))
      assert {:ok, %{key: key, user_id: ^owner, name: "laptop"}} = SQLite.token(db, id)
      assert key == :crypto.hash(:sha256, text)
      :ok = SQLite.close(db)
    end

    test "a user holds at most 16 tokens; names have the user name bounds", %{tmp_dir: dir} do
      hub = start_hub(dir)
      {:ok, [%{id: owner}]} = Hub.users(hub)

      assert {:ok, _} = Hub.create_token(hub, owner, String.duplicate("a", 64))
      assert {:ok, _} = Hub.create_token(hub, owner, String.duplicate("a", 62) <> "é")
      assert Hub.create_token(hub, owner, String.duplicate("a", 65)) == {:error, :invalid_name}

      assert Hub.create_token(hub, owner, String.duplicate("a", 63) <> "é") ==
               {:error, :invalid_name}

      assert Hub.create_token(hub, owner, "") == {:error, :invalid_name}
      assert Hub.create_token(hub, owner, "a\nb") == {:error, :invalid_name}

      for i <- 3..16, do: {:ok, _} = Hub.create_token(hub, owner, "t#{i}")
      assert Hub.create_token(hub, owner, "t17") == {:error, :too_many_tokens}
      assert Hub.create_token(hub, "missing", "t") == {:error, :unknown_user}
    end

    test "revoke", %{tmp_dir: dir} do
      hub = start_hub(dir)
      {:ok, [%{id: owner}]} = Hub.users(hub)
      {:ok, text} = Hub.create_token(hub, owner, "laptop")
      assert Hub.revoke_token(hub, token_id(text)) == :ok
      assert Hub.revoke_token(hub, token_id(text)) == {:error, :unknown_token}
    end
  end

  describe "the store file" do
    test "a :path that is a link or a folder is refused and keeps its mode", %{tmp_dir: dir} do
      target = Path.join(dir, "target.db")
      File.write!(target, "")
      File.chmod!(target, 0o644)
      link = Path.join(dir, "link.db")
      File.ln_s!(target, link)
      dangling = Path.join(dir, "dangling.db")
      File.ln_s!(Path.join(dir, "nowhere"), dangling)
      folder = Path.join(dir, "folder.db")
      File.mkdir!(folder)
      File.chmod!(folder, 0o755)

      for path <- [link, dangling, folder] do
        assert start(path) ==
                 {:error, {:invalid_option, :path}}
      end

      assert mode(target) == 0o644
      assert mode(folder) == 0o755
    end

    test "a :path with a second name, or a link beside it, is refused", %{tmp_dir: dir} do
      path = Path.join(dir, "hub.db")
      other = Path.join(dir, "other.db")
      File.write!(other, "")
      File.chmod!(other, 0o644)
      File.ln!(other, path)

      assert start(path) ==
               {:error, {:invalid_option, :path}}

      assert mode(other) == 0o644
      assert File.read!(other) == ""

      File.rm!(path)
      File.ln_s!(other, path <> "-wal")

      assert start(path) ==
               {:error, {:invalid_option, :path}}

      assert mode(other) == 0o644
    end

    test "an existing file and its WAL file get mode 0600", %{tmp_dir: dir} do
      path = Path.join(dir, "hub.db")
      {:ok, hub} = start(path)
      GenServer.stop(hub)
      File.write!(path <> "-wal", "")

      for file <- [path, path <> "-wal"], do: File.chmod!(file, 0o644)

      assert {:ok, hub} = start(path)

      for file <- [path, path <> "-wal"],
          do: assert(mode(file) == 0o600)

      GenServer.stop(hub)
    end

    test "a refused start changes nothing on the disk", %{tmp_dir: dir} do
      # A new path: no file is made.
      fresh = Path.join(dir, "fresh.db")
      File.ln_s!(Path.join(dir, "nowhere"), fresh <> "-journal")
      assert start(fresh) == {:error, {:invalid_option, :path}}
      assert File.ls!(dir) == ["fresh.db-journal"]

      # An existing file keeps its mode.
      path = Path.join(dir, "hub.db")
      {:ok, hub} = start(path)
      GenServer.stop(hub)
      File.chmod!(path, 0o644)
      File.mkdir!(path <> "-shm")
      bytes = File.read!(path)
      assert start(path) == {:error, {:invalid_option, :path}}
      assert mode(path) == 0o644
      assert File.read!(path) == bytes

      # A file of another version: refused after the lock, with no write.
      other = Path.join(dir, "other.db")
      {:ok, db} = Exqlite.Sqlite3.open(other)
      :ok = Exqlite.Sqlite3.execute(db, "PRAGMA user_version = 7")
      :ok = Exqlite.Sqlite3.close(db)
      File.chmod!(other, 0o644)
      bytes = File.read!(other)
      assert start(other) == {:error, {:store_version, 7}}
      assert mode(other) == 0o644
      assert File.read!(other) == bytes
      refute File.exists?(other <> "-wal")

      # A database of another program, version 0: refused with no write.
      foreign = Path.join(dir, "foreign.db")
      {:ok, db} = Exqlite.Sqlite3.open(foreign)
      :ok = Exqlite.Sqlite3.execute(db, "CREATE TABLE users (x INTEGER)")
      :ok = Exqlite.Sqlite3.close(db)
      File.chmod!(foreign, 0o644)
      bytes = File.read!(foreign)
      assert start(foreign) == {:error, {:store_version, 0}}
      assert mode(foreign) == 0o644
      assert File.read!(foreign) == bytes
    end

    test "the second name that a killed create left is removed by the next start", %{
      tmp_dir: dir
    } do
      path = Path.join(dir, "hub.db")
      {:ok, hub} = start(path)
      GenServer.stop(hub)
      left = Path.join(dir, ".hub-killed")
      File.mkdir!(left)
      File.ln!(path, Path.join(left, "hub.db"))

      assert {:ok, hub} = start(path)
      refute File.exists?(left)
      GenServer.stop(hub)
    end

    @tag :slow
    test "starts at once on a new path: one starts, the others get :store_locked", %{
      tmp_dir: dir
    } do
      path = Path.join(dir, "hub.db")
      core = core()

      results =
        1..8
        |> Enum.map(fn _ -> Task.async(fn -> start_unlinked(core, path) end) end)
        |> Task.await_many(30_000)

      assert Enum.count(results, &match?({:ok, _}, &1)) == 1, inspect(results)
      assert Enum.count(results, &(&1 == {:error, :store_locked})) == 7
      for {:ok, pid} <- results, do: GenServer.stop(pid)
      assert dir |> File.ls!() |> Enum.reject(&String.starts_with?(&1, "hub.db")) == []
    end

    test "a new file has mode 0600 and leaves no other file behind", %{tmp_dir: dir} do
      start_hub(dir)
      assert mode(Path.join(dir, "hub.db")) == 0o600
      assert dir |> File.ls!() |> Enum.reject(&String.starts_with?(&1, "hub.db")) == []
    end
  end

  # A store whose add_user reaches its commit at the deadline of the call.
  defmodule SlowStore do
    @behaviour Helyx.Hub.Store
    alias Helyx.Hub.Store.SQLite
    defdelegate open(opts), to: SQLite
    defdelegate close(db), to: SQLite
    defdelegate users(db), to: SQLite
    defdelegate remove_user(db, id, deadline), to: SQLite
    defdelegate token(db, id), to: SQLite
    defdelegate tokens(db, id), to: SQLite
    defdelegate add_token(db, token, max, deadline), to: SQLite
    defdelegate revoke_token(db, user, id, deadline), to: SQLite
    defdelegate user(db, id), to: SQLite
    defdelegate record(db, id), to: SQLite
    defdelegate records(db, ids), to: SQLite
    defdelegate count_records(db, owner), to: SQLite
    defdelegate put_record(db, record, max, deadline), to: SQLite
    defdelegate touch_record(db, id, at, prompt, deadline), to: SQLite
    defdelegate labels(db, ids), to: SQLite
    defdelegate update_record(db, id, new, changes, max, deadline), to: SQLite
    defdelegate delete_record(db, id, deadline), to: SQLite
    defdelegate search(db, user, filters), to: SQLite
    defdelegate projects(db, owner), to: SQLite
    defdelegate project(db, owner, id), to: SQLite
    defdelegate put_project(db, project, max, deadline), to: SQLite
    defdelegate rename_project(db, owner, id, name, deadline), to: SQLite
    defdelegate delete_project(db, owner, id, deadline), to: SQLite
    defdelegate saved(db, user, cwd, cursor, limit), to: SQLite
    defdelegate newest(db, owner, cwd), to: SQLite
    defdelegate hub_records?(db, owner), to: SQLite
    defdelegate schedules(db, owner, session_id), to: SQLite
    defdelegate schedule(db, id), to: SQLite
    defdelegate put_schedule(db, schedule, per_session, per_user, deadline), to: SQLite
    defdelegate delete_schedule(db, owner, id, deadline), to: SQLite
    defdelegate due(db, now, limit), to: SQLite
    defdelegate update_schedule(db, id, expect, changes, deadline), to: SQLite

    def add_user(db, user, max, :infinity), do: SQLite.add_user(db, user, max, :infinity)

    def add_user(db, user, max, deadline) do
      Process.sleep(max(deadline - System.monotonic_time(:millisecond), 0))
      SQLite.add_user(db, user, max, deadline)
    end
  end

  describe "Hub calls" do
    @tag :slow
    test "a write that reaches its commit at the deadline answers :timeout and writes nothing",
         %{tmp_dir: dir} do
      hub = start_hub(dir, store: SlowStore)
      assert Hub.add_user(hub, "ann") == {:error, :timeout}
      assert {:ok, [%{name: "owner"}]} = Hub.users(hub)
    end

    test "one under the admission bound sends the call", %{tmp_dir: dir} do
      hub = start_hub(dir)
      :erlang.suspend_process(hub)
      for _ <- 1..1_023, do: send(hub, :filler)
      task = Task.async(fn -> Hub.add_user(hub, "ann") end)

      ExUnit.CaptureLog.capture_log(fn ->
        # The call of the task is in the mailbox before the Hub runs again.
        wait_queue(hub, 1_024)
        :erlang.resume_process(hub)
        assert {:ok, %{name: "ann"}} = Task.await(task)
      end)
    end

    test "a full mailbox answers busy at once and sends nothing", %{tmp_dir: dir} do
      hub = start_hub(dir)
      :erlang.suspend_process(hub)
      for _ <- 1..1_024, do: send(hub, :filler)
      assert Hub.add_user(hub, "ann") == {:error, :busy}
      {:message_queue_len, n} = Process.info(hub, :message_queue_len)
      assert n == 1_024

      ExUnit.CaptureLog.capture_log(fn ->
        :erlang.resume_process(hub)
        :sys.get_state(hub)
      end)

      assert {:ok, [%{name: "owner"}]} = Hub.users(hub)
    end

    test "a call taken at or past its deadline is dropped before it writes", %{tmp_dir: dir} do
      hub = start_hub(dir)
      late = System.monotonic_time(:millisecond)

      assert catch_exit(GenServer.call(hub, {:hub, late, {:add_user, "ann"}}, 100))
      assert {:ok, [%{name: "owner"}]} = Hub.users(hub)
    end

    @tag :slow
    test "a Hub call exits its caller at 5,000 ms", %{tmp_dir: dir} do
      hub = start_hub(dir)
      :erlang.suspend_process(hub)
      assert {:timeout, _} = catch_exit(Hub.users(hub))
      :erlang.resume_process(hub)
    end

    test "a deadline of the caller before the one of the call: the write rolls back",
         %{tmp_dir: dir} do
      hub = start_hub(dir, store: SlowStore)
      now = System.monotonic_time(:millisecond)
      assert Hub.call(hub, {:add_user, "ann"}, now) == {:error, :timeout}
      assert Hub.call(hub, {:add_user, "ann"}, now + 300) == {:error, :timeout}
      assert {:ok, [%{name: "owner"}]} = Hub.users(hub)
    end

    test "a Hub that does not run exits the caller" do
      assert catch_exit(Hub.users(:no_such_hub))
    end
  end

  defp wait_queue(pid, n) do
    case Process.info(pid, :message_queue_len) do
      {:message_queue_len, ^n} ->
        :ok

      _ ->
        Process.sleep(5)
        wait_queue(pid, n)
    end
  end

  defp start(path), do: Hub.start_link(core: core(), default_owner: "o", path: path)

  # A start whose Hub outlives the Task that started it.
  defp start_unlinked(core, path) do
    with {:ok, pid} = ok <- Hub.start_link(core: core, default_owner: "o", path: path) do
      Process.unlink(pid)
      ok
    end
  end

  defp mode(path), do: Bitwise.band(File.stat!(path).mode, 0o777)

  defp token_id(text), do: text |> String.split(".") |> hd()
end
