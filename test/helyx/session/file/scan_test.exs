defmodule Helyx.Session.File.ScanTest do
  use ExUnit.Case, async: true

  alias Helyx.{Message, Session}
  alias Helyx.Session.File.Scan
  alias Helyx.Session.File.Scan.Summary

  @moduletag :tmp_dir

  # A session with the prompt `prompt` (nil for none), its file touched to
  # `mtime`.
  defp session(dir, cwd, mtime, prompt, id \\ Session.Id.new()) do
    {:ok, file} = Session.File.create(dir, id, cwd, "test/ok")
    if prompt, do: Session.File.append_message(file, Message.user(prompt))
    File.touch!(file.path, mtime)
    {id, file.path}
  end

  defp ids(summaries), do: Enum.map(summaries, & &1.id)

  test "the list of a folder: newest first, without empty or unreadable files", %{tmp_dir: dir} do
    {old, _} = session(dir, "/repo", 1_000, "first")
    {new, _} = session(dir, "/repo", 3_000, "second")
    {_empty, _} = session(dir, "/repo", 4_000, nil)

    # A model change is no message.
    {_, path} = session(dir, "/repo", 5_000, nil)
    File.write!(path, ~s({"id":"m","type":"model_change","model":"test/x"}\n), [:append])
    File.touch!(path, 5_000)

    # Another folder with the same slug, an older format with no session
    # header, an unknown version, and a file name that is not an id.
    {other, _} = session(dir, "_repo", 2_000, "other")
    {_, path} = session(dir, "/repo", 6_000, "old format")
    File.write!(path, ~s({"type":"message","role":"user","content":[]}\n))
    {_, path} = session(dir, "/repo", 7_000, "next version")
    File.write!(path, String.replace(File.read!(path), ~s("version":1), ~s("version":2)))
    session(dir, "/repo", 8_000, "bad name", "sess1")

    # A header with no string model, and one with no string cwd.
    {_, path} = session(dir, "/repo", 9_000, "number model")
    File.write!(path, String.replace(File.read!(path), ~s("model":"test/ok"), ~s("model":1)))
    {_, path} = session(dir, "/repo", 9_500, "null cwd")
    File.write!(path, String.replace(File.read!(path), ~s("cwd":"/repo"), ~s("cwd":null)))

    assert [
             %Summary{id: ^new, cwd: "/repo", model: "test/ok", mtime: 3_000, prompt: "second"},
             %Summary{id: ^old, mtime: 1_000, prompt: "first"}
           ] = Scan.list(dir, "/repo")

    assert ids(Scan.list(dir, :all)) == [new, other, old]
    assert Scan.list(dir, "/nothing") == []
    assert Scan.list(Path.join(dir, "missing"), :all) == []
  end

  test "the first prompt is the text of the first user message", %{tmp_dir: dir} do
    {:ok, file} = Session.File.create(dir, Session.Id.new(), "/repo", "test/ok")

    file
    |> Session.File.append_model_change("test/other")
    |> Session.File.append_message(%Message{
      role: :user,
      content: [
        %Message.Text{text: "look"},
        %Message.Image{mime_type: "image/png", data: "aGk="},
        %Message.Text{text: "at\e[2J this"}
      ]
    })
    |> Session.File.append_message(Message.user("later"))

    # The text comes as the file holds it: the client cleans it.
    assert [%Summary{prompt: "look at\e[2J this", model: "test/ok"}] = Scan.list(dir, "/repo")

    # A first message that is not a user message gives no prompt.
    {:ok, file} = Session.File.create(dir, Session.Id.new(), "/b", "test/ok")
    Session.File.append_message(file, %Message{role: :assistant, content: []})
    assert [%Summary{prompt: ""}] = Scan.list(dir, "/b")
  end

  describe "the head bound of 65,536 bytes" do
    # A session whose header line, with its newline, has `bytes` bytes.
    defp padded(dir, bytes) do
      {id, path} = session(dir, "/repo", 1_000, nil)
      header = path |> File.read!() |> String.trim_trailing("\n")
      pad = bytes - byte_size(header) - 1

      File.write!(
        path,
        String.replace(
          header,
          ~s("model":"test/ok"),
          ~s("model":"test/ok"#{String.duplicate(" ", pad)})
        ) <> "\n"
      )

      assert File.stat!(path).size == bytes
      {id, path}
    end

    test "a file of at most the head with no message is empty; one byte over is not known empty",
         %{tmp_dir: dir} do
      {_, path} = padded(dir, 65_535)
      assert Scan.list(dir, "/repo") == []
      File.rm!(path)

      {_, path} = padded(dir, 65_536)
      assert Scan.list(dir, "/repo") == []
      assert Session.File.resume(dir, "/repo") == {:error, :not_found}
      File.rm!(path)

      {id, _} = padded(dir, 65_537)
      assert [%Summary{id: ^id, prompt: ""}] = Scan.list(dir, "/repo")
      assert {:ok, %{session_id: ^id}} = Session.File.resume(dir, "/repo")
    end

    test "a first prompt whose line ends at the last byte of the head is kept; one byte over, not",
         %{tmp_dir: dir} do
      # The message line, newline included, ends at byte `size` of the file.
      at = fn cwd, size ->
        {:ok, file} = Session.File.create(dir, Session.Id.new(), cwd, "test/ok")
        Session.File.append_message(file, Message.user("é"))
        bytes = size - File.stat!(file.path).size
        pad = String.duplicate("é", div(bytes, 2)) <> String.duplicate("a", rem(bytes, 2))
        File.write!(file.path, String.replace(File.read!(file.path), ~s("é"), ~s("é#{pad}")))
        assert File.stat!(file.path).size == size
      end

      at.("/a", 65_537)
      assert [%Summary{prompt: "é" <> _}] = Scan.list(dir, "/a")
      at.("/b", 65_538)
      assert [%Summary{prompt: ""}] = Scan.list(dir, "/b")
    end

    test "a head of short lines is walked, not split into a list of all of them",
         %{tmp_dir: dir} do
      {id, path} = session(dir, "/repo", 1_000, nil)
      File.write!(path, String.duplicate("\n", 1024 * 1024), [:append])

      # 65,535 lines as a list are about 4 MiB of heap.
      {pid, ref} =
        spawn_monitor(fn ->
          Process.flag(:max_heap_size, %{size: div(2 * 1024 * 1024, 8), kill: true})
          exit({:result, Scan.list(dir, "/repo")})
        end)

      assert_receive {:DOWN, ^ref, :process, ^pid, {:result, [%Summary{id: ^id}]}}
    end

    test "a first prompt past the head is empty, also when the bound cuts a character",
         %{tmp_dir: dir} do
      {:ok, file} = Session.File.create(dir, Session.Id.new(), "/repo", "test/ok")
      header_bytes = File.stat!(file.path).size
      Session.File.append_message(file, Message.user(String.duplicate("é", 40_000)))
      assert File.stat!(file.path).size > 65_536 + header_bytes

      assert [%Summary{prompt: ""}] = Scan.list(dir, "/repo")

      # The same prompt that ends inside the head is kept whole.
      {:ok, file} = Session.File.create(dir, Session.Id.new(), "/b", "test/ok")
      Session.File.append_message(file, Message.user(String.duplicate("é", 20_000)))
      assert [%Summary{prompt: prompt}] = Scan.list(dir, "/b")
      assert prompt == String.duplicate("é", 20_000)
    end
  end

  test "the list reads the 256 newest files, also with :all", %{tmp_dir: dir} do
    prompts = fn scope -> Enum.map(Scan.list(dir, scope), & &1.prompt) end
    for n <- 1..255, do: session(dir, "/repo", 2_000 + n, "p#{n}")
    session(dir, "/repo", 1_000, "oldest")

    assert length(prompts.("/repo")) == 256
    assert List.last(prompts.("/repo")) == "oldest"

    # A newer file of another folder: the oldest falls out of :all only.
    session(dir, "/b", 3_000, "elsewhere")
    assert length(prompts.(:all)) == 256
    refute "oldest" in prompts.(:all)
    assert "oldest" in prompts.("/repo")

    session(dir, "/repo", 4_000, "newest")
    assert length(prompts.("/repo")) == 256
    refute "oldest" in prompts.("/repo")
  end

  describe "find/2" do
    test "the file of an id, under any project folder", %{tmp_dir: dir} do
      {id, path} = session(dir, "/repo", 1_000, nil)
      assert {:ok, ^path, %{"cwd" => "/repo"}} = Scan.find(dir, id)
      assert {:error, :not_found} = Scan.find(dir, Session.Id.new())
    end

    test "an id with a path character never reaches the filesystem", %{tmp_dir: dir} do
      # Session files that `<dir>/*/<id>.jsonl` reaches with a path in the
      # id: `../x` and `../escaped01`, 12 characters.
      {_, path} = session(dir, "/repo", 1_000, "x")
      File.cp!(path, Path.join(dir, "x.jsonl"))
      File.cp!(path, Path.join(dir, "escaped01.jsonl"))

      for bad <- [
            "../escaped01",
            "../x",
            "a/b/c/d/e/fg",
            "..",
            "",
            "abcdefghijk",
            "abcdefghijklm",
            "abcdefghijk.",
            "abcdefghijk\n",
            "abcdefghijk*",
            "ab\0defghijkl",
            "abcdefghijké",
            nil
          ] do
        assert Scan.find(dir, bad) == {:error, :invalid_id}
      end

      # Without the check, the pattern of the lookup reaches both files.
      for id <- ["../x", "../escaped01"],
          do: assert([_] = Path.wildcard(Path.join([dir, "*", id <> ".jsonl"])))
    end

    test "two files with one id, or a file with no session header", %{tmp_dir: dir} do
      {id, path} = session(dir, "/repo", 1_000, "x")
      copy = Path.join([dir, "other", Path.basename(path)])
      File.mkdir_p!(Path.dirname(copy))
      File.cp!(path, copy)
      assert {:error, :duplicate_id} = Scan.find(dir, id)

      File.write!(copy, "not json\n")
      File.rm!(path)
      assert {:error, {:invalid_file, _}} = Scan.find(dir, id)

      # The header of a found file has a string cwd.
      File.write!(copy, ~s({"type":"session","version":1,"cwd":7,"model":"test/ok"}\n))
      assert {:error, {:invalid_file, _}} = Scan.find(dir, id)
    end

    test "resume by id: the header must name the directory", %{tmp_dir: dir} do
      {id, _} = session(dir, "/repo", 1_000, nil)

      # An empty session resumes by its id.
      assert {:ok, %{session_id: ^id, messages: []}} = Session.File.resume(dir, "/repo", id: id)
      assert {:error, :not_found} = Session.File.resume(dir, "/other", id: id)
      assert {:error, :invalid_id} = Session.File.resume(dir, "/repo", id: "../" <> id)
    end
  end

  test "the newest session skips a file whose name is not a session id, as the list does",
       %{tmp_dir: dir} do
    {id, _} = session(dir, "/repo", 1_000, "valid")

    # Started later, and newer by modification time.
    for name <- ["sess1", "not-a-session-id"], do: session(dir, "/repo", 2_000, "bad", name)

    assert ids(Scan.list(dir, "/repo")) == [id]
    assert {:ok, %{session_id: ^id}} = Session.File.resume(dir, "/repo")
  end
end
