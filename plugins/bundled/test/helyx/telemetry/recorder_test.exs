defmodule Helyx.Telemetry.RecorderTest do
  # Not async: a telemetry handler is global and the recorder writes a file.
  use ExUnit.Case, async: false

  @moduletag :tmp_dir

  alias Helyx.Telemetry.Recorder

  @event [:helyx, :provider, :attempt]
  @max_bytes 4_096

  # The recorder runs under a name of its own, so a test never meets the
  # recorder of another one or the default name of a product.
  defp start do
    name = :"recorder_#{System.unique_integer([:positive])}"
    start_supervised!({Recorder, name: name})
    name
  end

  defp metadata do
    %{
      provider: "opencode-go",
      model: "kimi-k2",
      attempt: 0,
      status: 429,
      error: nil,
      decision: :wait,
      wait_ms: 1
    }
  end

  defp emit(name), do: Recorder.handle_event(@event, %{duration: 1}, metadata(), %{server: name})

  defp lines(path) do
    path |> File.read!() |> String.split("\n", trim: true)
  end

  test "line/3 is one JSON object with the event, the time, the duration, and the contract keys" do
    duration = System.convert_time_unit(3, :millisecond, :native)
    # A key outside the contract does not reach the line.
    metadata = Map.put(metadata(), :prompt, "secret content")
    line = IO.iodata_to_binary(Recorder.line(@event, %{duration: duration}, metadata))

    assert String.ends_with?(line, "\n")
    assert String.split(line, "\n", trim: true) == [String.trim_trailing(line, "\n")]

    json = JSON.decode!(line)
    assert json["event"] == "helyx.provider.attempt"
    assert json["ms"] == 3
    assert json["ts"] =~ ~r/\A\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z\z/
    assert json["provider"] == "opencode-go"
    assert json["model"] == "kimi-k2"
    assert json["attempt"] == 0
    assert json["status"] == 429
    assert json["decision"] == "wait"
    assert json["wait_ms"] == 1
    refute Map.has_key?(json, "prompt")
    # Nil is JSON null, and the key is there.
    assert Map.has_key?(json, "error")
    assert json["error"] == nil
  end

  test "the line holds a nil status as null, and no ms for a measurement that is not a duration" do
    json =
      @event
      |> Recorder.line(%{}, %{metadata() | status: nil, wait_ms: nil})
      |> IO.iodata_to_binary()
      |> JSON.decode!()

    assert Map.has_key?(json, "status")
    assert json["status"] == nil
    assert json["wait_ms"] == nil
    refute Map.has_key?(json, "ms")
  end

  test "open, then one line for each event", %{tmp_dir: dir} do
    name = start()
    path = Path.join(dir, "telemetry.jsonl")

    assert Recorder.path(name) == nil
    assert Recorder.open(name, path, @max_bytes) == :ok
    assert Recorder.path(name) == path

    for _ <- 1..3, do: :telemetry.execute(@event, %{duration: 1}, metadata())

    assert [_, _, _] = lines(path)

    for line <- lines(path),
        do: assert(%{"event" => "helyx.provider.attempt"} = JSON.decode!(line))

    assert Recorder.path(name) == path
  end

  test "a closed recorder drops the event and returns :ok", %{tmp_dir: dir} do
    name = start()
    path = Path.join(dir, "telemetry.jsonl")

    # Before open: nothing to write, and no file.
    assert emit(name) == :ok
    assert :ok = :telemetry.execute(@event, %{duration: 1}, metadata())
    refute File.exists?(path)

    assert Recorder.open(name, path, @max_bytes) == :ok
    assert Recorder.close(name) == :ok
    assert Recorder.path(name) == nil
    size = File.stat!(path).size

    # After close: the handler stays, and the line is dropped.
    assert emit(name) == :ok
    assert :ok = :telemetry.execute(@event, %{duration: 1}, metadata())
    assert File.stat!(path).size == size
  end

  test "a rotation keeps one older file, and the second replaces it", %{tmp_dir: dir} do
    name = start()
    path = Path.join(dir, "telemetry.jsonl")
    older = path <> ".0"
    assert Recorder.open(name, path, @max_bytes) == :ok

    # Enough lines to pass the cap, so that a rotation happens.
    per_file =
      div(@max_bytes, Recorder.line(@event, %{duration: 1}, metadata()) |> IO.iodata_length())

    assert per_file > 1
    for _ <- 1..(per_file * 3), do: :telemetry.execute(@event, %{duration: 1}, metadata())

    assert File.stat!(path).size <= @max_bytes
    assert File.exists?(older)
    assert File.stat!(older).size <= @max_bytes
    assert [_ | _] = lines(older)
    for line <- lines(path) ++ lines(older), do: assert(%{} = JSON.decode!(line))

    first = File.stat!(older).inode
    for _ <- 1..per_file, do: :telemetry.execute(@event, %{duration: 1}, metadata())

    # The rename replaced the older file.
    assert File.stat!(older).inode != first
    assert File.stat!(path).size <= @max_bytes
    assert [_ | _] = lines(path)
    assert [_ | _] = lines(older)
  end

  test "open refuses a folder, a relative path, and a cap out of range", %{tmp_dir: dir} do
    name = start()
    folder = Path.join(dir, "folder")
    File.mkdir_p!(folder)
    path = Path.join(dir, "telemetry.jsonl")

    assert Recorder.open(name, folder, @max_bytes) == {:error, :not_regular}
    assert Recorder.open(name, "relative/telemetry.jsonl", @max_bytes) == {:error, :einval}
    assert Recorder.open(name, path, @max_bytes - 1) == {:error, :einval}
    assert Recorder.open(name, path, 1_073_741_825) == {:error, :einval}
    assert Recorder.path(name) == nil

    assert Recorder.open(name, path, @max_bytes) == :ok
    assert Recorder.path(name) == path
  end

  test "a handler whose recorder is not running returns :ok" do
    name = :"gone_#{System.unique_integer([:positive])}"
    refute Process.whereis(name)
    assert emit(name) == :ok
  end

  # A write that fails must not raise: :telemetry detaches a handler that
  # raises. Filling the file to the cap and then removing its folder makes
  # the next line rotate, and the file that the rotation makes fails.
  @tag capture_log: true
  test "the handler stays attached after a write error", %{tmp_dir: dir} do
    name = start()
    path = Path.join(dir, "telemetry.jsonl")
    assert Recorder.open(name, path, @max_bytes) == :ok

    bytes = Recorder.line(@event, %{duration: 1}, metadata()) |> IO.iodata_length()
    for _ <- 1..div(@max_bytes, bytes), do: :telemetry.execute(@event, %{duration: 1}, metadata())
    File.rm_rf!(dir)

    assert :ok = :telemetry.execute(@event, %{duration: 1}, metadata())
    assert emit(name) == :ok
    assert Enum.any?(:telemetry.list_handlers(@event), &(&1.id == {Recorder, name}))
    assert Recorder.path(name) == nil
  end
end
