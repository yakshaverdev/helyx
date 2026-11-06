defmodule Helyx.TUI.ViewModel.UIBlocks do
  @moduledoc false
  # The UI blocks of the running turn in `Helyx.TUI.ViewModel`, and where
  # the transcript shows them (`docs/features/ui-blocks.md`, "Rendering in
  # the TUI"). The list holds the data of each `:ui_block` event, `%{call_id,
  # key, block}`, in the order of the first event of each pair of call id and
  # key; Core sends at most 8 keys for each call and 8 with call id nil, and
  # at most 8 calls run at once, so the list stays short.

  alias Helyx.TUI.{Question, ViewModel}

  @type shown :: Helyx.Session.Snapshot.ui_block()

  @typedoc """
  Where the blocks show: under the open tool cell at a cell position, under
  a tool call of the streaming message by its call id, and at the end of
  the turn.
  """
  @type placed :: %{
          cells: %{non_neg_integer() => [map()]},
          calls: %{String.t() => [map()]},
          turn: [map()]
        }

  # A later block with the same call id and key replaces the earlier one in
  # its place.
  @spec put([shown()], shown()) :: [shown()]
  def put(shown, %{call_id: id, key: key, block: _block} = data) do
    case Enum.find_index(shown, &(&1.call_id == id and &1.key == key)) do
      nil -> shown ++ [data]
      at -> List.replace_at(shown, at, data)
    end
  end

  # The result of a call drops its blocks.
  @spec drop_call([shown()], String.t()) :: [shown()]
  def drop_call(shown, id), do: Enum.reject(shown, &(&1.call_id == id))

  # The blocks of a call show under its oldest open cell, which its result
  # closes, or under its call in the streaming message. An ask of a kind
  # that the TUI does not render shows its request as a block of its call:
  # its text, and no answer. A block with call id nil, or of a call that
  # the transcript does not show, shows at the end of the turn.
  @spec placed(ViewModel.t()) :: placed()
  def placed(%ViewModel{ui_blocks: shown, asks: asks, open: open, streaming: streaming}) do
    fallback = for ask <- asks, unknown?(ask), do: %{call_id: ask.call_id, block: ask.request}

    streamed =
      for {:tool, call, _line, _result} <- streaming || [], into: MapSet.new(), do: call.id

    empty = %{cells: %{}, calls: %{}, turn: []}

    # Newest first, so each block goes to the head of its list in order.
    (shown ++ fallback)
    |> Enum.reverse()
    |> Enum.reduce(empty, fn %{call_id: id, block: block}, placed ->
      cond do
        id == nil -> %{placed | turn: [block | placed.turn]}
        Map.has_key?(open, id) -> add(placed, :cells, oldest(open, id), block)
        MapSet.member?(streamed, id) -> add(placed, :calls, id, block)
        true -> %{placed | turn: [block | placed.turn]}
      end
    end)
  end

  defp unknown?(%{request: %{"kind" => _}} = ask), do: not Question.picker?(ask)
  defp unknown?(_ask), do: false

  defp oldest(open, id) do
    {:value, at} = :queue.peek(Map.fetch!(open, id))
    at
  end

  defp add(placed, field, at, block),
    do:
      Map.update!(placed, field, &Map.update(&1, at, [block], fn blocks -> [block | blocks] end))
end
