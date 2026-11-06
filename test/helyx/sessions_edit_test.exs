defmodule Helyx.SessionsEditTest do
  # The delete of a saved session and the removal of a message from it
  # (#833, docs/features/session-edit.md).
  use ExUnit.Case, async: true

  import Helyx.Test.Events
  import Helyx.Test.SessionCase

  alias Helyx.{Message, Session, Sessions}
  alias Helyx.Session.File, as: SessionFile
  alias Helyx.Session.Lock
  alias Helyx.Test.Memory
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
end
