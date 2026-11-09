defmodule Helyx.SessionsEditTest do
  # The delete of a saved session and the removal of a message from it
  # (#833, docs/features/session-edit.md).
  use ExUnit.Case, async: true

  import Helyx.Test.Events
  import Helyx.Test.SessionCase

  alias Helyx.{Message, Session, Sessions}
  alias Helyx.Session.File, as: SessionFile
  alias Helyx.Session.File.Edit
  alias Helyx.Session.Lock
  alias Helyx.Test.Memory
  alias Helyx.Test.PerlSignal
  alias Helyx.Test.SessionFile, as: Saved

  @moduletag :tmp_dir

  @cwd "/repo"

  setup %{tmp_dir: dir} do
    core = :"core_#{System.unique_integer([:positive])}"

    start_supervised!(
      {Helyx.Core,
       name: core, plugins: [Helyx.Test.Provider, Memory], sessions_dir: dir, model: "test/ok"},
      id: core
    )

    Process.register(self(), Memory.controller(core))
    %{core: core}
  end

  defp msg(role, text, extra \\ []) do
    struct!(Message, [role: role, id: Helyx.Session.Id.new(), content: [text(text)]] ++ extra)
  end

  defp text(text), do: %Message.Text{text: text}

  defp call(id), do: %Message.ToolCall{id: id, name: "read", arguments: %{"path" => id}}

  defp result(call_id, text),
    do: %{Message.tool_result(call(call_id), {:ok, text}) | id: Helyx.Session.Id.new()}

  # A saved session of `messages`, and its id and path.
  defp saved(dir, messages, entries \\ fn file, _messages -> file end) do
    id = Helyx.Session.Id.new()
    {:ok, file} = SessionFile.create(dir, id, @cwd, "test/ok")
    file = Enum.reduce(messages, file, &SessionFile.append_message(&2, &1))
    _file = entries.(file, messages)
    {id, file.path}
  end

  defp ids(messages), do: Enum.map(messages, & &1.id)

  defp resumed(dir, id) do
    {:ok, resumed} = Saved.resume(dir, nil, id: id)
    resumed.messages
  end

  describe "delete" do
    test "removes the file, so the list and a resume do not find it",
         %{core: core, tmp_dir: dir} do
      {id, path} = saved(dir, [msg(:user, "secret")])
      assert {:ok, [_], nil} = Sessions.list_saved(core, [])

      assert Sessions.delete(core, id) == :ok

      refute File.exists?(path)
      assert {:ok, [], nil} = Sessions.list_saved(core, [])
      assert Sessions.resume(core, id: id) == {:error, :not_found}
      assert Sessions.delete(core, id) == {:error, :not_found}
    end

    test "a running session is refused and its file does not change",
         %{core: core, tmp_dir: dir} do
      {:ok, session} = Sessions.start(core, cwd: @cwd)
      {:ok, _, ref} = Session.subscribe(session)
      :ok = Session.prompt(session, "hi")
      # The file is read after the turn, whose answer is appended to it.
      collect_until(:turn_end)
      Process.demonitor(ref, [:flush])
      [path] = Path.wildcard(Path.join([dir, "*", session.id <> ".jsonl"]))
      before = File.read!(path)

      assert Sessions.delete(core, session.id) == {:error, :running}
      assert Sessions.remove_message(core, session.id, "x") == {:error, :running}
      assert File.read!(path) == before
    end

    test "a lock that another process holds is refused", %{core: core, tmp_dir: dir} do
      {id, path} = saved(dir, [msg(:user, "a")])
      parent = self()

      holder =
        spawn(fn ->
          Process.flag(:trap_exit, true)
          {:ok, _lock} = Lock.take(path)
          send(parent, :held)
          Process.sleep(:infinity)
        end)

      assert_receive :held, 5_000
      assert Sessions.delete(core, id) == {:error, :running}
      assert Sessions.remove_message(core, id, "x") == {:error, :running}
      assert File.exists?(path)
      Process.exit(holder, :kill)
    end

    test "removes a left copy first and keeps the lock file; a failed remove keeps the file",
         %{core: core, tmp_dir: dir} do
      {id, path} = saved(dir, [msg(:user, "a")])
      File.write!(path <> ".tmp", "left")
      assert Sessions.delete(core, id) == :ok
      refute File.exists?(path <> ".tmp")
      assert File.exists?(Path.rootname(path) <> ".lock")

      {id, path} = saved(dir, [msg(:user, "a")])
      File.mkdir_p!(Path.join(path <> ".tmp", "x"))
      assert {:error, {:edit_failed, _text}} = Sessions.delete(core, id)
      assert File.exists?(path)
    end

    test "a file whose header does not parse is deleted", %{core: core, tmp_dir: dir} do
      id = Helyx.Session.Id.new()
      path = Path.join([dir, "p", id <> ".jsonl"])
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "not json\n")

      assert Sessions.delete(core, id) == :ok
      refute File.exists?(path)
    end

    test "a symlinked session file is refused", %{core: core, tmp_dir: dir} do
      {id, path} = saved(dir, [msg(:user, "SECRET-TEXT")])
      target = Path.join(dir, "elsewhere.data")
      File.rename!(path, target)
      File.ln_s!(target, path)

      assert Sessions.delete(core, id) == {:error, :not_regular}
      assert Sessions.remove_message(core, id, "x") == {:error, :not_regular}
      assert File.read!(target) =~ "SECRET-TEXT"
    end

    test "a bad id and a Core with no folder", %{core: core} do
      assert Sessions.delete(core, "../x") == {:error, :invalid_id}
      bare = start_core([Helyx.Test.Provider])
      assert Sessions.delete(bare, Helyx.Session.Id.new()) == {:error, :not_found}
    end
  end

  describe "remove_message" do
    # The entries of the file in order, each a map, with no torn line.
    defp entries(path) do
      for line <- String.split(File.read!(path), "\n", trim: true),
          {:ok, entry} = Helyx.JSON.decode(line),
          do: entry
    end

    # A `hook` entry as the session writes it (docs/features/hooks.md): the
    # first answer of a `before_tool` chain with the copy of the
    # arguments, or a failed `after_tool` hook with its reason.
    defp hook_entry(call_id, {:before, arguments}) do
      %{
        "type" => "hook",
        "point" => "before_tool",
        "turn_id" => Helyx.Session.Id.new(),
        "call_id" => call_id,
        "hook" => "Acme.Hook.Gate",
        "answer" => "allow",
        "reason" => "fine",
        "tool" => "read",
        "arguments" => arguments,
        "arguments_cut" => false
      }
    end

    defp hook_entry(call_id, {:after_failed, reason}) do
      %{
        "type" => "hook",
        "point" => "after_tool",
        "turn_id" => Helyx.Session.Id.new(),
        "call_id" => call_id,
        "hook" => "Acme.Hook.Check",
        "answer" => "failed",
        "reason" => reason
      }
    end

    defp call(id, arguments),
      do: %Message.ToolCall{id: id, name: "read", arguments: arguments}

    # docs/features/turn-record.md, "Overlap with #833": every
    # `system_prompt` entry stays as it is, cut text and `bytes` included,
    # in the order of the chain, with the parent of a removed message as
    # its parent. A `hook` entry of a removed call goes with it, and every
    # other one stays as a `system_prompt` entry does (session-edit.md,
    # decision 5).
    test "keeps every system_prompt entry and the other hook entries in chain order, " <>
           "and removes the hook entries of the removed calls",
         %{core: core, tmp_dir: dir} do
      u1 = msg(:user, "u1")

      a1 =
        msg(:assistant, "calling", model: "test/ok")
        |> Map.update!(:content, &(&1 ++ [call("c1", %{"path" => "ARG-MARK-833"})]))

      r1 = result("c1", "RESULT-MARK-833")
      u2 = msg(:user, "u2")

      a2 =
        msg(:assistant, "calling", model: "test/ok")
        |> Map.update!(:content, &(&1 ++ [call("c2", %{"path" => "kept"})]))

      r2 = result("c2", "kept result")
      a3 = msg(:assistant, "done", model: "test/ok")
      long = String.duplicate("p", SessionFile.max_system_bytes() + 10)

      {id, path} =
        saved(dir, [u1], fn file, _ ->
          file
          |> SessionFile.append_system_prompt("first")
          |> SessionFile.append_message(a1)
          |> SessionFile.append(hook_entry("c1", {:before, ~s({"path":"ARG-MARK-833"})}))
          |> SessionFile.append_message(r1)
          |> SessionFile.append(hook_entry("c1", {:after_failed, "saw RESULT-MARK-833"}))
          |> SessionFile.append_system_prompt(long)
          |> SessionFile.append_message(u2)
          |> SessionFile.append_message(a2)
          |> SessionFile.append(hook_entry("c2", {:before, ~s({"path":"kept"})}))
          |> SessionFile.append_message(r2)
          |> SessionFile.append_message(a3)
        end)

      before = entries(path)
      gone = for %{"type" => "hook", "call_id" => "c1"} = e <- before, do: e["id"]
      assert length(gone) == 2

      records = fn entries ->
        for %{"type" => t} = e <- entries,
            t in ["system_prompt", "hook"],
            do: Map.delete(e, "parent_id")
      end

      # Message ids only: the hook entries are no message.
      assert Sessions.remove_message(core, id, a1.id) == {:ok, [a1.id, r1.id]}

      after_ = entries(path)
      # The other records stay as they were, the cut text and `bytes` of
      # the long prompt included: its parent went, so it is encoded again.
      assert records.(after_) == Enum.reject(records.(before), &(&1["id"] in gone))
      assert %{"system" => cut} = Enum.find(records.(after_), &(&1["bytes"] == byte_size(long)))
      assert byte_size(cut) == SessionFile.max_system_bytes()
      assert [%{"call_id" => "c2"}] = for(%{"type" => "hook"} = e <- after_, do: e)
      # File order is the order before, without the removed entries.
      assert Enum.map(after_, & &1["id"]) == Enum.map(before, & &1["id"]) -- [a1.id, r1.id | gone]
      # One chain: each entry after the header has the entry before it as
      # its parent.
      for [prev, next] <- Enum.chunk_every(after_, 2, 1, :discard),
          do: assert(next["parent_id"] == prev["id"])

      # No byte of the arguments or the result of the removed call is left.
      refute File.read!(path) =~ "ARG-MARK-833"
      refute File.read!(path) =~ "RESULT-MARK-833"

      assert ids(resumed(dir, id)) == [u1.id, u2.id, a2.id, r2.id, a3.id]

      # A resume reads the records and keeps none: no entry is invalid.
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          {:ok, session} = Sessions.resume(core, id: id)
          :ok = Sessions.stop(session)
        end)

      refute log =~ "not valid"

      assert Sessions.delete(core, id) == :ok
      refute File.exists?(path)
    end

    test "the file holds no byte of the text, and a resume keeps the order",
         %{core: core, tmp_dir: dir} do
      [a, b, c] = messages = [msg(:user, "one"), msg(:user, "SECRET-TEXT"), msg(:user, "three")]
      {id, path} = saved(dir, messages)

      assert Sessions.remove_message(core, id, b.id) == {:ok, [b.id]}

      refute File.read!(path) =~ "SECRET-TEXT"
      assert ids(resumed(dir, id)) == [a.id, c.id]
      refute File.exists?(path <> ".tmp")
    end

    test "a tool call takes its results, and a result takes its call and the other results",
         %{core: core, tmp_dir: dir} do
      user = msg(:user, "go")

      calls =
        msg(:assistant, "calling", model: "test/ok")
        |> Map.update!(:content, &(&1 ++ [call("c1"), call("c2")]))

      r1 = result("c1", "R-ONE")
      r2 = result("c2", "R-TWO")
      last = msg(:assistant, "done", model: "test/ok")
      messages = [user, calls, r1, r2, last]

      {id, path} = saved(dir, messages)
      assert Sessions.remove_message(core, id, r2.id) == {:ok, [calls.id, r1.id, r2.id]}
      refute File.read!(path) =~ "R-ONE"
      assert ids(resumed(dir, id)) == [user.id, last.id]

      {id, _path} = saved(dir, messages)
      assert Sessions.remove_message(core, id, calls.id) == {:ok, [calls.id, r1.id, r2.id]}
      assert ids(resumed(dir, id)) == [user.id, last.id]
    end

    test "a torn line is not copied, and the last line gets its newline",
         %{core: core, tmp_dir: dir} do
      [a, b, c] = [msg(:user, "one"), msg(:user, "two"), msg(:user, "three")]
      {id, path} = saved(dir, [a, b])
      # A torn append that holds the text, then a whole last entry with no
      # newline.
      File.write!(path, ~s({"type":"message","content":"TORN-TEXT\n), [:append])
      file = %SessionFile{path: path, leaf: b.id}
      SessionFile.append_message(file, c)
      File.write!(path, String.trim_trailing(File.read!(path), "\n"))

      assert Sessions.remove_message(core, id, b.id) == {:ok, [b.id]}
      refute File.read!(path) =~ "TORN-TEXT"
      assert String.ends_with?(File.read!(path), "\n")
      assert ids(resumed(dir, id)) == [a.id, c.id]
    end

    test "a tool result with no call before it goes alone", %{core: core, tmp_dir: dir} do
      [u, r, a] = [msg(:user, "u"), result("c1", "stray"), msg(:assistant, "a", model: "test/ok")]
      {id, _path} = saved(dir, [u, r, a])

      assert Sessions.remove_message(core, id, r.id) == {:ok, [r.id]}
      assert ids(resumed(dir, id)) == [u.id, a.id]
    end

    test "a last_id with no kept message before it is null", %{core: core, tmp_dir: dir} do
      [u, a] = [msg(:user, "u"), msg(:assistant, "a", model: "test/ok")]

      {id, path} =
        saved(dir, [u], fn file, _ ->
          file
          |> SessionFile.append_compaction("test", :manual, 9, 3, u.id)
          |> SessionFile.append_message(a)
        end)

      assert Sessions.remove_message(core, id, u.id) == {:ok, [u.id]}
      assert File.read!(path) =~ ~s("last_id":null)
      {:ok, read} = Saved.resume(dir, nil, id: id)
      assert ids(read.messages) == [a.id]
      assert read.compacted == nil
    end

    test "an unknown message changes nothing, also in a file with no last newline",
         %{core: core, tmp_dir: dir} do
      {id, path} = saved(dir, [msg(:user, "a")])
      File.write!(path, String.trim_trailing(File.read!(path), "\n"))
      before = File.read!(path)

      assert Sessions.remove_message(core, id, Helyx.Session.Id.new()) ==
               {:error, :message_not_found}

      assert File.read!(path) == before
    end

    test "a summary and a compaction that name a removed message name a kept one",
         %{core: core, tmp_dir: dir} do
      [u1, a1, u2, a2] =
        messages = [
          msg(:user, "u1"),
          msg(:assistant, "a1", model: "test/ok"),
          msg(:user, "u2"),
          msg(:assistant, "a2", model: "test/ok")
        ]

      {id, _path} =
        saved(dir, messages, fn file, _ ->
          summary = %Helyx.Summary{text: "sum", first_kept_id: u2.id, tokens_before: 5}

          file
          |> SessionFile.append_summary(summary, a2.id)
          |> SessionFile.append_compaction("test", :manual, 9, 3, a2.id)
        end)

      assert Sessions.remove_message(core, id, u2.id) == {:ok, [u2.id]}
      {:ok, read} = Saved.resume(dir, nil, id: id)
      assert ids(read.messages) == [u1.id, a1.id, a2.id]
      assert read.summary.first_kept_id == a2.id
      assert read.compacted == {a2.id, 3}

      assert Sessions.remove_message(core, id, a2.id) == {:ok, [a2.id]}
      {:ok, read} = Saved.resume(dir, nil, id: id)
      assert ids(read.messages) == [u1.id, a1.id]
      # No kept message after the first kept one: the summary goes.
      assert read.summary == nil
      assert read.compacted == {a1.id, 3}
    end

    test "a resume gives no removed message to the memory sync", %{core: core, tmp_dir: dir} do
      [a, b] = [msg(:user, "keep"), msg(:user, "gone")]
      {id, _path} = saved(dir, [a, b])

      assert {:ok, [_]} = Sessions.remove_message(core, id, b.id)
      {:ok, session} = Sessions.resume(core, id: id)

      assert_receive {:sync, entries, _opts}, 5_000
      assert Enum.map(entries, & &1.message.id) == [a.id]
      :ok = Sessions.stop(session)
    end
  end

  describe "the end of the edit Task" do
    # Runs `call` in a new process that sends `{tag, result}`, and gives the
    # edit Task that the call starts, held with `:erlang.suspend_process/1`:
    # the Task supervisor of `core` waits while the call queues its start,
    # so the poll finds the Task new, after a short run that as a rule ends
    # before its lock take.
    defp held_task(core, tag, call) do
      sup = Process.whereis(Helyx.Core.task_supervisor(core))
      parent = self()
      true = :erlang.suspend_process(sup)
      spawn(fn -> send(parent, {tag, call.()}) end)
      poll_until(fn -> Process.info(sup, :message_queue_len) == {:message_queue_len, 1} end)
      true = :erlang.resume_process(sup)

      poll_until(fn ->
        case Task.Supervisor.children(sup) do
          [pid] -> :erlang.suspend_process(pid) and pid
          _none -> false
        end
      end)
    end

    # Polls `fun` until it gives a value other than false, and flunks after
    # 10,000 ms: the window of a race that the poll waits for can pass.
    defp poll_until(fun, deadline \\ System.monotonic_time(:millisecond) + 10_000) do
      case fun.() do
        false ->
          if System.monotonic_time(:millisecond) > deadline, do: flunk("the poll timed out")
          poll_until(fun, deadline)

        value ->
          value
      end
    end

    defp big_session(dir) do
      saved(dir, for(n <- 1..3_000, do: msg(:user, String.duplicate("x", 1_000) <> "#{n}")))
    end

    # A kill that the killer did not send, as the kill of the Task
    # supervisor at a Core stop, can come after the rename was sent.
    test "a kill that is not the killer's is :unknown", %{core: core, tmp_dir: dir} do
      {id, _path} = big_session(dir)
      [first | _] = resumed(dir, id)
      task = held_task(core, :removed, fn -> Sessions.remove_message(core, id, first.id) end)
      Process.exit(task, :kill)
      assert_receive {:removed, {:error, :unknown}}, 5_000

      {id, _path} = big_session(dir)
      Process.exit(held_task(core, :deleted, fn -> Sessions.delete(core, id) end), :kill)
      assert_receive {:deleted, {:error, :unknown}}, 5_000
    end

    # The deadline of a small file is 25,000 ms and some.
    @tag :slow
    @tag timeout: 120_000
    test "the kill of the killer is :timeout, and the file does not change",
         %{core: core, tmp_dir: dir} do
      {id, path} = big_session(dir)
      before = File.read!(path)
      [first | _] = resumed(dir, id)
      task = held_task(core, :removed, fn -> Sessions.remove_message(core, id, first.id) end)
      ref = Process.monitor(task)
      assert_receive {:removed, {:error, :timeout}}, 60_000
      assert_receive {:DOWN, ^ref, :process, ^task, :killed}
      assert File.read!(path) == before
    end
  end

  describe "a session that lost its lock" do
    # The edit waits at the Task supervisor of its Core, so before its take;
    # a resume takes the lock, its perl ends, and the session goes on in
    # memory, registered. The edit then takes the free lock (Codex gate of
    # #833).
    test "is refused after the take, and the file does not change", %{tmp_dir: dir} do
      dir = Path.join(dir, "lost")
      core = :"core_#{System.unique_integer([:positive])}"

      start_supervised!(
        {Helyx.Core, name: core, plugins: [Helyx.Test.Provider], sessions_dir: dir},
        id: core
      )

      first = msg(:user, "one")
      {id, path} = saved(dir, [first, msg(:user, "two")])
      parent = self()

      for {name, call} <- [
            remove: fn -> Sessions.remove_message(core, id, first.id) end,
            delete: fn -> Sessions.delete(core, id) end
          ] do
        sup = Process.whereis(Helyx.Core.task_supervisor(core))
        true = :erlang.suspend_process(sup)
        spawn(fn -> send(parent, {name, call.()}) end)

        await(
          fn -> Process.info(sup, :message_queue_len) == {:message_queue_len, 1} end,
          "the edit to wait"
        )

        {:ok, session} = Sessions.resume(core, id: id)
        pid = Session.pid(session)
        lock_path = Path.rootname(path) <> ".lock"
        PerlSignal.send!(PerlSignal.pid(:sys.get_state(pid).lock, lock_path), "KILL", lock_path)
        await(fn -> :sys.get_state(pid).lock == nil end, "the session to lose its lock")
        before = File.read!(path)

        true = :erlang.resume_process(sup)
        assert_receive {^name, {:error, :running}}, 5_000
        assert File.read!(path) == before
        :ok = Sessions.stop(session)
      end
    end
  end

  describe "a removal whose lock holder ends" do
    # The removal waits for perl's answer to a command on its copy; perl
    # answers and then ends, so the lock is free, and a delete takes it and
    # removes the file and the copy. The removal goes on in its Task, which
    # traps exits, and must write no copy after that (Codex gate of #833,
    # round 2). The hold is at the first command after the read: the create
    # of the copy (`c`), or `r` of an old copy in the code before the fix.
    test "leaves no copy after a delete, held at the create of the copy",
         %{core: core, tmp_dir: dir} do
      lose_lock(core, dir, [])
    end

    # The hold is at the first append to the copy: the copy is made and the
    # session file is open in the Task, so a write of the copy that does
    # not go through perl would make the copy again after the delete.
    test "leaves no copy after a delete, held at an append to the copy",
         %{core: core, tmp_dir: dir} do
      lose_lock(core, dir, [{Edit, :flush}])
    end

    # perl stops after its answer to the take, so the Task, after its read
    # of the file, waits at its first command; each frame of `then` lets
    # perl answer that command and stops it again, so the Task waits at its
    # next command, the one in `frame`. At the last hold perl answers and
    # is killed, and a delete runs before the Task goes on.
    defp lose_lock(core, dir, then) do
      text = String.duplicate("x", 1_000)
      {id, path} = saved(dir, for(n <- 1..3_000, do: msg(:user, text <> "#{n}")))
      tmp = path <> ".tmp"
      [first | _] = resumed(dir, id)
      task = held_task(core, :removed, fn -> Sessions.remove_message(core, id, first.id) end)

      # perl starts in some ms; the Task waits for its answer to the take.
      # The port is in the list before the VM has started perl, and it
      # reports the os pid 0 until then: `PerlSignal.pid/2` waits for the
      # pid and checks it (a `kill -STOP 0` froze a precommit run).
      true = :erlang.resume_process(task)
      port = poll_until(fn -> lock_port(task) end)
      true = :erlang.suspend_process(task)
      lock_path = Path.rootname(path) <> ".lock"
      perl = PerlSignal.pid(port, lock_path)
      on_exit(fn -> PerlSignal.continue(perl, lock_path) end)
      if in_frames?(task, {Lock, :read_answer}), do: answered(task)
      refute File.exists?(tmp)
      PerlSignal.send!(perl, "STOP", lock_path)
      true = :erlang.resume_process(task)
      waits_at(task, {Edit, :replace})

      for frame <- then do
        PerlSignal.send!(perl, "CONT", lock_path)
        answered(task)
        PerlSignal.send!(perl, "STOP", lock_path)
        true = :erlang.resume_process(task)
        waits_at(task, frame)
      end

      PerlSignal.send!(perl, "CONT", lock_path)
      answered(task)
      PerlSignal.send!(perl, "KILL", lock_path)
      Saved.await_lock_free(path)

      assert Sessions.delete(core, id) == :ok
      true = :erlang.resume_process(task)
      assert_receive {:removed, {:error, _reason}}, 10_000
      refute File.exists?(path)
      refute File.exists?(tmp)
    end

    # The Task waits for the answer of a command that `frame` sent, and is
    # held there.
    defp waits_at(task, frame) do
      poll_until(fn -> in_frames?(task, {Lock, :read_answer}) and in_frames?(task, frame) end)
      true = :erlang.suspend_process(task)
    end

    # The held Task has the answer of perl in its mailbox.
    defp answered(task),
      do: poll_until(fn -> Process.info(task, :message_queue_len) != {:message_queue_len, 0} end)

    defp lock_port(task) do
      case for(p <- Port.list(), Port.info(p, :connected) == {:connected, task}, do: p) do
        [port] -> port
        [] -> false
      end
    end

    defp in_frames?(task, frame) do
      {:current_stacktrace, stack} = Process.info(task, :current_stacktrace)
      frame in for({module, function, _arity, _location} <- stack, do: {module, function})
    end
  end
end
