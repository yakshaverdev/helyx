defmodule Helyx.Tool.Todo do
  @moduledoc """
  Writes the plan of the current task as a checklist, for the user and for
  the model (`docs/features/todo-tool.md`).

  The result text is one line for each item, `[x]` for done, `[>]` for in
  progress, and `[ ]` for pending, then a line with the count of the done
  items. The result carries the same lines in a `todo` UI block, which every
  client shows under the call (`docs/features/ui-blocks.md`, "The
  vocabulary").

  The tool holds no state: each call sends the whole list and replaces the
  list before, so a client that joins later reads the newest `todo` result.
  """

  @behaviour Helyx.Tool

  alias Helyx.Tool.Args

  @statuses ~w(pending in_progress done)
  # The most items of one plan, and the most bytes of one item. A longer
  # plan does not help the user at a glance, and a plan item is one short
  # line. At both bounds the block takes about four fifths of
  # `Helyx.UIBlock.max_bytes/0`, because it holds the result text and the
  # items.
  @max_items 50
  @max_item_bytes 500

  @doc "The most items of one plan."
  @spec max_items() :: pos_integer()
  def max_items, do: @max_items

  @doc "The most bytes of the text of one item."
  @spec max_item_bytes() :: pos_integer()
  def max_item_bytes, do: @max_item_bytes

  @impl true
  def name, do: "todo"

  @impl true
  def description do
    "Write the plan of the current task as a checklist. Send the whole list each time; " <>
      "it replaces the list before. Mark one item in_progress while you work on it, and " <>
      "mark items done as soon as they are done. Use it for a task of three or more steps."
  end

  @impl true
  def concurrent?, do: true

  @impl true
  def parameters do
    item = %{
      "type" => "object",
      "properties" => %{
        "text" => %{
          "type" => "string",
          "minLength" => 1,
          "maxLength" => @max_item_bytes,
          "description" => "The item, 1 to #{@max_item_bytes} bytes on one line"
        },
        "status" => %{
          "type" => "string",
          "enum" => @statuses,
          "description" => "pending, in_progress, or done"
        }
      },
      "required" => ["text", "status"]
    }

    %{
      "type" => "object",
      "properties" => %{
        "items" => %{
          "type" => "array",
          "items" => item,
          "minItems" => 1,
          "maxItems" => @max_items
        }
      },
      "required" => ["items"]
    }
  end

  @impl true
  def run(args, _cwd) do
    with {:ok, args} <- Args.check(args, parameters()),
         {:ok, items} <- checked(args["items"]) do
      plan = text(items)
      {:ok, plan, [%{"kind" => "todo", "text" => plan, "items" => items}]}
    end
  end

  # The rules that the schema cannot state, in the order of the items: an
  # item of exactly its two keys, and a text of one line. The block shows a
  # line for each item, so a new line in a text breaks its format.
  defp checked(items) do
    with :ok <- each(items, 0), do: progress(items)
  end

  defp each([], _n), do: :ok

  defp each([item | rest], n) do
    with :ok <- keys(item, n),
         :ok <- one_line(item["text"], n),
         do: each(rest, n + 1)
  end

  defp keys(item, n) do
    if Enum.sort(Map.keys(item)) == ["status", "text"],
      do: :ok,
      else: {:error, "items[#{n}]: an item holds only text and status"}
  end

  defp one_line(text, n) do
    if String.contains?(text, ["\n", "\r"]),
      do: {:error, "items[#{n}].text must hold no new line"},
      else: :ok
  end

  # The user reads one item as the current one, so the plan marks one.
  defp progress(items) do
    if Enum.count(items, &(&1["status"] == "in_progress")) > 1,
      do: {:error, "items: at most one item is in_progress"},
      else: {:ok, items}
  end

  # The model reads the same lines that the block shows.
  defp text(items) do
    done = Enum.count(items, &(&1["status"] == "done"))
    lines = Enum.map(items, &"#{mark(&1["status"])} #{&1["text"]}")
    Enum.join(lines ++ ["#{done}/#{length(items)} done"], "\n")
  end

  defp mark("done"), do: "[x]"
  defp mark("in_progress"), do: "[>]"
  defp mark("pending"), do: "[ ]"
end
