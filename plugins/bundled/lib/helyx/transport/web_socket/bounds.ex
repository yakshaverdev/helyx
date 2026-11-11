defmodule Helyx.Transport.WebSocket.Bounds do
  @moduledoc false
  # The numbers and the error codes of the wire, read at compile time from
  # `test/fixtures/wire/bounds.json`, the one place that holds them
  # (`docs/features/wire-protocol.md`, "Bounds", gives the reason of each).
  # The server and the client of the TUI take them from here; the Rust
  # client checks its constants against the same file.

  @path Path.expand("../../../../../../test/fixtures/wire/bounds.json", __DIR__)
  @external_resource @path
  @bounds JSON.decode!(File.read!(@path))
  @codes Enum.map(@bounds["error_codes"], &String.to_atom/1)

  @spec get(String.t()) :: pos_integer()
  def get(key) when key not in ~w(deadlines_ms error_codes), do: Map.fetch!(@bounds, key)

  @doc "The deadline of `op` in milliseconds, or that of an op with no row."
  @spec deadline(String.t()) :: pos_integer()
  def deadline(op), do: Map.get(@bounds["deadlines_ms"], op, @bounds["deadlines_ms"]["default"])

  @spec error_codes() :: [atom()]
  def error_codes, do: @codes
end
