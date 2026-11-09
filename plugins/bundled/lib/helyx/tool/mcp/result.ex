defmodule Helyx.Tool.MCP.Result do
  @moduledoc false
  # The text of the result of an MCP `tools/call` (`docs/features/mcp-client.md`,
  # "Helyx.Tool.MCP", step 4): each text block as is, a binary block as a
  # line that names it, an embedded resource as its text; with no content
  # block, the JSON of `structuredContent`. Blocks join with a newline.
  # `isError: true` gives `{:error, text}`. The hands cut the text.

  # A JSON-RPC answer: its result, or its error text, cut.
  def reply(%{"result" => result}), do: {:ok, result}

  def reply(%{"error" => %{"message" => text}}) when is_binary(text),
    do: {:error, Helyx.Text.cap(text, 2_000, :head)}

  def reply(_message), do: {:error, "an answer with no result"}

  # The result of a call from the answer to its `tools/call`.
  def call({:ok, result}), do: text(result)
  def call({:error, text}), do: {:error, "the MCP server answered an error: " <> text}

  def text(%{} = result) do
    text =
      case result["content"] do
        [_ | _] = blocks -> Enum.map_join(blocks, "\n", &block/1)
        _none -> structured(result["structuredContent"])
      end

    if result["isError"] == true, do: {:error, text}, else: {:ok, text}
  end

  def text(_result), do: {:error, "the MCP server gave a result that is not an object"}

  defp block(%{"type" => "text", "text" => text}) when is_binary(text), do: text

  defp block(%{"type" => type, "data" => data} = block)
       when type in ["image", "audio"] and is_binary(data),
       do: "[#{type} #{string(block["mimeType"])}, #{decoded_size(data)} bytes, not shown]"

  defp block(%{"type" => "resource_link", "uri" => uri} = block) when is_binary(uri),
    do: "[resource #{string(block["name"])}: #{uri}]"

  defp block(%{"type" => "resource", "resource" => %{"text" => text}}) when is_binary(text),
    do: text

  defp block(%{"type" => "resource", "resource" => %{"blob" => blob} = resource})
       when is_binary(blob),
       do: "[resource #{string(resource["uri"])}, #{decoded_size(blob)} bytes, not shown]"

  defp block(_block), do: "[a content block that Helyx does not show]"

  defp structured(nil), do: ""
  defp structured(value), do: JSON.encode!(value)

  defp string(value) when is_binary(value), do: value
  defp string(_value), do: "?"

  # The bytes of base64 data, or of the text when it is not base64.
  defp decoded_size(data) do
    case Base.decode64(data) do
      {:ok, bytes} -> byte_size(bytes)
      :error -> byte_size(data)
    end
  end
end
