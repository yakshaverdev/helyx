defmodule Helyx.TUI.ViewModel.Cut do
  @moduledoc false
  # The blocks of a message that its cell keeps (`docs/features/tui-attach.md`,
  # row "a value of the schema past the bounds of Core"): the first 1,024,
  # the count that Core makes, and in place of the others one cut, which the
  # transcript draws as `[+N more blocks]`. A tool call past them is not
  # counted: it has a tool cell of its own. The cut walks the message once,
  # when it becomes a cell, so no frame walks more than 1,025 blocks.

  alias Helyx.Message

  @max_blocks Helyx.Session.Turn.max_message_blocks()

  @enforce_keys [:more]
  defstruct [:more]

  @type t :: %__MODULE__{more: pos_integer()}

  @spec message(Message.t()) :: Message.t()
  def message(%Message{content: content} = message) do
    case Enum.drop(content, @max_blocks) do
      [] -> message
      rest -> %{message | content: Enum.take(content, @max_blocks) ++ cut(rest)}
    end
  end

  defp cut(rest) do
    case Enum.count(rest, &(not is_struct(&1, Message.ToolCall))) do
      0 -> []
      more -> [%__MODULE__{more: more}]
    end
  end

  @spec text(t()) :: String.t()
  def text(%__MODULE__{more: more}), do: "[+#{more} more blocks]"
end
