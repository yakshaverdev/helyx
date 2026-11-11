defmodule Helyx.Session.File.UIBlocksCodecTest do
  # The UI blocks of a tool result on a read of the session file
  # (docs/features/ui-blocks.md, "In a tool result"): the reader keeps the
  # first 8 blocks, drops each that fails the check, cuts each over the
  # bound, and drops a `ui_blocks` that is not a list or that is on a
  # message that is not a tool result. It logs each drop; the message stays.
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Helyx.{Message, Session}
  alias Helyx.Test.SessionFile

  @moduletag :tmp_dir

  defp block(i), do: %{"kind" => "progress", "text" => "b#{i}"}

  defp entry(id, role, ui_blocks) do
    base = %{
      "id" => id,
      "type" => "message",
      "role" => role,
      "content" => [%{"type" => "text", "text" => "t"}]
    }

    base = if role == "user", do: Map.put(base, "origin", %{"kind" => "user", "id" => nil}), else: base

    extra =
      if role == "tool_result",
        do: %{"tool_call_id" => "c1", "tool_name" => "bash", "is_error" => false},
        else: %{}

    base |> Map.merge(extra) |> Map.put("ui_blocks", ui_blocks)
  end

  # A file with the entries in one chain, read back: the messages and the log.
  defp read(dir, entries) do
    {:ok, file} = Session.File.create(dir, "sess00000001", "/repo", "test/ok")

    _last =
      Enum.reduce(entries, file.leaf, fn entry, parent ->
        line = JSON.encode!(Map.put(entry, "parent_id", parent))
        File.write!(file.path, line <> "\n", [:append])
        entry["id"]
      end)

    {result, log} = with_log(fn -> SessionFile.resume(dir, "/repo") end)
    assert {:ok, %{messages: messages}} = result
    {messages, log}
  end

  test "the blocks that a session writes read back", %{tmp_dir: dir} do
    call = %Message.ToolCall{id: "c1", name: "bash", arguments: %{}}
    blocks = [block(1), Map.put(block(2), "n", 10 ** 100 - 1)]
    message = %{Message.tool_result(call, {:ok, "done"}) | ui_blocks: blocks}
    plain = Message.tool_result(call, {:ok, "plain"})

    {:ok, file} = Session.File.create(dir, "sess00000001", "/repo", "test/ok")
    file |> SessionFile.append_message(message) |> SessionFile.append_message(plain)

    assert {:ok, %{messages: [read, read_plain]}} = SessionFile.resume(dir, "/repo")
    assert read.ui_blocks == blocks
    assert read_plain.ui_blocks == []
    refute File.read!(file.path) =~ ~s("ui_blocks":[])
  end

  test "an integer of 100 digits in a block reads; 101 digits drops the block", %{tmp_dir: dir} do
    max = Map.put(block(1), "n", [%{"deep" => 10 ** 100 - 1}])
    big = Map.put(block(2), "n", [%{"deep" => 10 ** 100}])

    {[message], log} = read(dir, [entry("toolresult01", "tool_result", [max, big, block(3)])])

    assert message.ui_blocks == [max, block(3)]
    assert Message.text(message) == "t"
    assert log =~ "dropped a UI block that fails the check"
  end

  test "8 blocks read; past 8 the rest is dropped", %{tmp_dir: dir} do
    eight = Enum.map(1..8, &block/1)
    nine = Enum.map(1..9, &block/1)

    {[m8, m9], log} =
      read(dir, [
        entry("toolresult01", "tool_result", eight),
        entry("toolresult02", "tool_result", nine)
      ])

    assert m8.ui_blocks == eight
    assert m9.ui_blocks == eight
    assert log =~ "dropped 1 UI blocks past the count"
    assert length(String.split(log, "past the count")) == 2
  end

  test "a block that fails the check drops alone; one over the bound is cut", %{tmp_dir: dir} do
    bad = [%{"kind" => "A", "text" => ""}, %{"text" => "no kind"}, "text", 1]
    huge = %{"kind" => "table", "text" => String.duplicate("x", 70_000)}

    {[message], log} =
      read(dir, [entry("toolresult01", "tool_result", bad ++ [block(1), huge])])

    assert [block1, cut] = message.ui_blocks
    assert block1 == block(1)
    assert %{"kind" => "table", "cut" => true} = cut
    assert map_size(cut) == 3
    assert byte_size(JSON.encode!(cut)) <= Helyx.UIBlock.max_bytes()
    assert length(String.split(log, "fails the check")) == 5
  end

  test "a ui_blocks that is not a list, or on another role, drops whole", %{tmp_dir: dir} do
    {messages, log} =
      read(dir, [
        entry("toolresult01", "tool_result", block(1)),
        entry("usermessage1", "user", [block(1)]),
        entry("assistant001", "assistant", [block(1)]),
        entry("toolresult02", "tool_result", [])
      ])

    assert [%{role: :tool_result}, %{role: :user}, %{role: :assistant}, %{role: :tool_result}] =
             messages

    assert Enum.map(messages, & &1.ui_blocks) == [[], [], [], []]
    assert Enum.map(messages, &Message.text/1) == ["t", "t", "t", "t"]
    assert length(String.split(log, "not a list of a tool result")) == 4
  end
end
