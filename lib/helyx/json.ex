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

  # As `decode/1`, and an object with a repeated key, at any depth, is
  # `{:error, :duplicate_key}`: a reader that accepts a stated subset fails
  # closed (docs/agents/review-checklist.md), where `decode/1` keeps the
  # first value and a JavaScript reader the last. The second pass runs only
  # on text that the first decoded, so it cannot raise on an integer.
  @spec decode(binary(), :unique_keys) :: {:ok, term()} | {:error, term()}
  def decode(text, :unique_keys) do
    with {:ok, value} <- decode(text) do
      JSON.decode(text, :ok, object_finish: &unique/2)
      {:ok, value}
    end
  catch
    :throw, :duplicate_key -> {:error, :duplicate_key}
  end

  defp unique(pairs, acc) do
    map = Map.new(pairs)
    if map_size(map) == length(pairs), do: {map, acc}, else: throw(:duplicate_key)
  end
end
