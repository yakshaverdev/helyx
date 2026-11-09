defmodule Helyx.Tool.MCP.Listing do
  @moduledoc false
  # The entries of a listing of an MCP server (`docs/features/mcp-client.md`,
  # "Helyx.Tool.MCP" step 2, "Bounds"), with the map of each Helyx name to
  # its MCP name and the notices of the tools left out.

  alias Helyx.Tool.MCP.Config

  @max_tools 256
  @max_description_bytes 4_096

  # The tools of a listing as entries, deferred: task-only tools left out,
  # the first 256 by MCP name order. Two MCP names that map to one Helyx
  # name both go to Core, which keeps the first with a notice (decision 8);
  # a call of that name goes to the first.
  def entries(server, tools) do
    tools = for %{"name" => name} = tool when is_binary(name) <- tools, do: tool

    {tasks, tools} =
      Enum.split_with(tools, &match?(%{"execution" => %{"taskSupport" => "required"}}, &1))

    {kept, over} = tools |> Enum.sort_by(& &1["name"]) |> Enum.split(@max_tools)

    named = Enum.map(kept, &{Config.tool_name(server, &1["name"]), &1})

    entries =
      for {name, tool} <- named do
        %{
          name: name,
          description: description(tool["description"]),
          parameters: if(is_map(tool["inputSchema"]), do: tool["inputSchema"], else: %{}),
          exposure: :deferred
        }
      end

    notices =
      for {count, why} <- [
            {length(tasks), "they need tasks"},
            {length(over), "past #{@max_tools} tools"}
          ],
          count > 0,
          do: "MCP server #{server}: #{count} tools were left out: #{why}"

    names =
      named |> Enum.uniq_by(&elem(&1, 0)) |> Map.new(fn {name, tool} -> {name, tool["name"]} end)

    {entries, names, notices}
  end

  # A description at most 4,096 bytes, cut at a character boundary.
  defp description(text) when is_binary(text),
    do:
      text
      |> binary_part(0, min(byte_size(text), @max_description_bytes))
      |> String.replace_invalid("")

  defp description(_text), do: ""
end
