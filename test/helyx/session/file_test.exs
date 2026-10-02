defmodule Helyx.Session.FileTest do
  use ExUnit.Case, async: true

  alias Helyx.{Message, Session}

  @moduletag :tmp_dir

  # Appends a hand-written entry as the child of the leaf of `file`, so it
  # is on the branch that a resume reads, and moves the leaf to it.
  defp append_raw(file, json) do
    entry = Map.put(JSON.decode!(json), "parent_id", file.leaf)
    File.write!(file.path, JSON.encode!(entry) <> "\n", [:append])
    %{file | leaf: entry["id"]}
  end

  defp texts(resumed), do: Enum.map(resumed.messages, &Message.text/1)

  test "create writes a header and resume restores the empty session", %{tmp_dir: dir} do
    {:ok, file} = Session.File.create(dir, "sess1", "/repo", "test/ok")

    assert {:ok, resumed} = Session.File.resume(dir, "/repo")
    assert resumed.session_id == "sess1"
    assert resumed.model == "test/ok"
    assert resumed.messages == []
    assert resumed.file.path == file.path
  end

  test "resume with no session for the directory", %{tmp_dir: dir} do
    assert {:error, :not_found} = Session.File.resume(dir, "/repo")
  end

  test "messages round-trip through the file", %{tmp_dir: dir} do
    call = %Message.ToolCall{id: "c1", name: "bash", arguments: %{"command" => "ls"}}

    assistant = %Message{
      role: :assistant,
      model: "test/ok",
      stop_reason: :tool_use,
      usage: %{"input" => 12, "output" => 3},
      content: [
        %Message.Thinking{thinking: "hmm", signature: "sig"},
        %Message.Text{text: "Listing."},
        call
      ]
    }

    result = %Message{
      role: :tool_result,
      tool_call_id: "c1",
      tool_name: "bash",
      is_error: true,
      content: [
        %Message.Text{text: "no such directory"},
        %Message.Image{mime_type: "image/png", data: "aGk="}
      ]
    }

    messages = [Message.user("List the tests."), assistant, result]

    {:ok, file} = Session.File.create(dir, "sess1", "/repo", "test/ok")
    Enum.reduce(messages, file, &Session.File.append_message(&2, &1))

    assert {:ok, resumed} = Session.File.resume(dir, "/repo")
    assert resumed.messages == messages
  end

  test "a model change entry is written and restored", %{tmp_dir: dir} do
    {:ok, file} = Session.File.create(dir, "sess1", "/repo", "test/ok")
    Session.File.append_model_change(file, "test/other")

    assert {:ok, resumed} = Session.File.resume(dir, "/repo")
    assert resumed.model == "test/other"
  end

  test "harness session entries are written, and the last one per provider is restored with the messages before it",
       %{tmp_dir: dir} do
    {:ok, file} = Session.File.create(dir, "sess1", "/repo", "claude-code/opus")
    assert {:ok, %{harness_sessions: sessions}} = Session.File.resume(dir, "/repo")
    assert sessions == %{}

    file
    |> Session.File.append_harness_session("claude-code", "first")
    |> Session.File.append_harness_session("codex", "codex-1")
    |> Session.File.append_message(Helyx.Message.user("hello"))
    |> Session.File.append_harness_session("claude-code", "sécond")

    assert {:ok, resumed} = Session.File.resume(dir, "/repo")

    assert resumed.harness_sessions == %{
             "claude-code" => {"sécond", 1},
             "codex" => {"codex-1", 0}
           }

    # The entry has the shape the feature doc gives, and it moves the leaf.
    entries =
      file.path |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&JSON.decode!/1)

    assert [_header, first, _codex, _message, last] = entries

    assert %{
             "type" => "harness_session",
             "provider" => "claude-code",
             "harness_session_id" => "first",
             "parent_id" => parent,
             "ts" => _
           } = first

    assert parent == hd(entries)["id"]
    assert resumed.file.leaf == last["id"]
  end

  test "a harness session entry with a bad id removes the label of its provider",
       %{tmp_dir: dir} do
    bad = [
      ~s({"id":"x","type":"harness_session","provider":"claude-code"}),
      ~s({"id":"x","type":"harness_session","provider":"claude-code","harness_session_id":null}),
      # The id is 1 to 256 bytes; 257 bytes, multibyte, and empty are bad.
      ~s({"id":"x","type":"harness_session","provider":"claude-code","harness_session_id":"a#{String.duplicate("é", 128)}"}),
      ~s({"id":"x","type":"harness_session","provider":"claude-code","harness_session_id":""})
    ]

    for {line, n} <- Enum.with_index(bad) do
      {:ok, file} = Session.File.create(dir, "sess#{n}", "/repo#{n}", "test/ok")

      file
      |> Session.File.append_harness_session("claude-code", "stale")
      |> Session.File.append_harness_session("codex", "codex-1")
      |> append_raw(line)

      # The stale label does not come back; the other provider keeps its own.
      assert {:ok, %{harness_sessions: sessions}} = Session.File.resume(dir, "/repo#{n}")
      assert sessions == %{"codex" => {"codex-1", 0}}
    end
  end

  test "a harness session entry with no usable provider removes every label",
       %{tmp_dir: dir} do
    bad = [
      ~s({"id":"x","type":"harness_session","harness_session_id":"a"}),
      ~s({"id":"x","type":"harness_session","provider":1,"harness_session_id":"a"})
    ]

    for {line, n} <- Enum.with_index(bad) do
      {:ok, file} = Session.File.create(dir, "sess#{n}", "/repo#{n}", "claude-code/opus")

      file
      |> Session.File.append_harness_session("claude-code", "old")
      |> Session.File.append_harness_session("codex", "codex-1")
      |> append_raw(line)
      |> Session.File.append_message(%Message{
        role: :assistant,
        model: "claude-code/opus",
        content: [%Message.Text{text: "t"}]
      })

      # The reader cannot know which label the damaged entry replaced, so
      # the later message of the old provider does not resume the old label.
      assert {:ok, resumed} = Session.File.resume(dir, "/repo#{n}")
      assert resumed.harness_sessions == %{}
      assert [%Message{role: :assistant}] = resumed.messages

      assert Helyx.Session.Transcript.resumable(
               resumed.messages,
               resumed.harness_sessions,
               "claude-code"
             ) == nil
    end
  end

  test "a valid harness session entry after one with no provider sets a label",
       %{tmp_dir: dir} do
    {:ok, file} = Session.File.create(dir, "later", "/later", "test/ok")
    line = ~s({"id":"x","type":"harness_session","harness_session_id":"a"})

    file
    |> append_raw(line)
    |> Session.File.append_harness_session("claude-code", "good")

    assert {:ok, %{harness_sessions: %{"claude-code" => {"good", 0}}}} =
             Session.File.resume(dir, "/later")
  end

  test "an entry with no string id is on no branch, nor any entry below it", %{tmp_dir: dir} do
    for {id, n} <- Enum.with_index([nil, 42]) do
      {:ok, file} = Session.File.create(dir, "sess#{n}", "/repo#{n}", "claude-code/opus")

      entry = %{
        "type" => "harness_session",
        "provider" => "claude-code",
        "harness_session_id" => "a"
      }

      entry = if id, do: Map.put(entry, "id", id), else: entry

      file
      |> append_raw(JSON.encode!(entry))
      |> Session.File.append_message(Message.user("below"))

      assert {:ok, resumed} = Session.File.resume(dir, "/repo#{n}")
      assert resumed.messages == []
      assert resumed.harness_sessions == %{}
    end
  end

  test "a harness session id of 256 bytes is kept", %{tmp_dir: dir} do
    # 256 bytes, multibyte, is the longest id kept; 255 bytes is kept too.
    for id <- [String.duplicate("é", 128), "a" <> String.duplicate("é", 127)] do
      cwd = "/long#{byte_size(id)}"
      {:ok, file} = Session.File.create(dir, "long#{byte_size(id)}", cwd, "test/ok")
      Session.File.append_harness_session(file, "claude-code", id)

      assert {:ok, %{harness_sessions: %{"claude-code" => {^id, 0}}}} =
               Session.File.resume(dir, cwd)
    end
  end

  test "a header with an unknown or missing version is rejected", %{tmp_dir: dir} do
    {:ok, file} = Session.File.create(dir, "sess1", "/repo", "test/ok")
    header = File.read!(file.path)

    File.write!(file.path, String.replace(header, ~s("version":1), ~s("version":99)))
    assert {:error, {:unknown_version, 99}} = Session.File.resume(dir, "/repo")

    File.write!(file.path, String.replace(header, ~s("version"), ~s("gone")))
    assert {:error, {:unknown_version, nil}} = Session.File.resume(dir, "/repo")
  end

  test "a torn last line is skipped, kept in the file, and the next entry starts a new line",
       %{tmp_dir: dir} do
    {:ok, file} = Session.File.create(dir, "sess1", "/repo", "test/ok")
    file = Session.File.append_message(file, Helyx.Message.user("kept"))
    torn = ~s({"id":"x","type":"mess)
    File.write!(file.path, torn, [:append])
    before = File.read!(file.path)

    assert {:ok, resumed} = Session.File.resume(dir, "/repo")
    assert [%Message{role: :user}] = resumed.messages
    assert resumed.file.leaf == file.leaf

    Session.File.append_message(resumed.file, Message.user("after"))
    after_append = File.read!(file.path)
    assert String.starts_with?(after_append, before <> "\n")
    [_header, _kept, ^torn, next] = String.split(after_append, "\n", trim: true)
    assert JSON.decode!(next)["parent_id"] == file.leaf

    assert {:ok, repaired} = Session.File.resume(dir, "/repo")
    assert texts(repaired) == ["kept", "after"]
    assert File.read!(file.path) == after_append
  end

  test "a torn last line after multibyte content is skipped, and the next append resumes", %{
    tmp_dir: dir
  } do
    {:ok, file} = Session.File.create(dir, "sess1", "/repo", "test/ok")
    file = Session.File.append_message(file, Message.user("héllo — ünïcode ✓"))
    File.write!(file.path, ~s({"torn), [:append])

    assert {:ok, resumed} = Session.File.resume(dir, "/repo")

    Session.File.append_message(resumed.file, Message.user("after"))
    assert {:ok, repaired} = Session.File.resume(dir, "/repo")
    assert texts(repaired) == ["héllo — ünïcode ✓", "after"]
  end

  test "a rejected file is not repaired", %{tmp_dir: dir} do
    {:ok, file} = Session.File.create(dir, "sess1", "/repo", "test/ok")
    append_raw(file, ~s({"id":"x","type":"note"}))
    File.write!(file.path, ~s({"torn), [:append])
    before = File.read!(file.path)

    assert {:error, {:invalid_file, _}} = Session.File.resume(dir, "/repo")
    assert File.read!(file.path) == before
  end

  test "a complete last entry missing only its newline is repaired", %{tmp_dir: dir} do
    {:ok, file} = Session.File.create(dir, "sess1", "/repo", "test/ok")
    file = Session.File.append_message(file, Message.user("kept"))
    File.write!(file.path, String.trim_trailing(File.read!(file.path), "\n"))

    assert {:ok, resumed} = Session.File.resume(dir, "/repo")

    Session.File.append_message(resumed.file, Message.user("after"))
    assert {:ok, repaired} = Session.File.resume(dir, "/repo")
    assert Enum.map(repaired.messages, &Message.text/1) == ["kept", "after"]
  end

  test "resume picks the most recently started session for the directory", %{tmp_dir: dir} do
    {:ok, _} = Session.File.create(dir, "older", "/repo", "test/ok")
    {:ok, _} = Session.File.create(dir, "newer", "/repo", "test/ok")

    assert {:ok, resumed} = Session.File.resume(dir, "/repo")
    assert resumed.session_id == "newer"
  end

  test "two directories with one slug do not cross", %{tmp_dir: dir} do
    {:ok, _} = Session.File.create(dir, "sess1", "/repo/a-b", "test/ok")
    {:ok, _} = Session.File.create(dir, "sess2", "/repo/a/b", "test/ok")

    assert {:ok, resumed} = Session.File.resume(dir, "/repo/a-b")
    assert resumed.session_id == "sess1"
  end

  test "an entry with a shape this module never writes is rejected, not raised", %{tmp_dir: dir} do
    bad = ~s({"id":"x","ts":"t","type":"message","role":"system","content":[]})
    {:ok, file} = Session.File.create(dir, "sess1", "/repo", "test/ok")
    append_raw(file, bad)

    assert {:error, {:invalid_file, _}} = Session.File.resume(dir, "/repo")
  end

  test "an unwritable directory is an error, not a raise", %{tmp_dir: dir} do
    not_a_dir = Path.join(dir, "flat")
    File.write!(not_a_dir, "")

    assert {:error, {:create_failed, _}} =
             Session.File.create(not_a_dir, "sess1", "/repo", "test/ok")
  end

  test "a long working directory path still gets a file", %{tmp_dir: dir} do
    cwd = "/" <> String.duplicate("deep/", 80)
    {:ok, _} = Session.File.create(dir, "sess1", cwd, "test/ok")

    assert {:ok, resumed} = Session.File.resume(dir, cwd)
    assert resumed.session_id == "sess1"
  end

  test "a line mid-file that is not an entry is skipped and kept", %{tmp_dir: dir} do
    {:ok, file} = Session.File.create(dir, "sess1", "/repo", "test/ok")
    File.write!(file.path, "not json\n[1]\n\n{}\n", [:append])
    Session.File.append_message(file, Message.user("kept"))
    before = File.read!(file.path)

    assert {:ok, resumed} = Session.File.resume(dir, "/repo")
    assert texts(resumed) == ["kept"]
    assert File.read!(file.path) == before
  end

  describe "the file as a tree" do
    test "two writers make two branches; a resume reads the branch of the last write, unmixed",
         %{tmp_dir: dir} do
      {:ok, file} = Session.File.create(dir, "sess1", "/repo", "test/ok")
      shared = Session.File.append_message(file, Message.user("shared"))

      # Two writers hold the same leaf and append in turn.
      a = Session.File.append_message(shared, Message.user("a1"))
      b = Session.File.append_message(shared, Message.user("b1"))
      a = Session.File.append_model_change(a, "test/a")
      a = Session.File.append_message(a, Message.user("a2"))
      b = Session.File.append_message(b, Message.user("b2"))

      assert {:ok, resumed} = Session.File.resume(dir, "/repo")
      assert texts(resumed) == ["shared", "b1", "b2"]
      assert resumed.model == "test/ok"
      assert resumed.file.leaf == b.leaf

      Session.File.append_message(a, Message.user("a3"))
      assert {:ok, resumed} = Session.File.resume(dir, "/repo")
      assert texts(resumed) == ["shared", "a1", "a2", "a3"]
      assert resumed.model == "test/a"
    end

    # #282: the other branch may have continued the harness session too.
    test "a fork at or below a harness session label drops every label; a fork above keeps it",
         %{tmp_dir: dir} do
      start = fn n ->
        {:ok, file} = Session.File.create(dir, "s#{n}", "/r#{n}", "claude-code/opus")

        file
        |> Session.File.append_harness_session("codex", "codex-1")
        |> Session.File.append_message(Message.user("one"))
      end

      label = &Session.File.append_harness_session(&1, "claude-code", "h1")
      user = &Session.File.append_message(&1, Message.user(&2))

      labels = fn cwd ->
        {:ok, resumed} = Session.File.resume(dir, cwd)
        resumed.harness_sessions
      end

      # A fork below the label.
      labelled = label.(start.(0))
      user.(labelled, "a")
      user.(labelled, "b")
      assert labels.("/r0") == %{}

      # A fork at the label: both children of the label entry hold it.
      labelled = label.(start.(1))
      user.(labelled, "a")
      assert labels.("/r1") == %{"claude-code" => {"h1", 1}, "codex" => {"codex-1", 0}}
      user.(labelled, "b")
      assert labels.("/r1") == %{}

      # A fork above the label: the other branch never had it. The codex
      # label above the fork is dropped.
      file = start.(2)
      user.(file, "other")
      file |> user.("mine") |> label.() |> user.("after")
      assert labels.("/r2") == %{"claude-code" => {"h1", 2}}
    end

    test "a session file of one writer resumes as one chain in file order", %{tmp_dir: dir} do
      # The lines a writer before #266 made: each parent_id is the line above.
      lines = [
        ~s({"id":"h","parent_id":null,"ts":"t","type":"session","version":1,"cwd":"/repo","model":"test/ok"}),
        ~s({"id":"m1","parent_id":"h","ts":"t","type":"message","role":"user","content":[{"type":"text","text":"one"}]}),
        ~s({"id":"c","parent_id":"m1","ts":"t","type":"model_change","model":"test/two"}),
        ~s({"id":"m2","parent_id":"c","ts":"t","type":"message","role":"user","content":[{"type":"text","text":"two"}]})
      ]

      {:ok, file} = Session.File.create(dir, "old", "/repo", "test/ok")
      File.write!(file.path, Enum.map_join(lines, &(&1 <> "\n")))

      assert {:ok, resumed} = Session.File.resume(dir, "/repo")
      assert texts(resumed) == ["one", "two"]
      assert resumed.model == "test/two"
      assert resumed.file.leaf == "m2"
    end

    test "an entry whose parent is not an earlier entry is on no branch, nor any entry below it",
         %{tmp_dir: dir} do
      message = fn id, parent, text ->
        ~s({"id":"#{id}","parent_id":#{parent},"type":"message","role":"user","content":[{"type":"text","text":"#{text}"}]})
      end

      # A missing parent, a null parent, a parent later in the file (and so
      # a cycle), and an entry that is its own parent.
      cases = [
        [message.("d", ~s("gone"), "dangling"), message.("e", ~s("d"), "below")],
        [message.("n", "null", "null parent")],
        [message.("f", ~s("g"), "forward"), message.("g", ~s("f"), "cycle")],
        [message.("s", ~s("s"), "self")]
      ]

      for {lines, n} <- Enum.with_index(cases) do
        {:ok, file} = Session.File.create(dir, "s#{n}", "/r#{n}", "test/ok")
        file = Session.File.append_message(file, Message.user("kept"))
        File.write!(file.path, Enum.map_join(lines, &(&1 <> "\n")), [:append])
        before = File.read!(file.path)

        assert {:ok, resumed} = Session.File.resume(dir, "/r#{n}")
        assert texts(resumed) == ["kept"]
        assert resumed.file.leaf == file.leaf
        assert File.read!(file.path) == before
      end

      # The header is the root whatever its own parent_id names.
      {:ok, file} = Session.File.create(dir, "root", "/root", "test/ok")
      [header] = String.split(File.read!(file.path), "\n", trim: true)
      header = header |> JSON.decode!() |> Map.put("parent_id", "m") |> JSON.encode!()
      File.write!(file.path, header <> "\n")
      append_raw(file, message.("m", "null", "on the header"))

      assert {:ok, resumed} = Session.File.resume(dir, "/root")
      assert texts(resumed) == ["on the header"]
    end

    test "a repeated id: the branch before the repeat stands, a child after it is on no branch",
         %{tmp_dir: dir} do
      {:ok, file} = Session.File.create(dir, "sess1", "/repo", "test/ok")
      first = append_raw(file, ~s({"id":"x","type":"message","role":"user","content":[]}))
      child = Session.File.append_message(first, Message.user("child of the first"))
      File.write!(file.path, ~s({"id":"x","parent_id":null,"type":"note"}\n), [:append])
      before = File.read!(file.path)

      assert {:ok, resumed} = Session.File.resume(dir, "/repo")
      assert texts(resumed) == ["", "child of the first"]
      assert resumed.file.leaf == child.leaf
      assert File.read!(file.path) == before

      # A child after the repeat cannot tell the two apart.
      Session.File.append_message(first, Message.user("after the repeat"))
      assert {:ok, resumed} = Session.File.resume(dir, "/repo")
      assert texts(resumed) == ["", "child of the first"]

      # The id of the header too: the header stays the root, and a child
      # after the repeat is on no branch.
      {:ok, file} = Session.File.create(dir, "sess2", "/repo2", "test/ok")
      kept = Session.File.append_message(file, Message.user("kept"))
      append_raw(file, ~s({"id":"#{file.leaf}","type":"model_change","model":"test/other"}))
      Session.File.append_message(file, Message.user("after the repeat"))

      assert {:ok, resumed} = Session.File.resume(dir, "/repo2")
      assert texts(resumed) == ["kept"]
      assert resumed.file.leaf == kept.leaf
      assert resumed.model == "test/ok"
    end

    test "a repeated id is never the leaf, so work after a resume is kept", %{tmp_dir: dir} do
      {:ok, file} = Session.File.create(dir, "sess1", "/repo", "test/ok")
      kept = Session.File.append_message(file, Message.user("kept"))
      x = append_raw(kept, ~s({"id":"x","type":"message","role":"user","content":[]}))
      File.write!(x.path, ~s({"id":"x","parent_id":null,"type":"note"}\n), [:append])

      assert {:ok, resumed} = Session.File.resume(dir, "/repo")
      assert resumed.file.leaf == kept.leaf
      assert texts(resumed) == ["kept"]

      Session.File.append_message(resumed.file, Message.user("new work"))
      assert {:ok, resumed} = Session.File.resume(dir, "/repo")
      assert texts(resumed) == ["kept", "new work"]
    end

    test "a repeat of the header id with no other leaf is refused, the file unchanged",
         %{tmp_dir: dir} do
      {:ok, file} = Session.File.create(dir, "sess1", "/repo", "test/ok")
      File.write!(file.path, ~s({"id":"#{file.leaf}","type":"note"}\n), [:append])
      before = File.read!(file.path)

      assert {:error, {:invalid_file, _reason}} = Session.File.resume(dir, "/repo")
      assert File.read!(file.path) == before
    end
  end

  test "a repair that cannot write is an environment error", %{tmp_dir: dir} do
    {:ok, file} = Session.File.create(dir, "sess1", "/repo", "test/ok")
    File.write!(file.path, ~s({"torn), [:append])
    File.chmod!(file.path, 0o444)

    assert {:error, {:repair_failed, :eacces}} = Session.File.resume(dir, "/repo")
    File.chmod!(file.path, 0o644)
  end

  test "a model that is missing or not a string is rejected", %{tmp_dir: dir} do
    {:ok, file} = Session.File.create(dir, "sess1", "/repo", "test/ok")
    append_raw(file, ~s({"id":"x","type":"model_change","model":42}))

    assert {:error, {:invalid_file, _}} = Session.File.resume(dir, "/repo")

    {:ok, file2} = Session.File.create(dir, "sess2", "/repo2", "test/ok")
    append_raw(file2, ~s({"id":"x","type":"model_change"}))

    assert {:error, {:invalid_file, _}} = Session.File.resume(dir, "/repo2")

    # A later valid change does not launder a bad one mid-file.
    {:ok, file3} = Session.File.create(dir, "sess3", "/repo3", "test/ok")

    file3
    |> append_raw(~s({"id":"x","type":"model_change","model":42}))
    |> Session.File.append_model_change("test/other")

    assert {:error, {:invalid_file, _}} = Session.File.resume(dir, "/repo3")

    # Nor a bad header model.
    {:ok, file4} = Session.File.create(dir, "sess4", "/repo4", "test/ok")
    header = File.read!(file4.path)
    File.write!(file4.path, String.replace(header, ~s("model":"test/ok"), ~s("model":42)))
    Session.File.append_model_change(file4, "test/other")

    assert {:error, {:invalid_file, _}} = Session.File.resume(dir, "/repo4")
  end

  test "resume decodes stop reasons in a VM that never interned their atoms", %{tmp_dir: dir} do
    {:ok, file} = Session.File.create(dir, "sess1", "/repo", "test/ok")

    Session.File.append_message(file, %Message{
      role: :assistant,
      stop_reason: :max_tokens,
      content: [%Message.Text{text: "t"}]
    })

    script = """
    {:ok, resumed} = Helyx.Session.File.resume(#{inspect(dir)}, "/repo")
    [%{stop_reason: :max_tokens}] = resumed.messages
    IO.puts("resumed ok")
    """

    ebin = Path.join(Mix.Project.build_path(), "lib/helyx/ebin")
    assert {out, 0} = System.cmd("elixir", ["-pa", ebin, "-e", script])
    assert out =~ "resumed ok"
  end

  test "a stop reason outside the format's set is never written", %{tmp_dir: dir} do
    {:ok, file} = Session.File.create(dir, "sess1", "/repo", "test/ok")
    before = File.read!(file.path)

    assert_raise FunctionClauseError, fn ->
      Session.File.append_message(file, %Message{
        role: :assistant,
        stop_reason: :aborted,
        content: []
      })
    end

    assert File.read!(file.path) == before
  end

  test "resume caps an integer over the digit limit in tool call arguments and usage", %{
    tmp_dir: dir
  } do
    call = fn n -> %Message.ToolCall{id: "c1", name: "read", arguments: %{"offset" => [n]}} end

    message = fn n ->
      %Message{role: :assistant, content: [call.(n)], stop_reason: :tool_use, usage: %{"in" => n}}
    end

    {:ok, file} = Session.File.create(dir, "sess1", "/repo", "test/ok")
    file = Session.File.append_message(file, message.(10 ** 100))
    Session.File.append_message(file, message.(10 ** 100 - 1))

    assert {:ok, resumed} = Session.File.resume(dir, "/repo")

    assert [["integer of more than 100 digits removed"], [10 ** 100 - 1]] ==
             for(%Message{content: [block]} <- resumed.messages, do: block.arguments["offset"])

    assert ["integer of more than 100 digits removed", 10 ** 100 - 1] ==
             for(%Message{usage: usage} <- resumed.messages, do: usage["in"])
  end

  test "a tool call id with a wrong type is rejected", %{tmp_dir: dir} do
    entry = ~s({"id":"x","type":"message","role":"tool_result","tool_call_id":42,"content":[]})
    {:ok, file} = Session.File.create(dir, "sess1", "/repo", "test/ok")
    append_raw(file, entry)

    assert {:error, {:invalid_file, _}} = Session.File.resume(dir, "/repo")
  end

  test "a bad usage, model, or stop reason decodes as a missing one", %{tmp_dir: dir} do
    {:ok, file} = Session.File.create(dir, "sess1", "/repo", "test/ok")

    entries = [
      ~s({"id":"a","type":"message","role":"assistant","stop_reason":"banana","content":[]}),
      ~s({"id":"b","type":"message","role":"assistant","stop_reason":false,"content":[]}),
      ~s({"id":"c","type":"message","role":"assistant","model":42,"usage":[1],"content":[]}),
      ~s({"id":"d","type":"message","role":"assistant","usage":"x","stop_reason":{},"content":[]})
    ]

    Enum.reduce(entries, file, &append_raw(&2, &1))

    assert {:ok, resumed} = Session.File.resume(dir, "/repo")
    assert length(resumed.messages) == 4

    for message <- resumed.messages do
      assert %Message{role: :assistant, model: nil, stop_reason: nil, usage: usage} = message
      assert usage == %{}
    end
  end

  test "a content block with a wrong field type is rejected", %{tmp_dir: dir} do
    entry = ~s({"id":"x","type":"message","role":"user","content":[{"type":"text","text":42}]})
    {:ok, file} = Session.File.create(dir, "sess1", "/repo", "test/ok")
    append_raw(file, entry)

    assert {:error, {:invalid_file, _}} = Session.File.resume(dir, "/repo")
  end

  test "an entry type the writer never produces is rejected", %{tmp_dir: dir} do
    {:ok, file} = Session.File.create(dir, "sess1", "/repo", "test/ok")
    append_raw(file, ~s({"id":"x","type":"note"}))

    assert {:error, {:invalid_file, _}} = Session.File.resume(dir, "/repo")
  end

  test "an entry on no branch is not checked", %{tmp_dir: dir} do
    {:ok, file} = Session.File.create(dir, "sess1", "/repo", "test/ok")
    file = Session.File.append_message(file, Message.user("kept"))

    for line <- [
          ~s({"id":"n","parent_id":"gone","type":"note"}),
          ~s({"id":"m","parent_id":"gone","type":"model_change","model":42}),
          ~s({"id":"r","parent_id":"gone","type":"message","role":"system","content":[]})
        ] do
      File.write!(file.path, line <> "\n", [:append])
    end

    assert {:ok, resumed} = Session.File.resume(dir, "/repo")
    assert texts(resumed) == ["kept"]
    assert resumed.model == "test/ok"
  end

  test "a second header mid-file is rejected", %{tmp_dir: dir} do
    {:ok, file} = Session.File.create(dir, "sess1", "/repo", "test/ok")
    append_raw(file, ~s({"id":"h2","type":"session","version":1,"cwd":"/repo","model":"test/ok"}))

    assert {:error, {:invalid_file, _}} = Session.File.resume(dir, "/repo")
  end

  describe "the file size limit" do
    test "a file at the limit resumes; one byte over is rejected and not mutated",
         %{tmp_dir: dir} do
      {:ok, file} = Session.File.create(dir, "sess1", "/repo", "test/ok")
      # Multibyte content: the limit counts bytes, not characters.
      Session.File.append_message(file, Message.user("héllo wörld"))
      size = File.stat!(file.path).size

      assert {:ok, _} = Session.File.resume(dir, "/repo", max_bytes: size + 1)
      assert {:ok, resumed} = Session.File.resume(dir, "/repo", max_bytes: size)
      assert [%Message{role: :user}] = resumed.messages

      # One byte over. A torn tail would be repaired on an accepted file;
      # here it must stay.
      File.write!(file.path, "{", [:append])
      before = File.read!(file.path)

      assert {:error, {:too_large, text}} = Session.File.resume(dir, "/repo", max_bytes: size)
      assert text =~ "#{size}-byte limit"
      assert text =~ "start a new session"
      assert File.read!(file.path) == before
    end

    test "a last entry without its newline counts with the newline", %{tmp_dir: dir} do
      {:ok, file} = Session.File.create(dir, "sess1", "/repo", "test/ok")
      header = String.trim_trailing(File.read!(file.path), "\n")
      File.write!(file.path, header)

      assert {:error, {:too_large, _}} =
               Session.File.resume(dir, "/repo", max_bytes: byte_size(header))

      assert File.read!(file.path) == header

      assert {:ok, _} = Session.File.resume(dir, "/repo", max_bytes: byte_size(header) + 1)
      assert {:ok, _} = Session.File.resume(dir, "/repo", max_bytes: byte_size(header) + 1)
    end

    test "the default limit is 64 MiB", %{tmp_dir: dir} do
      {:ok, file} = Session.File.create(dir, "sess1", "/repo", "test/ok")
      # A sparse file: 64 MiB + 1 byte of size, no data blocks written.
      File.open!(file.path, [:read, :write, :binary], fn io ->
        {:ok, _} = :file.position(io, 64 * 1024 * 1024)
        :ok = IO.binwrite(io, "\n")
      end)

      assert {:error, {:too_large, text}} = Session.File.resume(dir, "/repo")
      assert text =~ "67108864-byte limit"
    end
  end

  @tag :slow
  test "a file of many short lines is not split into a list of all of them", %{tmp_dir: dir} do
    {:ok, file} = Session.File.create(dir, "sess1", "/repo", "test/ok")
    File.write!(file.path, String.duplicate("\n", 4 * 1024 * 1024), [:append])

    # 4 MiB of empty lines as a list is over 100 MiB of heap. The file
    # binary itself is off-heap. The process dies if its heap passes 16 MiB.
    {pid, ref} =
      spawn_monitor(fn ->
        Process.flag(:max_heap_size, %{size: div(16 * 1024 * 1024, 8), kill: true})
        exit({:result, Session.File.resume(dir, "/repo")})
      end)

    assert_receive {:DOWN, ^ref, :process, ^pid, {:result, {:ok, resumed}}}
    assert resumed.messages == []
  end

  describe "the heap cap of the decode" do
    test "a file whose decode passes the cap is rejected and not mutated", %{tmp_dir: dir} do
      {:ok, file} = Session.File.create(dir, "sess1", "/repo", "test/ok")
      Session.File.append_message(file, Message.user("hi"))
      assert {:ok, _} = Session.File.resume(dir, "/repo", max_heap_bytes: 16 * 1024 * 1024)

      # 1 MiB of `[` with a torn last line: the decode of deep nesting takes
      # tens of bytes of heap per file byte. The torn tail would be repaired
      # on an accepted file; here it must stay.
      File.write!(file.path, String.duplicate("[", 1024 * 1024), [:append])
      before = File.read!(file.path)

      assert {:error, {:too_large, text}} =
               Session.File.resume(dir, "/repo", max_heap_bytes: 16 * 1024 * 1024)

      assert text =~ "#{16 * 1024 * 1024} bytes of memory"
      assert text =~ "start a new session"
      assert File.read!(file.path) == before
    end

    @tag :slow
    test "a text-heavy session near the file limit fits the default cap", %{tmp_dir: dir} do
      {:ok, file} = Session.File.create(dir, "sess1", "/repo", "test/ok")

      file =
        Session.File.append_message(
          file,
          Message.user(String.duplicate("line of output\n", 4000))
        )

      [_header, line] = String.split(File.read!(file.path), "\n", trim: true)
      count = div(63 * 1024 * 1024, byte_size(line) + 1)
      entry = JSON.decode!(line)

      # Each copy has its own id and hangs below the one before it.
      copies =
        for n <- 1..(count - 1)//1 do
          parent = if n == 1, do: file.leaf, else: "m#{n - 1}"
          [JSON.encode!(%{entry | "id" => "m#{n}", "parent_id" => parent}), "\n"]
        end

      File.write!(file.path, copies, [:append])

      assert {:ok, resumed} = Session.File.resume(dir, "/repo")
      assert length(resumed.messages) == count
    end

    test "the caller's heap does not hold the decode", %{tmp_dir: dir} do
      {:ok, file} = Session.File.create(dir, "sess1", "/repo", "test/ok")
      File.write!(file.path, String.duplicate("[", 1024 * 1024) <> "\n", [:append])

      # The caller dies if its heap passes 16 MiB; the decode alone needs more.
      {pid, ref} =
        spawn_monitor(fn ->
          Process.flag(:max_heap_size, %{size: div(16 * 1024 * 1024, 8), kill: true})
          exit({:result, Session.File.resume(dir, "/repo")})
        end)

      assert_receive {:DOWN, ^ref, :process, ^pid, {:result, result}}
      assert {:ok, %{messages: []}} = result
    end
  end

  test "a limit that is not a positive integer raises; the file is not blamed", %{tmp_dir: dir} do
    {:ok, _file} = Session.File.create(dir, "sess1", "/repo", "test/ok")

    for bad <- [0, -1, 1.5, nil, 64 * 1024 * 1024 + 1] do
      assert_raise FunctionClauseError, fn ->
        Session.File.resume(dir, "/repo", max_bytes: bad)
      end
    end

    for bad <- [0, -1, 1.5, nil, 8, 1024 * 1024 - 1, 1024 * 1024 * 1024 + 1] do
      assert_raise FunctionClauseError, fn ->
        Session.File.resume(dir, "/repo", max_heap_bytes: bad)
      end
    end

    for good <- [1024 * 1024, 1024 * 1024 * 1024] do
      assert {:ok, _} = Session.File.resume(dir, "/repo", max_heap_bytes: good)
    end

    for bad <- [0, -1, 1.5, nil, 257] do
      assert_raise FunctionClauseError, fn ->
        Session.File.resume(dir, "/repo", max_scanned_files: bad)
      end
    end
  end

  describe "the header scan" do
    # The header line of a session whose model pads the line to `bytes`.
    defp header_of(bytes, pad) do
      base = ~s({"type":"session","version":1,"cwd":"/repo","id":"h","ts":"t","model":")
      count = div(bytes - byte_size(base) - 2, byte_size(pad))
      line = base <> String.duplicate(pad, count) <> ~s("})
      line <> String.duplicate(" ", bytes - byte_size(line))
    end

    defp overwrite_session(dir, header) do
      {:ok, file} = Session.File.create(dir, "sess1", "/repo", "test/ok")
      File.write!(file.path, header <> "\n")
    end

    test "a header line of 65,536 bytes is found, also with multibyte text", %{tmp_dir: dir} do
      overwrite_session(dir, header_of(65_536, "é"))
      assert {:ok, _} = Session.File.resume(dir, "/repo")

      overwrite_session(dir, header_of(65_535, "a"))
      assert {:ok, _} = Session.File.resume(dir, "/repo")
    end

    test "a header line one byte over is not a session", %{tmp_dir: dir} do
      overwrite_session(dir, header_of(65_537, "a"))
      assert {:error, :not_found} = Session.File.resume(dir, "/repo")
    end

    test "a file that is not regular is skipped, not opened", %{tmp_dir: dir} do
      {:ok, file} = Session.File.create(dir, "sess1", "/repo", "test/ok")
      {_, 0} = System.cmd("mkfifo", [Path.join(Path.dirname(file.path), "pipe.jsonl")])

      assert {:ok, resumed} = Session.File.resume(dir, "/repo")
      assert resumed.session_id == "sess1"
    end
  end

  describe "the file count of the header scan" do
    # "_repo" has the slug of "/repo", so its sessions share the directory.
    defp session_at(dir, id, cwd, mtime) do
      {:ok, file} = Session.File.create(dir, id, cwd, "test/ok")
      File.touch!(file.path, mtime)
      file
    end

    test "a session older than the newest files is not found", %{tmp_dir: dir} do
      session_at(dir, "old", "/repo", 1_000)
      session_at(dir, "b", "_repo", 2_000)
      session_at(dir, "c", "_repo", 3_000)

      assert {:error, :not_found} = Session.File.resume(dir, "/repo", max_scanned_files: 2)
      assert {:ok, resumed} = Session.File.resume(dir, "/repo", max_scanned_files: 3)
      assert resumed.session_id == "old"
    end

    test "the modification time selects the files, then the start time decides",
         %{tmp_dir: dir} do
      # The sleeps put the start times of the headers in order.
      session_at(dir, "first", "/repo", 3_000)
      Process.sleep(2)
      session_at(dir, "second", "/repo", 1_000)
      Process.sleep(2)
      session_at(dir, "third", "/repo", 2_000)

      assert {:ok, %{session_id: "first"}} =
               Session.File.resume(dir, "/repo", max_scanned_files: 1)

      assert {:ok, %{session_id: "third"}} = Session.File.resume(dir, "/repo")
    end

    test "a file that is not regular does not count", %{tmp_dir: dir} do
      file = session_at(dir, "sess1", "/repo", 1_000)
      {_, 0} = System.cmd("mkfifo", [Path.join(Path.dirname(file.path), "pipe.jsonl")])

      assert {:ok, %{session_id: "sess1"}} =
               Session.File.resume(dir, "/repo", max_scanned_files: 1)
    end

    test "the default limit is 256 files", %{tmp_dir: dir} do
      session_at(dir, "old", "/repo", 1_000)
      for n <- 1..255, do: session_at(dir, "s#{n}", "_repo", 2_000 + n)
      assert {:ok, %{session_id: "old"}} = Session.File.resume(dir, "/repo")

      session_at(dir, "s256", "_repo", 3_000)
      assert {:error, :not_found} = Session.File.resume(dir, "/repo")
    end

    test "the path breaks a tie of the modification time", %{tmp_dir: dir} do
      session_at(dir, "a", "/repo", 1_000)
      session_at(dir, "b", "_repo", 1_000)

      assert {:error, :not_found} = Session.File.resume(dir, "/repo", max_scanned_files: 1)
      assert {:ok, %{session_id: "b"}} = Session.File.resume(dir, "_repo", max_scanned_files: 1)
    end
  end
end
