defmodule Mix.Tasks.Helyx.StatsTest do
  # Not async: the sessions directory is application env.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    Application.put_env(:coding_agent, :sessions_dir, dir)
    on_exit(fn -> Application.delete_env(:coding_agent, :sessions_dir) end)
    :ok
  end

  defp session(dir) do
    now = DateTime.utc_now()
    ts = now |> DateTime.add(-3_600, :second) |> DateTime.to_iso8601()

    header = %{
      "id" => "h1",
      "parent_id" => nil,
      "ts" => ts,
      "type" => "session",
      "version" => 1,
      "cwd" => dir,
      "model" => "m/x"
    }

    message = %{
      "id" => "m1",
      "parent_id" => "h1",
      "ts" => ts,
      "type" => "message",
      "role" => "assistant",
      "model" => "m/x",
      "stop_reason" => "end_turn",
      "usage" => %{"input" => 10, "output" => 5, "cache_read" => 0, "cache_write" => 0},
      "content" => [%{"type" => "text", "text" => "hi"}]
    }

    path = Path.join([dir, "p", "session00001.jsonl"])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, JSON.encode!(header) <> "\n" <> JSON.encode!(message) <> "\n")
    path
  end

  defp error(args) do
    stderr =
      capture_io(:stderr, fn ->
        assert catch_exit(Mix.Tasks.Helyx.Stats.run(args)) == {:shutdown, 1}
      end)

    String.trim(stderr)
  end

  test "prints a text report for the default window", %{tmp_dir: dir} do
    session(dir)
    output = capture_io(fn -> Mix.Tasks.Helyx.Stats.run([]) end)

    assert output =~ "Totals"
    assert output =~ "tokens in"
    assert output =~ "10"
  end

  test "--json prints JSON", %{tmp_dir: dir} do
    session(dir)
    output = capture_io(fn -> Mix.Tasks.Helyx.Stats.run(["--json"]) end)

    assert JSON.decode!(output)["totals"]["input"] == 10
  end

  test "--days with --since is an error" do
    assert error(["--days", "7", "--since", "2026-01-01"]) ==
             "helyx.stats: use either --days or --since, not both"
  end

  test "--days outside 1 to 3650 is an error" do
    assert error(["--days", "0"]) == "helyx.stats: --days must be between 1 and 3650"
    assert error(["--days", "3651"]) == "helyx.stats: --days must be between 1 and 3650"
  end

  test "a date that does not parse is an error" do
    assert error(["--since", "nope"]) == "helyx.stats: invalid date for --since: nope"
    assert error(["--until", "2026-13-01"]) == "helyx.stats: invalid date for --until: 2026-13-01"
  end

  test "an unknown switch is an error" do
    assert error(["--bogus"]) == "helyx.stats: unknown switch --bogus"
  end

  test "an extra argument is an error" do
    assert error(["extra"]) == "helyx.stats: unexpected argument extra"
  end

  test "an empty window is an error" do
    assert error(["--since", "2026-02-02", "--until", "2026-02-01"]) ==
             "helyx.stats: the window is empty: since must be before until"
  end
end
