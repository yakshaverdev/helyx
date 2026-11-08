defmodule Helyx.TUI.Wire.UIBlocks do
  @moduledoc false
  # The UI blocks of the wire as Core values (`docs/features/wire-protocol.md`,
  # `docs/features/ui-blocks.md`), for `Helyx.TUI.Wire.Decode`. A block is
  # checked as Core admits it: the envelope, a JSON object of at most
  # 65,536 bytes of JSON, and integers of at most 100 digits
  # (`Helyx.UIBlock.check/1`). The kind is not read for its meaning: a kind
  # that the client does not know passes, and the view shows its text. A
  # broken value raises, as in the decoder.

  alias Helyx.UIBlock

  @max_result_blocks UIBlock.max_result_blocks()

  # The `ui_blocks` of a message: only a tool result has them, at most
  # 8 (`Helyx.UIBlock.max_result_blocks/0`). A missing key is no blocks.
  def message!(:tool_result, blocks)
      when is_list(blocks) and length(blocks) <= @max_result_blocks,
      do: Enum.map(blocks, &block!/1)

  def message!(_role, nil), do: []

  # The data of a `ui_block` event, and an item of the snapshot `ui_blocks`.
  def shown!(%{"call_id" => call_id, "key" => key, "block" => block})
      when is_binary(call_id) or is_nil(call_id) do
    true = UIBlock.key?(key)
    %{call_id: call_id, key: key, block: block!(block)}
  end

  # The request of an ask: one with a kind is an input UI block, so its
  # envelope is checked; its size is the ask bound of Core.
  def request!(%{"kind" => _kind} = request) do
    true = UIBlock.envelope?(request)
    request
  end

  def request!(request), do: request

  # A block within the bound comes back as it is; Core cut a block over it.
  defp block!(block) do
    {:ok, ^block} = UIBlock.check(block)
    block
  end
end
