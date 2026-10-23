defmodule Helyx.SessionsTest do
  # The server-management API (#657, docs/features/server-management.md).
  use ExUnit.Case, async: true

  import Helyx.Test.Events
  import Helyx.Test.SessionCase

  alias Helyx.{Message, Session, Sessions}
  alias Helyx.Session.File.Scan.Summary
  alias Helyx.Sessions.Live

  @moduletag :tmp_dir

  # A Core whose server configuration names the sessions folder and the
  # default model.
  setup %{tmp_dir: dir} do
    core = :"core_#{System.unique_integer([:positive])}"

    start_supervised!(
      {Helyx.Core,
       name: core, plugins: [Helyx.Test.Provider], sessions_dir: dir, model: "test/ok"},
      id: core
    )

    %{core: core}
  end

  defp turn(session, text) do
    {:ok, _, ref} = Session.subscribe(session)
    :ok = Session.prompt(session, text)
    collect_until(:turn_end)
    Process.demonitor(ref, [:flush])
  end

  describe "start and resume" do
    test "start takes the folder and the model of the Core", %{core: core, tmp_dir: dir} do
      {:ok, session} = Sessions.start(core, cwd: "/repo")
      turn(session, "hi")

      assert [%Live{id: id, cwd: "/repo", model: "test/ok", status: :idle}] =
               Sessions.list_live(core)

      assert id == session.id
      assert [_file] = Path.wildcard(Path.join([dir, "*", id <> ".jsonl"]))
    end

    test "a start with no model and no default model is an invalid model ref", %{tmp_dir: dir} do
      core = start_core([Helyx.Test.Provider])
      assert Sessions.start(core, cwd: dir) == {:error, {:invalid_model_ref, ""}}
    end

    test "a resume by id takes the folder of the header", %{core: core, tmp_dir: dir} do
      {:ok, session} = Sessions.start(core, cwd: "/elsewhere", model: "test/ok")
      turn(session, "hi")
      :ok = Sessions.stop(session)

      assert {:ok, ^session} = Sessions.resume(core, id: session.id)
      assert [%Live{cwd: "/elsewhere"}] = Sessions.list_live(core)
      :ok = Sessions.stop(session)

      # The rule is in `Session.resume/2` (#758).
      assert {:ok, ^session} = Session.resume(core, sessions_dir: dir, id: session.id)
      assert [%Live{cwd: "/elsewhere"}] = Sessions.list_live(core)
    end

    test "a header folder is checked as a given cwd", %{core: core, tmp_dir: dir} do
      id = Helyx.Session.Id.new()
      File.mkdir_p!(Path.join(dir, "p"))

      header =
        ~s({"type":"session","version":1,"id":"#{id}","cwd":"/a\\u0000b","model":"test/ok"})

      File.write!(Path.join([dir, "p", id <> ".jsonl"]), header <> "\n")

      assert Sessions.resume(core, id: id) == {:error, :invalid_cwd}
    end

    test "a resume of a session that runs attaches to it", %{core: core} do
      {:ok, session} = Sessions.start(core, cwd: "/repo")
      turn(session, "hi")
      pid = Session.pid(session)

      assert {:ok, ^session} = Sessions.resume(core, id: session.id)
      assert {:ok, ^session} = Sessions.resume(core, cwd: "/repo")
      assert Session.pid(session) == pid
      assert [%Live{}] = Sessions.list_live(core)
    end

    test "a resume of an id that is not a session id finds nothing", %{core: core} do
      assert Sessions.resume(core, id: "../x") == {:error, :invalid_id}
      assert Sessions.resume(core, id: Session.Id.new()) == {:error, :not_found}
    end

    test "a Core with no sessions folder has no saved session" do
      core = start_core([Helyx.Test.Provider])
      assert Sessions.resume(core, cwd: "/repo") == {:error, :not_found}
      assert Sessions.list_saved(core, []) == {:ok, [], nil}
    end
  end

  describe "concurrent resumes of one id" do
    test "both get the session when the open succeeds", %{core: core, tmp_dir: dir} do
      {first, pid, second} = held_pair(core, dir)
      send(pid, {:go, :ok})
      assert_receive {:started, ^first, {:ok, %Session{}}}
      assert_receive {:started, ^second, {:ok, %Session{}}}
    end

    test "both get the error of the open", %{core: core, tmp_dir: dir} do
      {first, pid, second} = held_pair(core, dir)
      send(pid, {:go, {:error, :boom}})
      assert_receive {:started, ^first, {:error, :boom}}
      assert_receive {:started, ^second, {:error, :boom}}
    end

    # The deadline of the open races the second start (#716), so the test
    # kills the open. lock_test.exs runs the deadline.
    test "both get :open_timeout when the open is killed", %{core: core, tmp_dir: dir} do
      {first, pid, second} = held_pair(core, dir)
      Process.exit(pid, :kill)
      assert_receive {:started, ^first, {:error, :open_timeout}}
      assert_receive {:started, ^second, {:error, :open_timeout}}
      # Only this line sees a run again of the second: its open blocks until
      # its deadline (25,000 ms) gives :open_timeout inside the receive
      # timeout (30,000 ms).
      refute_received {:in_open, _}
    end

    # The session of an ended caller stops after its open: no result of a
    # start, so the second start runs again and opens on its own.
    test "the second runs again when the first caller ends", %{core: core, tmp_dir: dir} do
      {first, pid, second} = held_pair(core, dir)
      ref = Process.monitor(pid)
      Process.exit(first, :kill)
      await_down(pid, first, "the session to get the end of its caller")
      send(pid, {:go, :ok})
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}

      assert_receive {:in_open, again}
      send(again, {:go, :ok})
      assert_receive {:started, ^second, {:ok, %Session{}}}
    end
  end

  # Two starts of one id: the open of the first waits for the test, and the
  # second is in the mailbox of the session process before the go.
  defp held_pair(core, dir) do
    test = self()
    {state, tools} = start_args(core)

    open =
      {Path.join(dir, state.id <> ".jsonl"),
       fn state ->
         send(test, {:in_open, self()})

         receive do
           {:go, :ok} -> {:ok, state}
           {:go, error} -> error
         end
       end}

    start = fn ->
      spawn(fn ->
        send(
          test,
          {:started, self(),
           Session.Server.start(state, {tools, Helyx.Tool.concurrent(tools)}, open)}
        )
      end)
    end

    first = start.()
    assert_receive {:in_open, pid}
    second = start.()

    await(
      fn -> Process.info(pid, :message_queue_len) == {:message_queue_len, 1} end,
      "the attach"
    )

    {first, pid, second}
  end

  defp start_args(core) do
    {:ok, ref} = Helyx.ModelRef.parse("test/ok")
    {:ok, provider} = Helyx.Provider.find(core, ref.provider)
    {:ok, tools} = Helyx.Tool.specs(core)

    state = %Session.Server.State{
      id: Session.Id.new(),
      core: core,
      model: ref,
      provider: provider,
      cwd: File.cwd!()
    }

    {state, tools}
  end

  describe "list_live/1" do
    test "a session with a turn is running, and a stopped one is gone", %{core: core} do
      {:ok, idle} = Sessions.start(core, cwd: "/a")
      {:ok, busy} = Sessions.start(core, cwd: "/b", model: gated_model())
      {:ok, snapshot, _ref} = Session.subscribe(busy)
      :ok = Session.prompt(busy, "hi")
      assert_receive {:waiting, gate}

      live = Map.new(Sessions.list_live(core), &{&1.id, &1})
      assert %{status: :idle, cwd: "/a"} = live[idle.id]

      assert %Live{status: :running, instance_id: instance, model: "test/gate." <> _} =
               live[busy.id]

      assert instance == snapshot.instance_id

      send(gate, :go)
      :ok = Sessions.stop(idle)
      assert [%Live{id: id}] = Sessions.list_live(core)
      assert id == busy.id
    end

    # The open of `held_pair/2` waits for the test, so the session does not
    # answer: the list waits for its deadline, then leaves it out.
    @tag :slow
    test "a session that does not answer is left out", %{core: core, tmp_dir: dir} do
      {:ok, idle} = Sessions.start(core, cwd: "/a")
      {_first, pid, _second} = held_pair(core, dir)
      assert [%Live{id: id}] = Sessions.list_live(core)
      assert id == idle.id
      send(pid, {:go, :ok})
    end

    test "a Core that is not running has no live session" do
      assert Sessions.list_live(:no_such_core) == []
    end
  end

  describe "stop/1" do
    test "aborts the turn, ends every subscription with :stopped, and frees the place", %{
      core: core
    } do
      {:ok, session} = Sessions.start(core, cwd: "/repo", model: gated_model())
      {:ok, _, ref} = Session.subscribe(session)
      :ok = Session.prompt(session, "hi")
      assert_receive {:waiting, _gate}

      assert :ok = Sessions.stop(session)
      events = collect_until(:turn_end)
      assert List.last(events).data == %{outcome: :aborted}
      assert_receive {:DOWN, ^ref, :process, _pid, reason}
      assert Session.end_reason(reason) == :stopped

      assert Sessions.stop(session) == {:error, :session_not_found}
      assert Sessions.list_live(core) == []
      assert {:ok, ^session} = Sessions.resume(core, id: session.id)
    end

    # The "stuck" call holds a handle whose release waits for the gate, and
    # "keep", which its release keeps (#752).
    test "reports the handles that a release left held" do
      core = start_core([Helyx.Test.Provider, Helyx.Test.Tool.Hold])
      {:ok, session} = Sessions.start(core, cwd: "/repo", model: "test/stuck")
      hands = :sys.get_state(Session.pid(session)).hands
      :ok = Session.prompt(session, Helyx.Test.Gate.open())

      await(
        fn -> :sys.get_state(hands).held |> Map.values() |> List.flatten() |> length() == 2 end,
        "the two holds"
      )

      stop = Task.async(fn -> Sessions.stop(session) end)
      assert_receive {:waiting, release}, wait_ms()
      send(release, :go)
      assert Task.await(stop, wait_ms()) == {:error, {:not_released, ["keep"]}}
      assert Session.pid(session) == nil
    end

    # The stop's abort waits for the release; another stop ends the session
    # first, so the report is unknown, not `:session_not_found`.
    test "another end during the abort gives :unknown" do
      core = start_core([Helyx.Test.Provider, Helyx.Test.Tool.Hold])
      {:ok, session} = Sessions.start(core, cwd: "/repo", model: "test/stuck")
      pid = Session.pid(session)
      hands = :sys.get_state(pid).hands
      :ok = Session.prompt(session, Helyx.Test.Gate.open())

      await(
        fn -> :sys.get_state(hands).held |> Map.values() |> List.flatten() |> length() == 2 end,
        "the two holds"
      )

      stop = Task.async(fn -> Sessions.stop(session) end)
      assert_receive {:waiting, release}, wait_ms()
      :erlang.trace(hands, true, [:receive])
      other = Task.async(fn -> GenServer.stop(pid) end)

      assert_receive {:trace, ^hands, :receive, {:"$gen_call", _from, {:stop, _deadline}}},
                     wait_ms()

      send(release, :go)

      assert Task.await(stop, wait_ms()) == {:error, {:not_released, :unknown}}
      assert Task.await(other, wait_ms()) == :ok
    end
  end

  describe "list_saved/2" do
    # A saved session with one user message, its file touched to `mtime`.
    defp saved(dir, cwd, mtime) do
      id = Session.Id.new()
      {:ok, file} = Session.File.create(dir, id, cwd, "test/ok")
      Helyx.Test.SessionFile.append_message(file, Message.user("p" <> id))
      File.touch!(file.path, mtime)
      id
    end

    defp page(core, opts) do
      {:ok, items, next} = Sessions.list_saved(core, opts)
      {Enum.map(items, & &1.id), next}
    end

    test "pages newest first by a cursor, and a new file moves no item", %{
      core: core,
      tmp_dir: dir
    } do
      # Two files in one second: the id breaks the tie.
      [a, b] = Enum.sort([saved(dir, "/repo", 1_000), saved(dir, "/repo", 1_000)])
      c = saved(dir, "/other", 2_000)
      d = saved(dir, "/repo", 3_000)

      {[^d, ^c], next} = page(core, limit: 2)
      # A session saved between two pages comes before the cursor.
      saved(dir, "/repo", 4_000)
      assert {[^b, ^a], nil} = page(core, limit: 2, after: next)

      assert {[_new, ^d, ^b, ^a], nil} = page(core, cwd: "/repo")

      {[_new], next} = page(core, cwd: "/repo", limit: 1)

      assert {:ok, [%Summary{id: ^d, cwd: "/repo", model: "test/ok", mtime: 3_000}], _} =
               Sessions.list_saved(core, cwd: "/repo", limit: 1, after: next)
    end

    test "the limit is from 1 to 256, with 50 by default", %{core: core, tmp_dir: dir} do
      for i <- 1..257, do: saved(dir, "/repo", i)

      assert {items, next} = page(core, [])
      assert length(items) == 50 and is_binary(next)
      assert {[_], _} = page(core, limit: 1)
      # The scan reads the 256 newest files.
      assert {items, nil} = page(core, limit: 256)
      assert length(items) == 256

      for bad <- [0, 257, -1, "1", nil] do
        assert Sessions.list_saved(core, limit: bad) == {:error, :invalid_limit}
      end
    end

    test "a bad cursor or folder is an error", %{core: core} do
      for bad <- ["", "x:abcdefghijkl", "1:short", "1", 1, "1:é" <> String.duplicate("a", 10)] do
        assert Sessions.list_saved(core, after: bad) == {:error, :invalid_cursor}
      end

      assert Sessions.list_saved(core, cwd: "a\0b") == {:error, :invalid_cwd}
      assert Sessions.list_saved(core, cwd: 1) == {:error, :invalid_cwd}
    end
  end

  describe "the server configuration" do
    test "Core refuses an option that is not a string" do
      for opts <- [
            [sessions_dir: 1],
            [sessions_dir: "a\0b"],
            [sessions_dir: <<255>>],
            [sessions_dir: "relative/sessions"],
            [model: :m],
            [model: "no-slash"]
          ] do
        [{key, _}] = opts

        assert Helyx.Core.start_link([name: :bad_core, plugins: [Helyx.Test.Provider]] ++ opts) ==
                 {:error, {:invalid_option, key}}
      end
    end
  end
end
