defmodule Helyx.LedgerTest do
  use ExUnit.Case, async: true

  alias Helyx.{Ledger, Message, Usage}
  alias Helyx.Session.Totals

  @moduletag :tmp_dir

  @since ~U[2026-11-01 00:00:00Z]
  @until ~U[2026-11-04 00:00:00Z]

  defp header(id, cwd, opts \\ []) do
    header = %{
      "id" => id,
      "parent_id" => nil,
      "ts" => "2026-11-01T00:00:00Z",
      "type" => "session",
      "version" => 1,
      "cwd" => cwd,
      "model" => Keyword.get(opts, :model, "m/x")
    }

    case Keyword.get(opts, :parent) do
      nil -> header
      parent -> Map.put(header, "parent", %{"session_id" => parent, "call_id" => "call_1"})
    end
  end

  defp user(id, parent, ts, text) do
    %{
      "id" => id,
      "parent_id" => parent,
      "ts" => ts,
      "type" => "message",
      "role" => "user",
      "origin" => %{"kind" => "user", "id" => nil},
      "content" => [%{"type" => "text", "text" => text}]
    }
  end

  defp assistant(id, parent, ts, text, usage, opts \\ []) do
    entry = %{
      "id" => id,
      "parent_id" => parent,
      "ts" => ts,
      "type" => "message",
      "role" => "assistant",
      "model" => Keyword.get(opts, :model, "m/x"),
      "stop_reason" => Keyword.get(opts, :stop, "end_turn"),
      "content" => [%{"type" => "text", "text" => text}]
    }

    if usage, do: Map.put(entry, "usage", usage), else: entry
  end

  defp assistant_call(id, parent, ts, call_id, name, usage \\ nil) do
    entry = %{
      "id" => id,
      "parent_id" => parent,
      "ts" => ts,
      "type" => "message",
      "role" => "assistant",
      "model" => "m/x",
      "stop_reason" => "tool_use",
      "content" => [%{"type" => "tool_call", "id" => call_id, "name" => name, "arguments" => %{}}]
    }

    if usage, do: Map.put(entry, "usage", usage), else: entry
  end

  defp tool_result(id, parent, ts, call_id, name, opts \\ []) do
    %{
      "id" => id,
      "parent_id" => parent,
      "ts" => ts,
      "type" => "message",
      "role" => "tool_result",
      "tool_call_id" => call_id,
      "tool_name" => name,
      "is_error" => Keyword.get(opts, :error, false),
      "content" => [%{"type" => "text", "text" => "ok"}]
    }
  end

  defp usage(input, output, opts \\ []) do
    usage = %{
      "input" => input,
      "output" => output,
      "cache_read" => Keyword.get(opts, :cache_read, 0),
      "cache_write" => Keyword.get(opts, :cache_write, 0)
    }

    case Keyword.get(opts, :cost) do
      nil -> usage
      cost -> Map.merge(usage, %{"cost" => cost, "cost_kind" => "billed"})
    end
  end

  defp write(dir, folder, id, entries) do
    path = Path.join([dir, folder, id <> ".jsonl"])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Enum.map_join(entries, "\n", &JSON.encode!/1) <> "\n")
    path
  end

  defp write_lines(dir, folder, id, lines) do
    path = Path.join([dir, folder, id <> ".jsonl"])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Enum.map_join(lines, "\n", & &1) <> "\n")
    path
  end

  defp read(dir, opts \\ []) do
    {:ok, ledger} = Ledger.read(dir, Keyword.merge([since: @since, until: @until], opts))
    ledger
  end

  defp message(input, output, opts) do
    %Message{
      role: :assistant,
      content: [],
      usage: %Usage{
        input: input,
        output: output,
        cache_read: Keyword.get(opts, :cache_read, 0),
        cache_write: Keyword.get(opts, :cache_write, 0)
      }
    }
  end

  defp add_all(messages) do
    Enum.reduce(messages, %Totals{}, fn message, totals -> Totals.add(totals, message) end)
  end

  test "totals, days, models, and projects are the sums of Totals.add/2", %{tmp_dir: dir} do
    a1 =
      assistant(
        "m1",
        "h1",
        "2026-11-01T10:00:00Z",
        "a",
        usage(10, 5, cache_read: 2, cache_write: 1),
        model: "m/a"
      )

    a2 =
      assistant("m2", "h2", "2026-11-02T10:00:00Z", "b", usage(20, 7, cache_read: 3),
        model: "m/b"
      )

    a3 =
      assistant(
        "m3",
        "h1",
        "2026-11-03T10:00:00Z",
        "c",
        usage(30, 9, cache_read: 4, cache_write: 2),
        model: "m/a"
      )

    write(dir, "repo-a", "session00001", [header("h1", "/repo/a", model: "m/a"), a1, a3])
    write(dir, "repo-b", "session00002", [header("h2", "/repo/b", model: "m/b"), a2])

    ledger = read(dir)

    m1 = message(10, 5, cache_read: 2, cache_write: 1)
    m2 = message(20, 7, cache_read: 3)
    m3 = message(30, 9, cache_read: 4, cache_write: 2)

    assert ledger.files == 2
    assert ledger.totals == add_all([m1, m2, m3])
    assert ledger.by_day["2026-11-01"] == add_all([m1])
    assert ledger.by_day["2026-11-02"] == add_all([m2])
    assert ledger.by_day["2026-11-03"] == add_all([m3])
    assert ledger.by_model["m/a"] == add_all([m1, m3])
    assert ledger.by_model["m/b"] == add_all([m2])
    assert ledger.by_project["/repo/a"] == add_all([m1, m3])
    assert ledger.by_project["/repo/b"] == add_all([m2])
    assert ledger.sessions["session00001"].totals == add_all([m1, m3])
    assert ledger.sessions["session00002"].totals == add_all([m2])
  end

  test "a user message of a product, a background run, or a hook is not the prompt",
       %{tmp_dir: dir} do
    others =
      for {kind, n} <- Enum.with_index(~w(product background hook)) do
        user("m#{n}", "h1", "2026-11-02T10:00:0#{n}Z", "from #{kind}")
        |> Map.put("origin", %{"kind" => kind, "id" => "x"})
      end

    typed = user("m9", "h1", "2026-11-02T10:00:09Z", "typed")
    write(dir, "p", "session00001", [header("h1", "/repo")] ++ others ++ [typed])

    ledger = read(dir)

    assert ledger.skipped_entries == 0
    assert ledger.sessions["session00001"].prompt =~ "typed"
  end

  test "an assistant with no usage adds nothing", %{tmp_dir: dir} do
    message =
      assistant("m1", "h1", "2026-11-02T10:00:00Z", "hi", nil)

    write(dir, "p", "session00001", [header("h1", "/repo"), message])

    ledger = read(dir)

    assert ledger.totals == %Totals{}
    assert ledger.sessions["session00001"].totals == %Totals{}
  end

  test "a usage with cost nil makes the cost unknown", %{tmp_dir: dir} do
    message = assistant("m1", "h1", "2026-11-02T10:00:00Z", "hi", usage(0, 0))
    write(dir, "p", "session00001", [header("h1", "/repo"), message])

    ledger = read(dir)

    assert ledger.totals.input == 0
    assert ledger.totals.cost == nil
    assert ledger.totals.unknown
  end

  test "the window includes since, excludes until, and skips an old file", %{tmp_dir: dir} do
    at_since = assistant("m1", "h1", "2026-11-01T00:00:00Z", "a", usage(1, 1))
    at_until = assistant("m2", "h1", "2026-11-04T00:00:00Z", "b", usage(2, 2))
    write(dir, "p", "session00001", [header("h1", "/repo"), at_since, at_until])

    old = assistant("m3", "h2", "2026-11-02T10:00:00Z", "c", usage(3, 3))
    path = write(dir, "q", "session00002", [header("h2", "/repo/old"), old])
    File.touch!(path, DateTime.to_unix(@since) - 1)

    ledger = read(dir)

    assert ledger.files == 1
    assert ledger.skipped_files == 0
    assert ledger.totals.input == 1
    assert ledger.totals.output == 1
    assert Map.keys(ledger.by_day) == ["2026-11-01"]
    assert Map.keys(ledger.sessions) == ["session00001"]
  end

  test ":cwd keeps one project and a relative path is invalid", %{tmp_dir: dir} do
    write(dir, "a", "session00001", [
      header("h1", "/repo/a"),
      assistant("m1", "h1", "2026-11-02T10:00:00Z", "a", usage(1, 1))
    ])

    write(dir, "b", "session00002", [
      header("h2", "/repo/b"),
      assistant("m2", "h2", "2026-11-02T10:00:00Z", "b", usage(2, 2))
    ])

    ledger = read(dir, cwd: "/repo/a")

    assert ledger.files == 1
    assert ledger.skipped_files == 0
    assert Map.keys(ledger.sessions) == ["session00001"]

    assert {:error, :invalid_cwd} =
             Ledger.read(dir, since: @since, until: @until, cwd: "relative")
  end

  test "a bad window is invalid", %{tmp_dir: dir} do
    assert {:error, :invalid_window} = Ledger.read(dir, since: @until, until: @since)
    assert {:error, :invalid_window} = Ledger.read(dir, since: @since)
    assert {:error, :invalid_window} = Ledger.read(dir, until: @until)
  end

  test "tool calls, errors, and wall times", %{tmp_dir: dir} do
    call1 = assistant_call("m1", "h1", "2026-11-02T10:00:00.000Z", "call_1", "bash")
    result1 = tool_result("m2", "m1", "2026-11-02T10:00:01.500Z", "call_1", "bash")
    result2 = tool_result("m3", "m2", "2026-11-02T10:00:02.000Z", "call_2", "bash", error: true)
    call3 = assistant_call("m4", "m3", "2026-11-02T10:00:05.000Z", "call_3", "bash")
    result3 = tool_result("m5", "m4", "2026-11-02T10:00:04.000Z", "call_3", "bash")

    write(dir, "p", "session00001", [
      header("h1", "/repo"),
      call1,
      result1,
      result2,
      call3,
      result3
    ])

    tool = read(dir).tools["bash"]

    assert tool.calls == 3
    assert tool.errors == 1
    assert tool.max == 1_500
    assert tool.buckets == %{11 => 1}
    assert Ledger.percentile(tool, 0.5) == 2_048
    assert Ledger.percentile(tool, 0.95) == 2_048
  end

  test "a result inside the window gets the time of a call before since", %{tmp_dir: dir} do
    call = assistant_call("m1", "h1", "2026-10-31T23:59:59.000Z", "call_1", "bash", usage(5, 5))
    result = tool_result("m2", "m1", "2026-11-01T00:00:01.000Z", "call_1", "bash")

    write(dir, "p", "session00001", [header("h1", "/repo"), call, result])

    ledger = read(dir)

    assert ledger.totals == %Totals{}
    assert ledger.tools["bash"].calls == 1
    assert ledger.tools["bash"].max == 2_000
  end

  test "a hook deny counts by point and answer and by tool", %{tmp_dir: dir} do
    hook = %{
      "type" => "hook",
      "id" => "e1",
      "parent_id" => "h1",
      "ts" => "2026-11-02T10:00:00Z",
      "point" => "before_tool",
      "turn_id" => "t1",
      "call_id" => "call_1",
      "hook" => "Helyx.Test.Hook",
      "answer" => "deny",
      "reason" => nil,
      "tool" => "bash",
      "arguments" => "{}",
      "arguments_cut" => false
    }

    bad = %{
      "type" => "hook",
      "id" => "e2",
      "parent_id" => "e1",
      "ts" => "2026-11-02T10:00:01Z",
      "point" => "before_tool",
      "answer" => "deny"
    }

    write(dir, "p", "session00001", [header("h1", "/repo"), hook, bad])

    ledger = read(dir)

    assert ledger.hooks == %{{"before_tool", "deny"} => 1}
    assert ledger.denies == %{"bash" => 1}
    assert ledger.skipped_entries == 1
  end

  test "a file with no header counts as a skipped file", %{tmp_dir: dir} do
    write(dir, "p", "session00001", [user("m1", nil, "2026-11-02T10:00:00Z", "hi")])

    ledger = read(dir)

    assert ledger.skipped_files == 1
    assert ledger.sessions == %{}
    assert ledger.torn == 0
    assert ledger.skipped_entries == 0
  end

  test "a torn line counts and the other entries count", %{tmp_dir: dir} do
    good = assistant("m1", "h1", "2026-11-02T10:00:00Z", "a", usage(1, 1))

    write_lines(dir, "p", "session00001", [
      JSON.encode!(header("h1", "/repo")),
      ~s({"torn),
      JSON.encode!(good)
    ])

    ledger = read(dir)

    assert ledger.torn == 1
    assert ledger.skipped_files == 0
    assert ledger.totals.input == 1
  end

  test "a bad ts and a message that Codec rejects are skipped entries", %{tmp_dir: dir} do
    bad_ts = user("m1", "h1", "nope", "hi")

    bad_message = %{
      "id" => "m2",
      "parent_id" => "m1",
      "ts" => "2026-11-02T10:00:01Z",
      "type" => "message",
      "role" => "bogus",
      "content" => [%{"type" => "text", "text" => "x"}]
    }

    good = assistant("m3", "m2", "2026-11-02T10:00:02Z", "a", usage(1, 1))

    write(dir, "p", "session00001", [header("h1", "/repo"), bad_ts, bad_message, good])

    ledger = read(dir)

    assert ledger.skipped_entries == 2
    assert ledger.totals.input == 1
  end

  test "max_files keeps the newest files and counts the rest", %{tmp_dir: dir} do
    for {id, offset} <- [{"session00001", 100}, {"session00002", 200}, {"session00003", 300}] do
      entry = assistant("m#{id}", "h#{id}", "2026-11-02T10:00:00Z", "x", usage(1, 1))

      path =
        write(dir, "p", id, [
          header("h#{id}", "/repo"),
          entry
        ])

      File.touch!(path, DateTime.to_unix(@since) + offset)
    end

    ledger = read(dir, max_files: 2)

    assert ledger.files == 2
    assert ledger.skipped_files == 1
    assert Enum.sort(Map.keys(ledger.sessions)) == ["session00002", "session00003"]
  end

  test "a child session under .children is read with its parent", %{tmp_dir: dir} do
    write(dir, ".children", "session00003", [
      header("h1", "/repo", parent: "parent000001"),
      assistant("m1", "h1", "2026-11-02T10:00:00Z", "a", usage(1, 1))
    ])

    ledger = read(dir)

    assert ledger.files == 1
    assert ledger.sessions["session00003"].parent == "parent000001"
  end

  test "the histogram buckets the edges and keeps the exact max", %{tmp_dir: dir} do
    base = ~U[2026-11-02 10:00:00Z]
    tall = Integer.pow(2, 40)

    entries =
      [0, 1, 2, tall, tall + 1]
      |> Enum.with_index()
      |> Enum.flat_map(fn {wall, index} ->
        at = base |> DateTime.add(wall, :millisecond) |> DateTime.to_iso8601()

        [
          assistant_call("c#{index}", "h1", DateTime.to_iso8601(base), "call_#{index}", "bash"),
          tool_result("r#{index}", "c#{index}", at, "call_#{index}", "bash")
        ]
      end)

    write(dir, "p", "session00001", [header("h1", "/repo") | entries])

    {:ok, ledger} =
      Ledger.read(dir, since: ~U[2026-01-01 00:00:00Z], until: ~U[2100-01-01 00:00:00Z])

    tool = ledger.tools["bash"]

    assert tool.buckets == %{0 => 1, 1 => 1, 2 => 1, 40 => 2}
    assert tool.max == tall + 1
    assert Ledger.percentile(tool, 0.5) == 4
    assert Ledger.percentile(tool, 0.95) == tall + 1
  end
end
