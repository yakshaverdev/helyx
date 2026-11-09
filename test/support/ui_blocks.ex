# Test tools of UI blocks (docs/features/ui-blocks.md), for the session
# tests of UI blocks and of the hooks with UI blocks.

defmodule Helyx.Test.UIBlocks.Result do
  @moduledoc false
  # Returns the UI blocks that its "mode" names: "n.<k>", k small blocks;
  # "max" and "big", one block with an integer of 100 or 101 digits; "huge",
  # one block over the byte bound; "error", an error result with one block;
  # "none", an empty list.
  use Helyx.Test.Tool, name: "result", description: "Returns UI blocks."

  def block(i), do: %{"kind" => "progress", "text" => "b#{i}", "i" => i}

  @impl true
  def run(%{"mode" => "n." <> k}, _cwd),
    do: {:ok, "r", Enum.map(1..String.to_integer(k), &block/1)}

  def run(%{"mode" => "max"}, _cwd), do: {:ok, "r", [Map.put(block(1), "n", 10 ** 100 - 1)]}
  def run(%{"mode" => "big"}, _cwd), do: {:ok, "r", [Map.put(block(1), "n", 10 ** 100)]}

  def run(%{"mode" => "huge"}, _cwd),
    do: {:ok, "r", [%{"kind" => "table", "text" => String.duplicate("x", 70_000)}]}

  def run(%{"mode" => "error"}, _cwd), do: {:error, "e", [block(1)]}
  def run(%{"mode" => "none"}, _cwd), do: {:ok, "r", []}
end

defmodule Helyx.Test.UIBlocks.Show do
  @moduledoc false
  # Shows a block for each [key, spec] of "shows" with `Helyx.Tool.show/2`,
  # then, with "gate", waits for the gate (`Helyx.Test.Gate`), then shows
  # each of "after", then each of "child" from a process that it starts
  # with its call context. Gives the inspected replies, joined with ",",
  # and with "result", that one block in its result. A spec is "max" or "big" for a
  # block with an integer of 100 or 101 digits, "huge" for a block over the
  # byte bound, and any other text for a block with that text.
  use Helyx.Test.Tool, name: "show", description: "Shows UI blocks."

  def block("max"), do: %{"kind" => "progress", "text" => "max", "n" => 10 ** 100 - 1}
  def block("big"), do: %{"kind" => "progress", "text" => "big", "n" => 10 ** 100}
  def block("huge"), do: %{"kind" => "table", "text" => String.duplicate("x", 70_000)}
  def block(text), do: %{"kind" => "progress", "text" => text}

  @impl true
  def run(%{"shows" => shows} = args, _cwd) do
    replies = for [key, spec] <- shows, do: Helyx.Tool.show(key, block(spec))
    with %{"gate" => gate} <- args, do: {:ok, "done"} = Helyx.Test.Gate.wait(gate)
    later = for [key, spec] <- Map.get(args, "after", []), do: Helyx.Tool.show(key, block(spec))
    context = Process.get(:helyx_call)

    child =
      for [key, spec] <- Map.get(args, "child", []) do
        Task.await(
          Task.async(fn ->
            Process.put(:helyx_call, context)
            Helyx.Tool.show(key, block(spec))
          end)
        )
      end

    text = Enum.map_join(replies ++ later ++ child, ",", &inspect/1)

    case args do
      %{"result" => spec} -> {:ok, text, [block(spec)]}
      _none -> {:ok, text}
    end
  end
end

defmodule Helyx.Test.UIBlocks.Background do
  @moduledoc false
  # A background run: takes a place, answers "started", shows a block, waits
  # for the gate in "gate", then ends with a text that holds the reply of
  # the show and one UI block.
  use Helyx.Test.Tool, name: "bg_blocks", description: "Runs in the background."

  def block, do: %{"kind" => "progress", "text" => "end"}

  @impl true
  def run(%{"gate" => gate}, _cwd) do
    {:ok, _place} = Helyx.Tool.background()
    :ok = Helyx.Tool.started("started")
    shown = Helyx.Tool.show("k", block())
    {:ok, "done"} = Helyx.Test.Gate.wait(gate)
    {:ok, "finished " <> inspect(shown), [block()]}
  end
end

defmodule Helyx.Test.UIBlocks.Asker do
  @moduledoc false
  # Asks the clients with the request in "request" (`Helyx.Tool.ask/1`),
  # after the gate in "gate" when it has one, and gives the inspected reply.
  use Helyx.Test.Tool, name: "asker", description: "Asks the clients."

  @impl true
  def run(%{"request" => request} = args, _cwd) do
    with %{"gate" => gate} <- args, do: {:ok, "done"} = Helyx.Test.Gate.wait(gate)
    {:ok, inspect(Helyx.Tool.ask(request))}
  end
end
