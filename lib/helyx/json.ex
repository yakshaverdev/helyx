defmodule Helyx.JSON do
  @moduledoc false
  # The JSON decode of every boundary. `JSON.decode/1` raises
  # `SystemLimitError` for an integer over the largest integer of the BEAM
  # (`docs/features/wire-protocol.md`, "Bounds"); here that text is an
  # error, as any other text that does not decode. The Credo check
  # `Helyx.Credo.JSONDecode` reports a call written `JSON.decode` or
  # `JSON.decode!` in other `lib/` code (#792).

  @spec decode(binary()) :: {:ok, term()} | {:error, term()}
  def decode(text) do
    JSON.decode(text)
  rescue
    SystemLimitError -> {:error, :system_limit}
  end
end
