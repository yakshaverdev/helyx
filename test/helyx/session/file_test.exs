defmodule Helyx.Session.FileTest do
  use ExUnit.Case, async: true

  alias Helyx.{Message, Session}
  alias Helyx.Test.SessionFile

  @moduletag :tmp_dir

  # Appends a hand-written entry as the child of the leaf of `file`, so it
  # continues the chain that a resume reads, and moves the leaf to it.
  defp append_raw(file, json) do
    entry = Map.put(JSON.decode!(json), "parent_id", file.leaf)
    File.write!(file.path, JSON.encode!(entry) <> "\n", [:append])
    %{file | leaf: entry["id"]}
  end

  defp id(resumed), do: Path.basename(resumed.file.path, ".jsonl")

  defp texts(resumed), do: Enum.map(resumed.messages, &Message.text/1)

  # A session with a first prompt. The resume of the newest session leaves
  # out a session with a header and no message, and a file whose name is not
  # a session id: the literal ids here are padded to its 12 characters.
  defp started(dir, id, cwd, model) do
    {:ok, file} = Session.File.create(dir, id, cwd, model)
    {:ok, SessionFile.append_message(file, Message.user("start"))}
  end

  test "create writes a header, and the newest-session resume skips a session with no message",
       %{tmp_dir: dir} do
    {:ok, older} = started(dir, "older0000000", "/repo", "test/ok")
    {:ok, file} = Session.File.create(dir, "sess00000001", "/repo", "test/ok")
    # A model change is no message.
    Session.File.append_model_change(file, "test/other")

    assert {:ok, resumed} = SessionFile.resume(dir, "/repo")
    assert id(resumed) == "older0000000"
    assert resumed.file.path == older.path

    File.rm!(older.path)
    assert {:error, :not_found} = SessionFile.resume(dir, "/repo")

    # The skip writes nothing.
    assert [_header, _model_change] = String.split(File.read!(file.path), "\n", trim: true)
  end

  test "resume with no session for the directory", %{tmp_dir: dir} do
    assert {:error, :not_found} = SessionFile.resume(dir, "/repo")
  end

  test "messages round-trip through the file", %{tmp_dir: dir} do
    call = %Message.ToolCall{id: "c1", name: "bash", arguments: %{"command" => "ls"}}

    assistant = %Message{
      role: :assistant,
      model: "test/ok",
      stop_reason: :tool_use,
      usage: %Helyx.Usage{
        input: 12,
        output: 3,
        cache_read: 40,
        cache_write: 5,
        cost: 0.0125,
        cost_kind: :list,
        context_tokens: 60,
        context_window: 200_000
      },
      content: [
        %Message.Thinking{thinking: "hmm"},
        %Message.Text{text: "Listing."},
        call
      ]
    }

    result = %Message{
      role: :tool_result,
      tool_call_id: "c1",
      tool_name: "bash",
      is_error: true,
      content: [%Message.Text{text: "no such directory"}]
    }

    # The unknown usage and a nil usage are two values, and both stay.
    unknown = %Message{role: :assistant, content: [], usage: %Helyx.Usage{}}
    billed = %{unknown | usage: %Helyx.Usage{output: 1, cost: 2, cost_kind: :billed}}
    none = %Message{role: :assistant, content: [%Message.Text{text: "cut"}]}

    # Each origin kind of a new user message round-trips with its id.
    users =
      for origin <- [
            %{kind: :user, id: nil},
            %{kind: :background, id: "run000000001"},
            %{kind: :product, id: "job 7 · run 1"}
          ],
          do: Message.user("List the tests.", origin)

    messages =
      Enum.map([assistant, result, unknown, billed, none], &%{&1 | id: Session.Id.new()})

    messages = users ++ messages

    {:ok, file} = Session.File.create(dir, "sess00000001", "/repo", "test/ok")
    Enum.reduce(messages, file, &SessionFile.append_message(&2, &1))

    assert {:ok, resumed} = SessionFile.resume(dir, "/repo")
    assert resumed.messages == messages
  end

  describe "message ids and origins (#649)" do
    @assistant %{"role" => "assistant"}
    @tool_result %{"role" => "tool_result", "tool_call_id" => "c1", "tool_name" => "bash"}

    test "a message with no id does not encode: the session sets every id" do
      assert_raise FunctionClauseError, fn -> Session.File.Codec.encode(Message.user("hi")) end
    end

    defp user_entry(id, extra) do
      JSON.encode!(
        Map.merge(
          %{
            "id" => id,
            "type" => "message",
            "role" => "user",
            "content" => [%{"type" => "text", "text" => "hi"}]
          },
          extra
        )
      )
    end

    test "the entry id is the message id, and a user entry with no origin reads as :unknown",
         %{tmp_dir: dir} do
      {:ok, file} = Session.File.create(dir, "sess00000001", "/repo", "test/ok")
      append_raw(file, user_entry("message00001", %{}))

      assert {:ok, %{messages: [message]}} = SessionFile.resume(dir, "/repo")
      assert %Message{id: "message00001", origin: %{kind: :unknown, id: nil}} = message
    end

    test "a malformed origin, or an origin on another role, rejects the file", %{tmp_dir: dir} do
      bad = [
        %{"origin" => %{"kind" => "unknown"}},
        %{"origin" => %{"kind" => "admin", "id" => "x"}},
        %{"origin" => %{"kind" => "product"}},
        %{"origin" => %{"kind" => "product", "id" => ""}},
        %{"origin" => %{"kind" => "product", "id" => String.duplicate("a", 257)}},
        %{"origin" => %{"kind" => "background", "id" => 7}},
        %{"origin" => %{"kind" => "user", "id" => "x"}},
        %{"origin" => %{"kind" => "user", "extra" => 1}},
        %{"origin" => "user"},
        %{"origin" => nil},
        %{"origin" => %{"kind" => "user"}},
        # A valid origin on another role.
        Map.put(@assistant, "origin", %{"kind" => "user", "id" => nil}),
        Map.put(@tool_result, "origin", %{"kind" => "product", "id" => "p"})
      ]

      # The same roles with no origin resume.
      for {extra, n} <- Enum.with_index([@assistant, @tool_result]) do
        dir = Path.join(dir, "role#{n}")
        {:ok, file} = Session.File.create(dir, "sess00000001", "/repo", "test/ok")
        append_raw(file, user_entry("message00001", extra))
        assert {:ok, _resumed} = SessionFile.resume(dir, "/repo")
      end

      for {extra, n} <- Enum.with_index(bad) do
        dir = Path.join(dir, "case#{n}")
        {:ok, file} = Session.File.create(dir, "sess00000001", "/repo", "test/ok")
        append_raw(file, user_entry("message00001", extra))
        assert {:error, {:invalid_file, _text}} = SessionFile.resume(dir, "/repo"), inspect(extra)
      end

      # At the bound the origin id is kept: 256 bytes, multibyte too.
      for id <- [String.duplicate("a", 256), String.duplicate("é", 128)] do
        dir = Path.join(dir, "ok#{byte_size(id)}#{String.length(id)}")
        {:ok, file} = Session.File.create(dir, "sess00000001", "/repo", "test/ok")

        append_raw(
          file,
          user_entry("message00001", %{"origin" => %{"kind" => "product", "id" => id}})
        )

        assert {:ok, %{messages: [%Message{origin: %{kind: :product, id: ^id}}]}} =
                 SessionFile.resume(dir, "/repo")
      end
    end

    test "a message id that repeats an earlier one rejects the file", %{tmp_dir: dir} do
      {:ok, file} = Session.File.create(dir, "sess00000001", "/repo", "test/ok")

      file
      |> append_raw(user_entry("message00001", %{}))
      |> append_raw(user_entry("message00001", %{}))

      assert {:error, {:invalid_file, ~s(a message repeats the id "message00001")}} =
               SessionFile.resume(dir, "/repo")
    end

    # An id that `Id.new/0` never makes could hold `:`, the separator of the
    # derived ids of repair results.
    test "a message id that Id.new/0 never makes rejects the file", %{tmp_dir: dir} do
      for {id, n} <- Enum.with_index(["AAAAAAAAAA:0", "m1", ""]) do
        dir = Path.join(dir, "case#{n}")
        {:ok, file} = Session.File.create(dir, "sess00000001", "/repo", "test/ok")
        append_raw(file, user_entry(id, %{}))

        assert {:error, {:invalid_file, "a message id is not valid: " <> _}} =
                 SessionFile.resume(dir, "/repo"),
               inspect(id)
      end
    end

    # docs/features/summary-compaction.md: a summary keeps a user or
    # assistant message before it, with a text of at most 65,536 bytes.
    test "a summary entry resumes, and one out of its bounds rejects the file",
         %{tmp_dir: dir} do
      summary = fn extra ->
        JSON.encode!(
          Map.merge(
            %{
              "id" => "summary00001",
              "type" => "summary",
              "summary" => "s",
              "first_kept_id" => "message00001",
              "tokens_before" => 1
            },
            extra
          )
        )
      end

      cases = [
        {%{}, :ok},
        {%{"summary" => String.duplicate("é", 32_768)}, :ok},
        {%{"summary" => String.duplicate("x", 65_537)}, :error},
        {%{"first_kept_id" => "summary00001"}, :error},
        {%{"first_kept_id" => "message00002"}, :error},
        {%{"tokens_before" => 0}, :ok},
        {%{"tokens_before" => 1_000_000_000}, :ok},
        {%{"tokens_before" => -1}, :error},
        {%{"tokens_before" => 1_000_000_001}, :error},
        {%{"summary" => nil}, :error},
        {%{"summary" => ""}, :error}
      ]

      for {{extra, expected}, n} <- Enum.with_index(cases) do
        dir = Path.join(dir, "case#{n}")
        {:ok, file} = Session.File.create(dir, "sess00000001", "/repo", "test/ok")

        file
        |> append_raw(user_entry("message00001", %{}))
        |> append_raw(user_entry("message00002", @tool_result))
        |> append_raw(summary.(extra))

        case expected do
          :ok ->
            assert {:ok, %{summary: %Helyx.Summary{first_kept_id: "message00001"}}} =
                     SessionFile.resume(dir, "/repo")

          :error ->
            assert {:error, {:invalid_file, "a summary entry is not valid"}} =
                     SessionFile.resume(dir, "/repo"),
                   inspect(Map.keys(extra))
        end
      end

      # The last entry wins, and a kept id must come before its entry.
      for {{entries, expected}, n} <-
            Enum.with_index([
              {[summary.(%{}), summary.(%{"id" => "summary00002", "summary" => "t"})], :ok},
              {[summary.(%{"first_kept_id" => "message00003"}), user_entry("message00003", %{})],
               :error}
            ]) do
        dir = Path.join(dir, "order#{n}")
        {:ok, file} = Session.File.create(dir, "sess00000001", "/repo", "test/ok")
        file = append_raw(file, user_entry("message00001", %{}))
        Enum.reduce(entries, file, &append_raw(&2, &1))

        case expected do
          :ok ->
            assert {:ok, %{summary: %Helyx.Summary{text: "t"}}} = SessionFile.resume(dir, "/repo")

          :error ->
            assert {:error, {:invalid_file, _}} = SessionFile.resume(dir, "/repo")
        end
      end
    end

    # #712: the last compaction or summary entry gives the message id that
    # it names and its tokens after; a count out of 0..10^9 reads as nil.
    test "the last compaction or summary names its message and its tokens after",
         %{tmp_dir: dir} do
      entry = fn type, extra ->
        fields =
          if type == "summary",
            do: %{"summary" => "s", "first_kept_id" => "message00001", "tokens_before" => 1},
            else: %{"provider" => "conn", "trigger" => "auto", "tokens_before" => 1}

        id = "entry#{System.unique_integer([:positive])}"

        %{"id" => id, "type" => type, "last_id" => "message00001"}
        |> Map.merge(fields)
        |> Map.merge(extra)
        |> JSON.encode!()
      end

      cases = [
        {[entry.("compaction", %{"tokens_after" => 1_000_000_000})],
         {"message00001", 1_000_000_000}},
        {[entry.("compaction", %{"tokens_after" => 1_000_000_001})], {"message00001", nil}},
        {[entry.("compaction", %{"tokens_after" => -1})], {"message00001", nil}},
        {[entry.("compaction", %{"tokens_after" => 4, "last_id" => nil})], nil},
        # An entry from before #712 names no message: the one before it.
        {[
           ~s({"id":"old00001","type":"compaction","provider":"conn","trigger":"auto","tokens_after":4})
         ], {"message00001", 4}},
        {[entry.("compaction", %{"tokens_after" => 4}), entry.("summary", %{})],
         {"message00001", nil}},
        {[entry.("summary", %{}), entry.("compaction", %{"tokens_after" => 4})],
         {"message00001", 4}}
      ]

      for {{entries, expected}, n} <- Enum.with_index(cases) do
        dir = Path.join(dir, "case#{n}")
        {:ok, file} = Session.File.create(dir, "sess00000001", "/repo", "test/ok")
        file = append_raw(file, user_entry("message00001", %{}))
        Enum.reduce(entries, file, &append_raw(&2, &1))
        assert {:ok, %{compacted: ^expected}} = SessionFile.resume(dir, "/repo")
      end
    end
  end

  test "a tool result text over the limit is cut on resume", %{tmp_dir: dir} do
    {:ok, file} = Session.File.create(dir, "sess00000001", "/repo", "test/ok")
    big = String.duplicate("x", 100_000)

    append_raw(
      file,
      JSON.encode!(%{
        "id" => "toolresult01",
        "type" => "message",
        "role" => "tool_result",
        "tool_call_id" => "c1",
        "tool_name" => "bash",
        "is_error" => false,
        "content" => [%{"type" => "text", "text" => big}]
      })
    )

    assert {:ok, resumed} = SessionFile.resume(dir, "/repo")
    assert [text] = texts(resumed)
    assert byte_size(text) <= 65_536

    assert text =~
             ~r/^\[cut to \d+ of 100000 bytes, start and end kept\]\nx+\n\[… cut …\]\nx+$/
  end

  test "a model change entry is written and restored", %{tmp_dir: dir} do
    {:ok, file} = started(dir, "sess00000001", "/repo", "test/ok")
    Session.File.append_model_change(file, "test/other")

    assert {:ok, resumed} = SessionFile.resume(dir, "/repo")
    assert resumed.model == "test/other"
  end

  test "resume id entries are written, and the last one per provider is restored with the assistant messages before it",
       %{tmp_dir: dir} do
    {:ok, file} = started(dir, "sess00000001", "/repo", "claude-code/opus")
    assert {:ok, %{resume_ids: sessions}} = SessionFile.resume(dir, "/repo")
    assert sessions == %{}

    call = %Message.ToolCall{id: "c1", name: "read", arguments: %{}}

    file
    |> Session.File.append_resume_id("claude-code", "first")
    |> Session.File.append_resume_id("codex", "codex-1")
    |> SessionFile.append_message(%Message{role: :assistant, content: [call]})
    |> SessionFile.append_message(Message.tool_result(call, {:ok, "done"}))
    |> Session.File.append_resume_id("claude-code", "sécond")

    assert {:ok, resumed} = SessionFile.resume(dir, "/repo")

    assert resumed.resume_ids == %{
             "claude-code" => {"sécond", 1, nil},
             "codex" => {"codex-1", 0, nil}
           }

    # The entry has the shape the feature doc gives, and it moves the leaf.
    entries =
      file.path |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&JSON.decode!/1)

    assert [_header, user, first, _codex, _assistant, _result, last] = entries

    assert %{
             "type" => "harness_session",
             "provider" => "claude-code",
             "harness_session_id" => "first",
             "parent_id" => parent,
             "ts" => _
           } = first

    assert parent == user["id"]
    assert resumed.file.leaf == last["id"]
  end

  test "an entry stored as harness_session by an older writer still resumes", %{tmp_dir: dir} do
    # The literal line pins the stored names that session files on disk hold.
    {:ok, file} = started(dir, "old000000000", "/old", "claude-code/opus")

    append_raw(
      file,
      ~s({"id":"h","type":"harness_session","provider":"claude-code","harness_session_id":"h1"})
    )

    assert {:ok, %{resume_ids: %{"claude-code" => {"h1", 0, nil}}}} =
             SessionFile.resume(dir, "/old")
  end

  test "a resume id entry with a bad id removes the label of its provider",
       %{tmp_dir: dir} do
    bad = [
      ~s({"id":"x","type":"harness_session","provider":"claude-code"}),
      ~s({"id":"x","type":"harness_session","provider":"claude-code","harness_session_id":null}),
      # The id is 1 to 256 bytes; 257 bytes, multibyte, and empty are bad.
      ~s({"id":"x","type":"harness_session","provider":"claude-code","harness_session_id":"a#{String.duplicate("é", 128)}"}),
      ~s({"id":"x","type":"harness_session","provider":"claude-code","harness_session_id":""})
    ]

    for {line, n} <- Enum.with_index(bad) do
      {:ok, file} = started(dir, Session.Id.new(), "/repo#{n}", "test/ok")

      file
      |> Session.File.append_resume_id("claude-code", "stale")
      |> Session.File.append_resume_id("codex", "codex-1")
      |> append_raw(line)

      # The stale label does not come back; the other provider keeps its own.
      assert {:ok, %{resume_ids: sessions}} = SessionFile.resume(dir, "/repo#{n}")
      assert sessions == %{"codex" => {"codex-1", 0, nil}}
    end
  end

  test "a resume id entry with no usable provider removes every label",
       %{tmp_dir: dir} do
    bad = [
      ~s({"id":"x","type":"harness_session","harness_session_id":"a"}),
      ~s({"id":"x","type":"harness_session","provider":1,"harness_session_id":"a"})
    ]

    for {line, n} <- Enum.with_index(bad) do
      {:ok, file} = Session.File.create(dir, Session.Id.new(), "/repo#{n}", "claude-code/opus")

      file
      |> Session.File.append_resume_id("claude-code", "old")
      |> Session.File.append_resume_id("codex", "codex-1")
      |> append_raw(line)
      |> SessionFile.append_message(%Message{
        role: :assistant,
        model: "claude-code/opus",
        content: [%Message.Text{text: "t"}]
      })

      # The reader cannot know which label the damaged entry replaced, so
      # the later message of the old provider does not resume the old label.
      assert {:ok, resumed} = SessionFile.resume(dir, "/repo#{n}")
      assert resumed.resume_ids == %{}
      assert [%Message{role: :assistant}] = resumed.messages

      assert Helyx.Session.Transcript.resumable(
               resumed.messages,
               resumed.resume_ids,
               "claude-code"
             ) == nil
    end
  end

  test "a valid resume id entry after one with no provider sets a label",
       %{tmp_dir: dir} do
    {:ok, file} = started(dir, "later0000000", "/later", "test/ok")
    line = ~s({"id":"x","type":"harness_session","harness_session_id":"a"})

    file
    |> append_raw(line)
    |> Session.File.append_resume_id("claude-code", "good")

    assert {:ok, %{resume_ids: %{"claude-code" => {"good", 0, nil}}}} =
             SessionFile.resume(dir, "/later")
  end

  test "a resume id of 256 bytes is kept", %{tmp_dir: dir} do
    # 256 bytes, multibyte, is the longest id kept; 255 bytes is kept too.
    for id <- [String.duplicate("é", 128), "a" <> String.duplicate("é", 127)] do
      cwd = "/long#{byte_size(id)}"
      {:ok, file} = started(dir, Session.Id.new(), cwd, "test/ok")
      Session.File.append_resume_id(file, "claude-code", id)

      assert {:ok, %{resume_ids: %{"claude-code" => {^id, 0, nil}}}} =
               SessionFile.resume(dir, cwd)
    end
  end

  # The newest-session resume skips such a file (`scan_test.exs`).
  test "resume by id rejects a header with an unknown or missing version", %{tmp_dir: dir} do
    {:ok, file} = started(dir, "sess00000001", "/repo", "test/ok")
    header = File.read!(file.path)

    File.write!(file.path, String.replace(header, ~s("version":1), ~s("version":99)))

    assert {:error, {:unknown_version, 99}} =
             SessionFile.resume(dir, "/repo", id: "sess00000001")

    File.write!(file.path, String.replace(header, ~s("version"), ~s("gone")))

    assert {:error, {:unknown_version, nil}} =
             SessionFile.resume(dir, "/repo", id: "sess00000001")
  end

  test "a torn last line is skipped, kept in the file, and the next entry starts a new line",
       %{tmp_dir: dir} do
    {:ok, file} = Session.File.create(dir, "sess00000001", "/repo", "test/ok")
    file = SessionFile.append_message(file, Helyx.Message.user("kept"))
    torn = ~s({"id":"x","type":"mess)
    File.write!(file.path, torn, [:append])
    before = File.read!(file.path)

    assert {:ok, resumed} = SessionFile.resume(dir, "/repo")
    assert [%Message{role: :user}] = resumed.messages
    assert resumed.file.leaf == file.leaf

    SessionFile.append_message(resumed.file, Message.user("after"))
    after_append = File.read!(file.path)
    assert String.starts_with?(after_append, before <> "\n")
    [_header, _kept, ^torn, next] = String.split(after_append, "\n", trim: true)
    assert JSON.decode!(next)["parent_id"] == file.leaf

    assert {:ok, repaired} = SessionFile.resume(dir, "/repo")
    assert texts(repaired) == ["kept", "after"]
    assert File.read!(file.path) == after_append
  end

  test "a torn last line after multibyte content is skipped, and the next append resumes", %{
    tmp_dir: dir
  } do
    {:ok, file} = Session.File.create(dir, "sess00000001", "/repo", "test/ok")
    file = SessionFile.append_message(file, Message.user("héllo — ünïcode ✓"))
    File.write!(file.path, ~s({"torn), [:append])

    assert {:ok, resumed} = SessionFile.resume(dir, "/repo")

    SessionFile.append_message(resumed.file, Message.user("after"))
    assert {:ok, repaired} = SessionFile.resume(dir, "/repo")
    assert texts(repaired) == ["héllo — ünïcode ✓", "after"]
  end

  # The repair adds one result for each open call, so this bound is the bound
  # of one resumed group (#673).
  test "a message over the block limit of the live path rejects the file", %{tmp_dir: dir} do
    max = Session.Turn.max_message_blocks()

    assistant = fn blocks ->
      calls =
        for n <- 1..blocks,
            do: %{"type" => "tool_call", "id" => "c#{n}", "name" => "bash", "arguments" => %{}}

      user_entry("message00001", %{"role" => "assistant", "content" => calls})
    end

    {:ok, file} = started(Path.join(dir, "at"), "sess00000001", "/repo", "test/ok")
    append_raw(file, assistant.(max))
    assert {:ok, %{messages: messages}} = SessionFile.resume(Path.join(dir, "at"), "/repo")
    assert [_user, %Message{content: content} | results] = Session.Transcript.repair(messages)
    assert length(content) == max and length(results) == max

    # A user or tool result message over it is damage too: a live one has
    # one block.
    blocks = List.duplicate(%{"type" => "text", "text" => "x"}, max + 1)

    over = [
      assistant.(max + 1),
      user_entry("message00001", %{"content" => blocks}),
      user_entry("message00001", Map.put(@tool_result, "content", blocks))
    ]

    for {line, n} <- Enum.with_index(over) do
      dir = Path.join(dir, "over#{n}")
      {:ok, file} = started(dir, "sess00000001", "/repo", "test/ok")
      file |> append_raw(line) |> SessionFile.append_message(Message.user("after"))
      before = File.read!(file.path)

      assert {:error, {:invalid_file, text}} = SessionFile.resume(dir, "/repo")
      assert text == "a message has #{max + 1} content blocks, over the limit of #{max}"
      assert File.read!(file.path) == before
    end

    # A content that is not a list has no blocks to count: it keeps its
    # decode of before #673.
    {:ok, file} = started(Path.join(dir, "map"), "sess00000001", "/repo", "test/ok")
    keys = Map.new(1..(max + 1), &{"k#{&1}", 1})
    append_raw(file, user_entry("message00001", %{"content" => keys}))

    assert {:error, {:invalid_file, "no function clause matching in " <> _}} =
             SessionFile.resume(Path.join(dir, "map"), "/repo")
  end

  test "a rejected file is not repaired", %{tmp_dir: dir} do
    {:ok, file} = started(dir, "sess00000001", "/repo", "test/ok")
    append_raw(file, ~s({"id":"x","type":"note"}))
    File.write!(file.path, ~s({"torn), [:append])
    before = File.read!(file.path)

    assert {:error, {:invalid_file, _}} = SessionFile.resume(dir, "/repo")
    assert File.read!(file.path) == before
  end

  test "a complete last entry missing only its newline is repaired", %{tmp_dir: dir} do
    {:ok, file} = Session.File.create(dir, "sess00000001", "/repo", "test/ok")
    file = SessionFile.append_message(file, Message.user("kept"))
    File.write!(file.path, String.trim_trailing(File.read!(file.path), "\n"))

    assert {:ok, resumed} = SessionFile.resume(dir, "/repo")

    SessionFile.append_message(resumed.file, Message.user("after"))
    assert {:ok, repaired} = SessionFile.resume(dir, "/repo")
    assert Enum.map(repaired.messages, &Message.text/1) == ["kept", "after"]
  end

  test "resume picks the most recently started session for the directory", %{tmp_dir: dir} do
    {:ok, _} = started(dir, "older0000000", "/repo", "test/ok")
    {:ok, _} = started(dir, "newer0000000", "/repo", "test/ok")

    assert {:ok, resumed} = SessionFile.resume(dir, "/repo")
    assert id(resumed) == "newer0000000"
  end

  test "two directories with one slug do not cross", %{tmp_dir: dir} do
    {:ok, _} = started(dir, "sess00000001", "/repo/a-b", "test/ok")
    {:ok, _} = started(dir, "sess00000002", "/repo/a/b", "test/ok")

    assert {:ok, resumed} = SessionFile.resume(dir, "/repo/a-b")
    assert id(resumed) == "sess00000001"
  end

  for {name, line} <- [
        {"a message role", ~s({"id":"x","ts":"t","type":"message","role":"system","content":[]})},
        {"a model that is not a string", ~s({"id":"x","type":"model_change","model":42})},
        {"a model change with no model", ~s({"id":"x","type":"model_change"})},
        {"a tool call id with a wrong type",
         ~s({"id":"x","type":"message","role":"tool_result","tool_call_id":42,"content":[]})},
        {"a content block with a wrong field type",
         ~s({"id":"x","type":"message","role":"user","content":[{"type":"text","text":42}]})},
        {"an image block, removed in #634",
         ~s({"id":"x","type":"message","role":"user","content":[{"type":"image","mime_type":"image/png","data":"aGk="}]})},
        {"a thinking signature, removed in #634",
         ~s({"id":"x","type":"message","role":"assistant","content":[{"type":"thinking","thinking":"t","signature":"s"}]})},
        {"a compaction with no string provider", ~s({"id":"x","type":"compaction","provider":1})},
        {"an entry type", ~s({"id":"x","type":"note"})},
        {"a second header mid-file",
         ~s({"id":"h2","type":"session","version":1,"cwd":"/repo","model":"test/ok"})}
      ] do
    test "an entry with a shape this module never writes is rejected, not raised: #{name}",
         %{tmp_dir: dir} do
      {:ok, file} = started(dir, "sess00000001", "/repo", "test/ok")
      append_raw(file, unquote(line))

      assert {:error, {:invalid_file, _}} = SessionFile.resume(dir, "/repo")
    end
  end

  test "an unwritable directory is an error, not a raise", %{tmp_dir: dir} do
    not_a_dir = Path.join(dir, "flat")
    File.write!(not_a_dir, "")

    assert {:error, {:create_failed, _}} =
             Session.File.create(not_a_dir, "sess00000001", "/repo", "test/ok")
  end

  test "a long working directory path still gets a file", %{tmp_dir: dir} do
    cwd = "/" <> String.duplicate("deep/", 80)
    {:ok, _} = started(dir, "sess00000001", cwd, "test/ok")

    assert {:ok, resumed} = SessionFile.resume(dir, cwd)
    assert id(resumed) == "sess00000001"
  end

  test "a line mid-file that is not an entry is skipped and kept", %{tmp_dir: dir} do
    {:ok, file} = Session.File.create(dir, "sess00000001", "/repo", "test/ok")
    File.write!(file.path, "not json\n[1]\n\n{}\n", [:append])
    SessionFile.append_message(file, Message.user("kept"))
    before = File.read!(file.path)

    assert {:ok, resumed} = SessionFile.resume(dir, "/repo")
    assert texts(resumed) == ["kept"]
    assert File.read!(file.path) == before
  end

  test "a session file of one chain resumes in file order", %{tmp_dir: dir} do
    # Hand-written lines: each parent_id is the id of the line above.
    lines = [
      ~s({"id":"h","parent_id":null,"ts":"t","type":"session","version":1,"cwd":"/repo","model":"test/ok"}),
      ~s({"id":"message00001","parent_id":"h","ts":"t","type":"message","role":"user","content":[{"type":"text","text":"one"}]}),
      ~s({"id":"c","parent_id":"message00001","ts":"t","type":"model_change","model":"test/two"}),
      ~s({"id":"message00002","parent_id":"c","ts":"t","type":"message","role":"user","content":[{"type":"text","text":"two"}]})
    ]

    {:ok, file} = Session.File.create(dir, "old000000000", "/repo", "test/ok")
    File.write!(file.path, Enum.map_join(lines, &(&1 <> "\n")))

    assert {:ok, resumed} = SessionFile.resume(dir, "/repo")
    assert texts(resumed) == ["one", "two"]
    assert resumed.model == "test/two"
    assert resumed.file.leaf == "message00002"
  end

  test "an entry that does not continue the chain is rejected with its line, the file unchanged",
       %{tmp_dir: dir} do
    entry = fn id, parent ->
      ~s({"id":#{id},"parent_id":#{parent},"type":"message","role":"user","content":[]})
    end

    breaks = [
      # A second child of the header: the branch of a second writer.
      fn header, _leaf -> entry.(~s("b"), ~s("#{header}")) end,
      fn _header, _leaf -> entry.(~s("d"), ~s("gone")) end,
      fn _header, _leaf -> entry.(~s("n"), "null") end,
      fn _header, leaf -> entry.("42", ~s("#{leaf}")) end
    ]

    for {break, n} <- Enum.with_index(breaks) do
      {:ok, header} = Session.File.create(dir, Session.Id.new(), "/r#{n}", "test/ok")
      kept = SessionFile.append_message(header, Message.user("kept"))
      # A line that does not decode is skipped, and its line still counts.
      File.write!(kept.path, "not json\n" <> break.(header.leaf, kept.leaf) <> "\n", [:append])
      before = File.read!(kept.path)

      assert SessionFile.resume(dir, "/r#{n}") ==
               {:error,
                {:invalid_file, "line 4 does not continue the chain of the entry before it"}}

      assert File.read!(kept.path) == before
    end
  end

  # The file can change between the pick and the read under the lock.
  test "the read after the pick uses the header of its own read", %{tmp_dir: dir} do
    {:ok, _file} = started(dir, "sess00000001", "/repo", "test/ok")
    {:ok, path, "/repo"} = Session.File.pick(dir, "/repo", [])
    File.write!(path, String.replace(File.read!(path), ~s("test/ok"), ~s("test/new")))

    assert {:ok, %{model: "test/new"}} = Session.File.resume_picked(path, "/repo")

    File.write!(path, String.replace(File.read!(path), ~s("/repo"), ~s("/moved")))
    assert Session.File.resume_picked(path, "/repo") == {:error, :not_found}
  end

  test "a repair that cannot write is an environment error", %{tmp_dir: dir} do
    {:ok, file} = started(dir, "sess00000001", "/repo", "test/ok")
    File.write!(file.path, ~s({"torn), [:append])
    File.chmod!(file.path, 0o444)

    assert {:error, {:repair_failed, :eacces}} = SessionFile.resume(dir, "/repo")
    File.chmod!(file.path, 0o644)
  end

  test "a later valid model change does not launder a bad one, nor a bad header model",
       %{tmp_dir: dir} do
    {:ok, file} = started(dir, "sess00000001", "/repo", "test/ok")

    file
    |> append_raw(~s({"id":"x","type":"model_change","model":42}))
    |> Session.File.append_model_change("test/other")

    assert {:error, {:invalid_file, _}} = SessionFile.resume(dir, "/repo")

    # Nor a bad header model, in a resume by id: the newest-session resume
    # skips such a file.
    {:ok, file2} = started(dir, "sess00000002", "/repo2", "test/ok")
    header = File.read!(file2.path)
    File.write!(file2.path, String.replace(header, ~s("model":"test/ok"), ~s("model":42)))
    Session.File.append_model_change(file2, "test/other")

    assert {:error, {:invalid_file, _}} = SessionFile.resume(dir, "/repo2", id: "sess00000002")
  end

  test "resume decodes stop reasons in a VM that never interned their atoms", %{tmp_dir: dir} do
    {:ok, file} = Session.File.create(dir, "sess00000001", "/repo", "test/ok")

    for stop <- [:max_tokens, :refused], reduce: file do
      file ->
        SessionFile.append_message(file, %Message{
          role: :assistant,
          stop_reason: stop,
          content: [%Message.Text{text: "t"}]
        })
    end

    script = """
    {:ok, resumed} = Helyx.Test.SessionFile.resume(#{inspect(dir)}, "/repo")
    [%{stop_reason: :max_tokens}, %{stop_reason: :refused}] = resumed.messages
    IO.puts("resumed ok")
    """

    ebin = Path.join(Mix.Project.build_path(), "lib/helyx/ebin")
    assert {out, 0} = System.cmd("elixir", ["-pa", ebin, "-e", script])
    assert out =~ "resumed ok"
  end

  test "a stop reason outside the format's set is never written", %{tmp_dir: dir} do
    {:ok, file} = Session.File.create(dir, "sess00000001", "/repo", "test/ok")
    before = File.read!(file.path)

    assert_raise FunctionClauseError, fn ->
      SessionFile.append_message(file, %Message{
        role: :assistant,
        stop_reason: :stop_sequence,
        content: []
      })
    end

    assert File.read!(file.path) == before
  end

  test "resume caps an integer over the digit limit in tool call arguments", %{tmp_dir: dir} do
    call = fn n -> %Message.ToolCall{id: "c1", name: "read", arguments: %{"offset" => [n]}} end
    message = fn n -> %Message{role: :assistant, content: [call.(n)], stop_reason: :tool_use} end

    {:ok, file} = Session.File.create(dir, "sess00000001", "/repo", "test/ok")
    file = SessionFile.append_message(file, message.(10 ** 100))
    SessionFile.append_message(file, message.(10 ** 100 - 1))

    assert {:ok, resumed} = SessionFile.resume(dir, "/repo")

    assert [["integer of more than 100 digits removed"], [10 ** 100 - 1]] ==
             for(%Message{content: [block]} <- resumed.messages, do: block.arguments["offset"])
  end

  # The struct bound (`docs/features/usage-and-limits.md`, "Value
  # bounds"): at the bound the usage comes back, one over gives the unknown
  # usage, and the message stays.
  test "a usage from the file gets the struct bound", %{tmp_dir: dir} do
    tokens = %{"input" => 0, "output" => 0, "cache_read" => 0, "cache_write" => 0}

    cases = [
      {%{"input" => 10 ** 15}, %{"input" => 10 ** 15 + 1}},
      {%{"output" => 10 ** 15}, %{"output" => 10 ** 15 + 1}},
      {%{"cache_read" => 10 ** 15}, %{"cache_read" => 10 ** 15 + 1}},
      {%{"cache_write" => 10 ** 15}, %{"cache_write" => 10 ** 15 + 1}},
      {%{"context_tokens" => 10 ** 15}, %{"context_tokens" => 10 ** 15 + 1}},
      {%{"cost" => 10 ** 12, "cost_kind" => "list"},
       %{"cost" => 10 ** 12 + 0.5, "cost_kind" => "list"}},
      {%{"cost" => 1.5, "cost_kind" => "list"}, %{"cost" => 1.5}},
      {%{"context_window" => 1}, %{"context_window" => 0}},
      {%{"context_window" => 10 ** 9}, %{"context_window" => 10 ** 9 + 1}},
      {%{"input" => 10 ** 15 - 1}, %{"input" => -1}},
      {%{}, %{"cost_kind" => "list"}},
      {%{}, %{"extra" => 1}},
      {%{}, %{"context_window" => nil}}
    ]

    {:ok, file} = Session.File.create(dir, "sess00000001", "/repo", "test/ok")

    entries =
      for {{good, bad}, i} <- Enum.with_index(cases), {usage, kind} <- [{good, :g}, {bad, :b}] do
        message = %{"type" => "message", "role" => "assistant", "content" => []}

        {kind,
         Map.merge(message, %{
           "id" => entry_id("#{kind}#{i}"),
           "usage" => Map.merge(tokens, usage)
         })}
      end

    Enum.reduce(entries, file, fn {_kind, entry}, file ->
      append_raw(file, JSON.encode!(entry))
    end)

    assert {:ok, resumed} = SessionFile.resume(dir, "/repo")
    assert length(resumed.messages) == length(entries)

    for {{kind, entry}, %Message{usage: usage}} <- Enum.zip(entries, resumed.messages) do
      if kind == :g do
        fields =
          for {key, value} <- entry["usage"],
              do: {String.to_existing_atom(key), if(key == "cost_kind", do: :list, else: value)}

        assert usage == struct!(Helyx.Usage, fields)
      else
        assert usage == %Helyx.Usage{}
      end
    end
  end

  test "a bad usage decodes as the unknown usage; a bad model or stop reason as a missing one",
       %{tmp_dir: dir} do
    {:ok, file} = Session.File.create(dir, "sess00000001", "/repo", "test/ok")

    entries = [
      ~s({"id":"assistant00a","type":"message","role":"assistant","stop_reason":"banana","content":[]}),
      ~s({"id":"assistant00b","type":"message","role":"assistant","stop_reason":false,"content":[]}),
      ~s({"id":"assistant00c","type":"message","role":"assistant","model":42,"usage":[1],"content":[]}),
      ~s({"id":"assistant00d","type":"message","role":"assistant","usage":"x","stop_reason":{},"content":[]}),
      ~s({"id":"assistant00e","type":"message","role":"assistant","usage":{"input":12,"output":3},"content":[]}),
      ~s({"id":"assistant00f","type":"message","role":"assistant","usage":{"inputTokens":9},"content":[]}),
      ~s({"id":"assistant00g","type":"message","role":"assistant","usage":null,"content":[]})
    ]

    Enum.reduce(entries, file, &append_raw(&2, &1))

    assert {:ok, resumed} = SessionFile.resume(dir, "/repo")
    assert [nil, nil | unknown] = Enum.map(resumed.messages, & &1.usage)
    assert unknown == List.duplicate(%Helyx.Usage{}, 5)

    for message <- resumed.messages do
      assert %Message{role: :assistant, model: nil, stop_reason: nil} = message
    end
  end

  describe "the file size limit" do
    test "a file at the limit resumes; one byte over is rejected and not mutated",
         %{tmp_dir: dir} do
      {:ok, file} = Session.File.create(dir, "sess00000001", "/repo", "test/ok")
      # Multibyte content: the limit counts bytes, not characters.
      SessionFile.append_message(file, Message.user("héllo wörld"))
      size = File.stat!(file.path).size

      assert {:ok, _} = SessionFile.resume(dir, "/repo", max_bytes: size + 1)
      assert {:ok, resumed} = SessionFile.resume(dir, "/repo", max_bytes: size)
      assert [%Message{role: :user}] = resumed.messages

      # One byte over. A torn tail would be repaired on an accepted file;
      # here it must stay.
      File.write!(file.path, "{", [:append])
      before = File.read!(file.path)

      assert {:error, {:too_large, text}} = SessionFile.resume(dir, "/repo", max_bytes: size)
      assert text =~ "#{size}-byte limit"
      assert text =~ "start a new session"
      assert File.read!(file.path) == before
    end

    test "the limit counts the bytes read, not the repair newline", %{tmp_dir: dir} do
      {:ok, file} = started(dir, "sess00000001", "/repo", "test/ok")
      content = String.trim_trailing(File.read!(file.path), "\n")
      File.write!(file.path, content)
      limit = byte_size(content)

      # The file at the limit resumes, and the repair takes it one byte over.
      assert {:ok, _} = SessionFile.resume(dir, "/repo", max_bytes: limit)
      assert File.read!(file.path) == content <> "\n"

      assert {:error, {:too_large, _}} = SessionFile.resume(dir, "/repo", max_bytes: limit)
      assert File.read!(file.path) == content <> "\n"
    end

    test "the default limit is 64 MiB", %{tmp_dir: dir} do
      {:ok, file} = Session.File.create(dir, "sess00000001", "/repo", "test/ok")
      # A sparse file: 64 MiB + 1 byte of size, no data blocks written.
      File.open!(file.path, [:read, :write, :binary], fn io ->
        {:ok, _} = :file.position(io, 64 * 1024 * 1024)
        :ok = IO.binwrite(io, "\n")
      end)

      assert {:error, {:too_large, text}} = SessionFile.resume(dir, "/repo")
      assert text =~ "67108864-byte limit"
    end
  end

  @tag :slow
  test "a file of many short lines is not split into a list of all of them", %{tmp_dir: dir} do
    {:ok, file} = Session.File.create(dir, "sess00000001", "/repo", "test/ok")
    File.write!(file.path, String.duplicate("\n", 4 * 1024 * 1024), [:append])

    # 4 MiB of empty lines as a list is over 100 MiB of heap. The file
    # binary itself is off-heap. The process dies if its heap passes 16 MiB.
    {pid, ref} =
      spawn_monitor(fn ->
        Process.flag(:max_heap_size, %{size: div(16 * 1024 * 1024, 8), kill: true})
        exit({:result, SessionFile.resume(dir, "/repo")})
      end)

    assert_receive {:DOWN, ^ref, :process, ^pid, {:result, {:ok, resumed}}}
    assert resumed.messages == []
  end

  describe "the heap cap of the decode" do
    test "a file whose decode passes the cap is rejected and not mutated", %{tmp_dir: dir} do
      {:ok, file} = Session.File.create(dir, "sess00000001", "/repo", "test/ok")
      SessionFile.append_message(file, Message.user("hi"))
      assert {:ok, _} = SessionFile.resume(dir, "/repo", max_heap_bytes: 16 * 1024 * 1024)

      # 1 MiB of `[` with a torn last line: the decode of deep nesting takes
      # tens of bytes of heap per file byte. The torn tail would be repaired
      # on an accepted file; here it must stay.
      File.write!(file.path, String.duplicate("[", 1024 * 1024), [:append])
      before = File.read!(file.path)

      assert {:error, {:too_large, text}} =
               SessionFile.resume(dir, "/repo", max_heap_bytes: 16 * 1024 * 1024)

      assert text =~ "#{16 * 1024 * 1024} bytes of memory"
      assert text =~ "start a new session"
      assert File.read!(file.path) == before
    end

    @tag :slow
    test "a text-heavy session near the file limit fits the default cap", %{tmp_dir: dir} do
      {:ok, file} = Session.File.create(dir, "sess00000001", "/repo", "test/ok")

      file =
        SessionFile.append_message(
          file,
          Message.user(String.duplicate("line of output\n", 4000))
        )

      [_header, line] = String.split(File.read!(file.path), "\n", trim: true)
      count = div(63 * 1024 * 1024, byte_size(line) + 1)
      entry = JSON.decode!(line)

      # Each copy has its own id and hangs below the one before it.
      copies =
        for n <- 1..(count - 1)//1 do
          parent = if n == 1, do: file.leaf, else: entry_id("m#{n - 1}")
          [JSON.encode!(%{entry | "id" => entry_id("m#{n}"), "parent_id" => parent}), "\n"]
        end

      File.write!(file.path, copies, [:append])

      assert {:ok, resumed} = SessionFile.resume(dir, "/repo")
      assert length(resumed.messages) == count
    end

    test "the caller's heap does not hold the decode", %{tmp_dir: dir} do
      {:ok, file} = Session.File.create(dir, "sess00000001", "/repo", "test/ok")
      File.write!(file.path, String.duplicate("[", 1024 * 1024) <> "\n", [:append])

      # The caller dies if its heap passes 16 MiB; the decode alone needs more.
      {pid, ref} =
        spawn_monitor(fn ->
          Process.flag(:max_heap_size, %{size: div(16 * 1024 * 1024, 8), kill: true})
          exit({:result, SessionFile.resume(dir, "/repo")})
        end)

      assert_receive {:DOWN, ^ref, :process, ^pid, {:result, result}}
      assert {:ok, %{messages: []}} = result
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

    # The header replaced, the user message kept as the child of the new one.
    defp overwrite_session(dir, header) do
      File.rm_rf!(Session.File.path(dir, "/repo", "sess00000001"))
      {:ok, file} = started(dir, "sess00000001", "/repo", "test/ok")
      [old, rest] = String.split(File.read!(file.path), "\n", parts: 2)
      rest = String.replace(rest, JSON.decode!(old)["id"], "h")
      File.write!(file.path, header <> "\n" <> rest)
    end

    test "a header line of 65,536 bytes is found, also with multibyte text", %{tmp_dir: dir} do
      overwrite_session(dir, header_of(65_536, "é"))
      assert {:ok, _} = SessionFile.resume(dir, "/repo")

      overwrite_session(dir, header_of(65_535, "a"))
      assert {:ok, _} = SessionFile.resume(dir, "/repo")
    end

    test "a header line one byte over is not a session", %{tmp_dir: dir} do
      overwrite_session(dir, header_of(65_537, "a"))
      assert {:error, :not_found} = SessionFile.resume(dir, "/repo")
    end

    test "a file that is not regular is skipped, not opened", %{tmp_dir: dir} do
      {:ok, file} = started(dir, "sess00000001", "/repo", "test/ok")
      {_, 0} = System.cmd("mkfifo", [Path.join(Path.dirname(file.path), "pipe00000000.jsonl")])

      assert {:ok, resumed} = SessionFile.resume(dir, "/repo")
      assert id(resumed) == "sess00000001"
    end
  end

  describe "the file count of the header scan" do
    # "_repo" has the slug of "/repo", so its sessions share the directory.
    # `ts` replaces the start time in the header.
    defp session_at(dir, id, cwd, mtime, ts \\ "2026-01-01T00:00:00Z") do
      {:ok, file} = started(dir, id, cwd, "test/ok")
      [header, rest] = String.split(File.read!(file.path), "\n", parts: 2)
      header = header |> JSON.decode!() |> Map.put("ts", ts) |> JSON.encode!()
      File.write!(file.path, [header, "\n", rest])
      File.touch!(file.path, mtime)
      file
    end

    test "a session older than the newest files is not found", %{tmp_dir: dir} do
      session_at(dir, "old000000000", "/repo", 1_000)
      session_at(dir, "b00000000000", "_repo", 2_000)
      session_at(dir, "c00000000000", "_repo", 3_000)

      assert {:error, :not_found} = SessionFile.resume(dir, "/repo", max_scanned_files: 2)
      assert {:ok, resumed} = SessionFile.resume(dir, "/repo", max_scanned_files: 3)
      assert id(resumed) == "old000000000"
    end

    test "the modification time selects the files, then the start time decides",
         %{tmp_dir: dir} do
      session_at(dir, "first0000000", "/repo", 3_000, "2026-01-01T00:00:01Z")
      session_at(dir, "second000000", "/repo", 1_000, "2026-01-01T00:00:03Z")
      session_at(dir, "third0000000", "/repo", 2_000, "2026-01-01T00:00:02Z")

      assert {:ok, resumed} = SessionFile.resume(dir, "/repo", max_scanned_files: 1)
      assert id(resumed) == "first0000000"

      assert {:ok, resumed} = SessionFile.resume(dir, "/repo")
      assert id(resumed) == "second000000"
    end

    test "a file that is not regular does not count", %{tmp_dir: dir} do
      file = session_at(dir, "sess00000001", "/repo", 1_000)
      {_, 0} = System.cmd("mkfifo", [Path.join(Path.dirname(file.path), "pipe00000000.jsonl")])

      assert {:ok, resumed} = SessionFile.resume(dir, "/repo", max_scanned_files: 1)
      assert id(resumed) == "sess00000001"
    end

    test "the default limit is 256 files", %{tmp_dir: dir} do
      session_at(dir, "old000000000", "/repo", 1_000)
      for n <- 1..255, do: session_at(dir, Session.Id.new(), "_repo", 2_000 + n)
      assert {:ok, resumed} = SessionFile.resume(dir, "/repo")
      assert id(resumed) == "old000000000"

      session_at(dir, "s10000000256", "_repo", 3_000)
      assert {:error, :not_found} = SessionFile.resume(dir, "/repo")
    end

    test "the path breaks a tie of the modification time", %{tmp_dir: dir} do
      session_at(dir, "a00000000000", "/repo", 1_000)
      session_at(dir, "b00000000000", "_repo", 1_000)

      assert {:error, :not_found} = SessionFile.resume(dir, "/repo", max_scanned_files: 1)

      assert {:ok, resumed} = SessionFile.resume(dir, "_repo", max_scanned_files: 1)
      assert id(resumed) == "b00000000000"
    end
  end

  # A valid entry id (`Helyx.Session.Id.valid?/1`) that names its case.
  defp entry_id(name), do: String.pad_leading(name, 12, "_")
end
