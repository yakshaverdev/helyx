defmodule Helyx.Provider.OpenAI.ErrorText do
  # The text of an error of the engine. It is built from the HTTP status and
  # the `type` and `code` of an error object. The message, the body, and the
  # payload never reach it, so no copy of the key can, not even one that
  # overlaps another (`docs/adr/0014-hole-proofing-invariants.md`, 2).
  @moduledoc false

  # A field is a short identifier, not a text.
  @max_field_bytes 64
  @field ~r/\A[a-z][a-z0-9_.-]*\z/

  @doc false
  def http(status, body, key), do: text("HTTP #{status}", decode(body, key))

  @doc false
  def api(%{} = error, key), do: text("API error", fields(error, key))
  def api(_error, _key), do: "API error"

  # `: ` and `(` are not bearer token characters, so a key cannot span two
  # fields; each field is checked against the key on its own.
  defp text(label, {nil, nil}), do: label
  defp text(label, {nil, code}), do: label <> " (code: " <> code <> ")"
  defp text(label, {type, nil}), do: label <> " (" <> type <> ")"
  defp text(label, {type, code}), do: label <> " (" <> type <> ": " <> code <> ")"

  defp decode(body, key) do
    case Helyx.JSON.decode(body) do
      {:ok, %{"error" => %{} = error}} -> fields(error, key)
      _ -> {nil, nil}
    end
  end

  defp fields(error, key), do: {field(error["type"], key), field(error["code"], key)}

  defp field(value, key) when is_binary(value) and byte_size(value) <= @max_field_bytes do
    if Regex.match?(@field, value) and not holds_key?(value, key), do: value
  end

  defp field(_value, _key), do: nil

  defp holds_key?(_value, nil), do: false
  defp holds_key?(value, key), do: String.contains?(value, key)
end
