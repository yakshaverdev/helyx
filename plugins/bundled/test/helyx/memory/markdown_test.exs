defmodule Helyx.Memory.MarkdownTest do
  use ExUnit.Case, async: true

  alias Helyx.Memory.Markdown
  alias Helyx.Message

  defp user(text, id), do: %{Message.user(text, %{kind: :user, id: nil}) | id: id}

  defp assistant(text, id, stop \\ :end_turn),
    do: %Message{
      role: :assistant,
      content: [%Message.Text{text: text}],
      id: id,
      stop_reason: stop
    }

  # The default `recall_ms` of `Helyx.Core`.
  @recall_ms 2_000

  defp entries(messages), do: Enum.map(messages, &%{message: &1, persisted: true})
  defp opts(dir), do: [dir: dir, session_id: "s1"]
  defp logs(dir), do: Path.wildcard(Path.join([dir, "log", "*.md"]))
  defp times(dir), do: Path.wildcard(Path.join([dir, "log", "time", "*", "*.md"]))
  defp hash(id), do: Base.encode16(:crypto.hash(:sha256, id), case: :lower)

  # The time name of write number `seq` and hash `hash`, as sync makes it.
  defp time_name(dir, seq, hash) do
    bucket = seq |> div(1_000) |> Integer.to_string() |> String.pad_leading(9, "0")
    name = (seq |> Integer.to_string() |> String.pad_leading(12, "0")) <> "-#{hash}.md"
    Path.join([dir, "log", "time", bucket, name])
  end

  defp write!(path, text) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, text)
  end

  @tag :tmp_dir
  test "sync stores each message once by id, also for two calls at once", %{tmp_dir: dir} do
    batch = entries([user("deploy the frontend", "u1"), assistant("deployed frontend", "a1")])
    assert :ok = Markdown.sync(batch, opts(dir))
    assert :ok = Markdown.sync(batch, opts(dir))

    results =
      1..8
      |> Task.async_stream(fn _ -> Markdown.sync(batch, opts(dir)) end)
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.uniq(results) == [:ok]
    assert length(logs(dir)) == 2
    assert Path.wildcard(Path.join([dir, "log", ".tmp-*"]), match_dot: true) == []

    # One time name per message, in batch order, a second name of one file.
    assert times(dir) == [time_name(dir, 0, hash("u1")), time_name(dir, 1, hash("a1"))]

    for {id, time} <- [{"u1", 0}, {"a1", 1}] do
      assert %File.Stat{links: 2, inode: inode} =
               File.stat!(Path.join([dir, "log", hash(id) <> ".md"]))

      assert %File.Stat{inode: ^inode} = File.stat!(time_name(dir, time, hash(id)))
    end
  end

  @tag :tmp_dir
  test "calls at once with new messages store each once, with one time name of the same file",
       %{tmp_dir: dir} do
    messages = for n <- 1..20, do: user("m#{n}", "u#{n}")

    results =
      1..8
      |> Task.async_stream(fn _ -> Markdown.sync(entries(Enum.shuffle(messages)), opts(dir)) end)
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.uniq(results) == [:ok]
    assert length(logs(dir)) == 20
    assert length(times(dir)) == 20

    for time <- times(dir) do
      <<_seq::binary-12, ?-, hash::binary-64, ".md">> = Path.basename(time)
      assert File.stat!(time).inode == File.stat!(Path.join([dir, "log", hash <> ".md"])).inode
    end
  end

  @tag :tmp_dir
  test "sync numbers its writes on from the highest number of the highest bucket",
       %{tmp_dir: dir} do
    write!(time_name(dir, 1_998, hash("x")), "old\n")
    write!(time_name(dir, 41, hash("y")), "old\n")
    File.mkdir_p!(Path.join([dir, "log", "time", "not-a-bucket"]))

    :ok = Markdown.sync(entries([user("one", "u1"), user("two", "u2")]), opts(dir))
    assert File.exists?(time_name(dir, 1_999, hash("u1")))
    assert File.exists?(time_name(dir, 2_000, hash("u2")))

    # An empty highest bucket starts at its first number.
    File.mkdir_p!(Path.join([dir, "log", "time", "000000007"]))
    :ok = Markdown.sync(entries([user("three", "u3")]), opts(dir))
    assert File.exists?(time_name(dir, 7_000, hash("u3")))
  end

  @tag :tmp_dir
  test "sync skips aborted and failed replies, and keeps a reply with a tool call",
       %{tmp_dir: dir} do
    call = %Message.ToolCall{id: "c", name: "bash", arguments: %{}}

    batch =
      entries([
        assistant("half", "a1", :aborted),
        assistant("broken", "a2", :error),
        %{assistant("run it", "a3", :tool_use) | content: [%Message.Text{text: "run it"}, call]}
      ])

    assert :ok = Markdown.sync(batch, opts(dir))
    assert [path] = logs(dir)

    assert File.read!(path) =~
             ~r/^<!-- helyx-memory role=assistant origin=none id="a3" session=s1 /

    assert File.read!(path) =~ "run it\n[tool call: bash]\n"
  end

  @tag :tmp_dir
  test "recall greps the query words in the notes and the log, with file:line sources",
       %{tmp_dir: dir} do
    :ok =
      Markdown.sync(
        entries([user("please deploy the frontend", "u1"), assistant("frontend deployed", "a1")]),
        opts(dir)
      )

    {:ok, "saved"} = Markdown.write_note("the frontend deploy needs a token", dir)

    assert {:ok, records} =
             Markdown.recall(%{text: "Deploy the FRONTEND?", origin: nil}, opts(dir))

    assert [best | rest] = records

    assert best == %{
             id: "notes.md:1",
             source: "notes.md:1",
             text: "- the frontend deploy needs a token"
           }

    texts = Enum.map(rest, & &1.text)
    assert "please deploy the frontend" in texts
    assert "(generated by the assistant) frontend deployed" in texts

    assert Enum.all?(
             rest,
             &(&1.id =~ ~r"^log/time/000000000/00000000000[01]-[0-9a-f]{64}\.md:2$")
           )
  end

  @tag :tmp_dir
  test "recall has bounds: no words of three characters, 32 records, 1,024 bytes",
       %{tmp_dir: dir} do
    long = String.duplicate("é", 600)
    lines = for i <- 1..40, do: "alpha #{i} #{long}\n"
    File.write!(Path.join(dir, "a.md"), lines)

    assert {:ok, []} = Markdown.recall(%{text: "a an to", origin: nil}, opts(dir))
    assert {:ok, records} = Markdown.recall(%{text: "alpha", origin: nil}, opts(dir))
    assert length(records) == 32
    assert Enum.all?(records, &(byte_size(&1.text) in 1_023..1_024))
    assert Enum.all?(records, &String.valid?(&1.text))
  end

  @tag :tmp_dir
  test "recall skips a file that is not regular and one over 1 MiB", %{tmp_dir: dir} do
    {_, 0} = System.cmd("mkfifo", [Path.join(dir, "fifo.md")])
    File.write!(Path.join(dir, "big.md"), ["alpha\n", String.duplicate("x", 1_048_576)])
    File.write!(Path.join(dir, "ok.md"), "alpha here\n")

    assert {:ok, [%{source: "ok.md:1"}]} =
             Markdown.recall(%{text: "alpha", origin: nil}, opts(dir))
  end

  # 1,000 files or more: about 1 s on a loaded machine.
  @tag :slow
  @tag :tmp_dir
  test "recall reads the notes, then the newest log files, past 1,000 log files",
       %{tmp_dir: dir} do
    # Hashes that sort before every other: in name order they would fill
    # the 1,000 files, and the new message would not be read.
    for n <- 0..1_099 do
      write!(time_name(dir, n, String.pad_leading("#{n}", 64, "0")), "zephyr old #{n} k#{n}x\n")
    end

    {:ok, "saved"} = Markdown.write_note("zephyr note", dir)
    :ok = Markdown.sync(entries([user("zephyr quokka new", "u-new")]), opts(dir))
    assert File.exists?(time_name(dir, 1_100, hash("u-new")))

    assert {:ok, [first, second | rest]} =
             Markdown.recall(%{text: "zephyr quokka", origin: nil}, opts(dir))

    # The new message matches two words; then the note and the old files,
    # one word each, in read order up to the 32 records.
    assert first.text == "zephyr quokka new"
    assert second.id == "notes.md:1"

    assert Enum.map(rest, & &1.text) ==
             for(n <- 1_099..1_070//-1, do: "zephyr old #{n} k#{n}x")

    # 1,000 files: the note, the new message, and the old files 1,099 to 102.
    assert {:ok, [%{text: "zephyr old 102 k102x"}]} =
             Markdown.recall(%{text: "k102x k101x", origin: nil}, opts(dir))
  end

  # 100,000 file names: the setup and the removal take about 100 s on a
  # loaded machine (a link about 420 µs, measured on 2026-11-06).
  @tag :slow
  @tag timeout: 600_000
  @tag :tmp_dir
  test "recall over 100,000 log files ends within the default recall_ms and reads a new message",
       %{tmp_dir: dir} do
    on_exit(fn -> File.rm_rf!(dir) end)

    # Time names only: recall lists no id name while the time names fill
    # its bound. One file per bucket with 1,000 links, and raw calls: 100,000
    # files and the file server would make the setup take minutes.
    for bucket <- 0..99 do
      first = time_name(dir, bucket * 1_000, hash("m#{bucket * 1_000}"))
      File.mkdir_p!(Path.dirname(first))
      :ok = :prim_file.write_file(first, "zephyr old #{bucket}\n")

      for n <- (bucket * 1_000 + 1)..(bucket * 1_000 + 999)//1,
          do: :ok = :prim_file.make_link(first, time_name(dir, n, hash("m#{n}")))
    end

    :ok = Markdown.sync(entries([user("zephyr quokka new", "u-new")]), opts(dir))

    # The bound is the acceptance of #852, the Core default of `recall_ms`,
    # not a margin: the recall lists 101 bucket names and 2 buckets and reads
    # 1,000 small files: 324 to 456 ms on a loaded laptop (2026-11-06).
    task = Task.async(fn -> Markdown.recall(%{text: "zephyr quokka", origin: nil}, opts(dir)) end)

    assert {:ok, {:ok, [%{text: "zephyr quokka new"} | _]}} =
             Task.yield(task, @recall_ms) || Task.shutdown(task, :brutal_kill)
  end

  @tag :tmp_dir
  test "recall reads one time name per hash, then the id names of an old folder in name order",
       %{tmp_dir: dir} do
    log = Path.join(dir, "log")
    # An old folder: id names with no time name, read in name order.
    for name <- ["b", "a"], do: write!(Path.join(log, "#{name}.md"), "walrus old #{name}\n")

    # A crash between the two links, then the replay: two time names of
    # one message, with one id name.
    write!(time_name(dir, 3, hash("u1")), "walrus crash\n")
    :ok = Markdown.sync(entries([user("walrus new", "u1"), user("walrus two", "u2")]), opts(dir))
    assert File.exists?(time_name(dir, 4, hash("u1")))

    # Names of another form in `log/time/` are not read.
    write!(Path.join([dir, "log", "time", "000000000", "bad.md"]), "walrus bad\n")

    write!(
      Path.join([dir, "log", "time", "12", time_name(dir, 5, hash("x")) |> Path.basename()]),
      "walrus bad\n"
    )

    assert {:ok, records} = Markdown.recall(%{text: "walrus", origin: nil}, opts(dir))

    assert Enum.map(records, & &1.text) ==
             ["walrus two", "walrus new", "walrus old a", "walrus old b"]
  end

  # 1,000 files or more: about 1 s on a loaded machine.
  @tag :slow
  @tag :tmp_dir
  test "a listing error while sync looks for the next number fails the sync, past 1,000 messages",
       %{tmp_dir: dir} do
    for bucket <- 0..1 do
      first = time_name(dir, bucket * 1_000, hash("m#{bucket * 1_000}"))
      write!(first, "old\n")

      for n <- (bucket * 1_000 + 1)..(bucket * 1_000 + 999)//1,
          do: :ok = :prim_file.make_link(first, time_name(dir, n, hash("m#{n}")))
    end

    time = Path.join([dir, "log", "time"])
    bucket = Path.join(time, "000000001")
    on_exit(fn -> for d <- [time, bucket], do: File.chmod(d, 0o755) end)

    # Write and path access, no listing: a link in the folder still works,
    # so a number from the empty view would put the message below the
    # newest 1,000 for good.
    for folder <- [bucket, time] do
      File.chmod!(folder, 0o300)

      assert {:error, "memory folder failed: permission denied"} =
               Markdown.sync(entries([user("zephyr new", "u-new")]), opts(dir))

      refute File.exists?(Path.join([dir, "log", hash("u-new") <> ".md"]))
      File.chmod!(folder, 0o755)
    end

    :ok = Markdown.sync(entries([user("zephyr new", "u-new")]), opts(dir))
    assert File.exists?(time_name(dir, 2_000, hash("u-new")))
  end

  @tag :tmp_dir
  test "a file at the highest bucket name fails sync with an error (a hand-made entry)",
       %{tmp_dir: dir} do
    write!(Path.join([dir, "log", "time", "000000005"]), "not a folder\n")

    assert {:error, "memory folder failed: not a directory"} =
             Markdown.sync(entries([user("one", "u1")]), opts(dir))
  end

  # 1,000 files or more: about 1 s on a loaded machine.
  @tag :slow
  @tag :tmp_dir
  test "the id names of an old folder are left out when the time names fill the bound",
       %{tmp_dir: dir} do
    write!(Path.join([dir, "log", "0.md"]), "walrus old\n")

    for n <- 0..999, do: write!(time_name(dir, n, hash("m#{n}")), "k#{n}x\n")

    assert {:ok, []} = Markdown.recall(%{text: "walrus", origin: nil}, opts(dir))
    assert {:ok, [%{text: "k0x"}]} = Markdown.recall(%{text: "k0x", origin: nil}, opts(dir))
  end

  @tag :tmp_dir
  test "recall skips a file whose name cannot make a record id of 256 bytes",
       %{tmp_dir: dir} do
    File.write!(Path.join(dir, String.duplicate("n", 237) <> ".md"), "alpha\n")
    File.write!(Path.join(dir, String.duplicate("o", 238) <> ".md"), "alpha\n")

    assert {:ok, [%{id: id}]} = Markdown.recall(%{text: "alpha", origin: nil}, opts(dir))
    assert byte_size(id) == 242
  end

  @tag :tmp_dir
  test "recall reads its own folder when the folder name holds glob characters",
       %{tmp_dir: dir} do
    mem = Path.join(dir, "mem[ab]")
    File.mkdir_p!(Path.join(dir, "mema"))
    File.write!(Path.join([dir, "mema", "x.md"]), "zebra elsewhere\n")
    {:ok, "saved"} = Markdown.write_note("zebra note", mem)

    assert {:ok, [%{id: "notes.md:1"}]} =
             Markdown.recall(%{text: "zebra", origin: nil}, opts(mem))
  end

  @tag :tmp_dir
  test "a note is never written to a file that is not regular", %{tmp_dir: dir} do
    {_, 0} = System.cmd("mkfifo", [Path.join(dir, "notes.md")])
    assert {:error, "memory write failed: " <> _} = Markdown.write_note("hi", dir)
  end

  @tag :tmp_dir
  test "a note has 1 to 4,096 bytes and is one line", %{tmp_dir: dir} do
    assert {:error, _} = Markdown.write_note("", dir)
    assert {:error, _} = Markdown.write_note(String.duplicate("a", 4_097), dir)
    assert {:ok, "saved"} = Markdown.write_note(String.duplicate("a", 4_096), dir)
    assert {:ok, "saved"} = Markdown.write_note("two\nlines", dir)

    assert [_, "- two lines"] =
             dir |> Path.join("notes.md") |> File.read!() |> String.split("\n", trim: true)

    assert {:error, "text must be a string"} = Markdown.run(%{"text" => 1}, dir)
  end

  test "a product adds it to its plugin list as a memory and a tool" do
    core = :"core_#{System.unique_integer([:positive])}"
    plugins = [Helyx.Provider.Fake, Helyx.ModelContext.Default, Markdown]
    start_supervised!({Helyx.Core, name: core, plugins: plugins})
    assert Helyx.Core.plugins(core, Helyx.Memory) == [Markdown]
    assert Helyx.Core.plugins(core, Helyx.Tool) == [Markdown]
  end
end
