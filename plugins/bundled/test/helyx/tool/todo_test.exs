defmodule Helyx.Tool.TodoTest do
  # The todo tool: the result text and its block, the checks of the arguments
  # at their bounds, and the block within the bound of a UI block
  # (docs/features/todo-tool.md).
  use ExUnit.Case, async: true

  alias Helyx.Tool.Todo

  defp item(text, status \\ "pending"), do: %{"text" => text, "status" => status}

  defp run(items), do: Todo.run(%{"items" => items}, ".")

  test "a list of one item of each status gives its text and its block, exactly" do
    items = [
      item("Read the brief", "done"),
      item("Write the tool", "in_progress"),
      item("Run the tests")
    ]

    assert {:ok, text, [block]} = run(items)

    assert text ==
             "[x] Read the brief\n[>] Write the tool\n[ ] Run the tests\n1/3 done"

    assert block == %{"kind" => "todo", "text" => text, "items" => items}
  end

  test "1 item and max_items() items pass, and an empty or a longer list fails" do
    assert {:ok, "[ ] One\n0/1 done", [block]} = run([item("One")])
    assert block["items"] == [item("One")]

    most = for n <- 1..Todo.max_items(), do: item("Step #{n}")
    assert {:ok, _text, [_block]} = run(most)

    assert {:error, empty} = run([])
    assert empty =~ "items must be a list of 1 to #{Todo.max_items()} items"

    assert {:error, over} = run(most ++ [item("One more")])
    assert over =~ "items must be a list of 1 to #{Todo.max_items()} items"
  end

  test "an item of max_item_bytes() bytes of multibyte text passes, and one byte more fails" do
    # Two bytes a character, so half the bound is a whole character.
    most = String.duplicate("é", div(Todo.max_item_bytes(), 2))
    assert byte_size(most) == Todo.max_item_bytes()
    assert {:ok, _text, [_block]} = run([item(most)])

    assert {:error, over} = run([item(most <> "a")])
    assert over =~ "items[0].text must be a string of 1 to #{Todo.max_item_bytes()} bytes"
  end

  test "an empty text fails" do
    assert {:error, text} = run([item("")])
    assert text =~ "items[0].text must be a string of 1 to #{Todo.max_item_bytes()} bytes"
  end

  test "a text with a new line fails" do
    for bad <- ["one\ntwo", "one\r\ntwo"] do
      assert {:error, text} = run([item(bad)])
      assert text == "items[0].text must hold no new line"
    end
  end

  test "two items in progress fail" do
    items = [item("One", "in_progress"), item("Two", "in_progress")]
    assert run(items) == {:error, "items: at most one item is in_progress"}
  end

  test "an unknown status and an unknown key fail" do
    assert {:error, status} = run([item("One", "finished")])
    assert status =~ "items[0].status must be one of pending, in_progress, done"

    assert run([Map.put(item("One"), "note", "later")]) ==
             {:error, "items[0]: an item holds only text and status"}
  end

  test "the block passes the check of a UI block unchanged at the largest list" do
    items =
      for n <- 1..Todo.max_items() do
        status = if n == 25, do: "in_progress", else: "done"
        item(String.duplicate("a", Todo.max_item_bytes()), status)
      end

    assert {:ok, text, [block]} = run(items)
    assert Helyx.UIBlock.check(block) == {:ok, block}
    assert byte_size(JSON.encode!(block)) < Helyx.UIBlock.max_bytes()
    assert text =~ "#{Todo.max_items() - 1}/#{Todo.max_items()} done"
  end
end
