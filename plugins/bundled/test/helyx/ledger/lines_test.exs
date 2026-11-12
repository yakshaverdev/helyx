defmodule Helyx.Ledger.LinesTest do
  use ExUnit.Case, async: true

  alias Helyx.Ledger.Lines

  @moduletag :tmp_dir

  defp fold(path, fun, opts \\ []) do
    case Lines.fold(path, [], fun, opts) do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end

  defp write(dir, text) do
    path = Path.join(dir, "session.jsonl")
    File.write!(path, text)
    path
  end

  defp line_of(size) do
    base = JSON.encode!(%{"type" => "x", "pad" => ""})
    pad = String.duplicate("a", size - byte_size(base))
    JSON.encode!(%{"type" => "x", "pad" => pad})
  end

  test "reads a line that spans a chunk edge", %{tmp_dir: dir} do
    big = String.duplicate("a", 1_200_000)

    text =
      JSON.encode!(%{"type" => "x", "pad" => big}) <>
        "\n" <> JSON.encode!(%{"type" => "x", "pad" => "tail"}) <> "\n"

    assert {:ok, [{:entry, %{"pad" => first}}, {:entry, %{"pad" => "tail"}}]} =
             fold(write(dir, text), &[&1 | &2])

    assert byte_size(first) == 1_200_000
  end

  test "reads a file with no final newline", %{tmp_dir: dir} do
    path = write(dir, JSON.encode!(%{"type" => "x"}))
    assert {:ok, [{:entry, %{"type" => "x"}}]} = fold(path, &[&1 | &2])
  end

  test "reads an empty file", %{tmp_dir: dir} do
    assert {:ok, []} = fold(write(dir, ""), &[&1 | &2])
  end

  test "a line at the limit is read, one under is skipped, one over is read", %{tmp_dir: dir} do
    line = line_of(100)
    short = JSON.encode!(%{"type" => "x"})
    text = line <> "\n" <> short <> "\n"

    assert {:ok, [{:entry, _}, {:entry, _}]} =
             fold(write(dir, text), &[&1 | &2], max_line_bytes: 100)

    assert {:ok, [{:skip, :too_large}, {:entry, _}]} =
             fold(write(dir, text), &[&1 | &2], max_line_bytes: 99)

    assert {:ok, [{:entry, _}, {:entry, _}]} =
             fold(write(dir, text), &[&1 | &2], max_line_bytes: 101)
  end

  test "a partial line over the limit ends the read", %{tmp_dir: dir} do
    short = JSON.encode!(%{"type" => "x"})

    assert {:ok, [{:entry, _}, {:skip, :too_large}]} =
             fold(write(dir, short <> "\n" <> line_of(120)), &[&1 | &2], max_line_bytes: 100)
  end

  test "a missing file is an error", %{tmp_dir: dir} do
    assert {:error, :enoent} =
             Lines.fold(Path.join(dir, "missing.jsonl"), [], fn _item, acc -> acc end)
  end
end
