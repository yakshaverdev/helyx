defmodule Helyx.EventTest do
  use ExUnit.Case, async: true

  # The list of the feed is the union of the type, so a type that the type
  # gains or loses without the list fails here (docs/features/session-feed.md).
  test "types/0 lists every type of the type spec" do
    {:ok, types} = Code.Typespec.fetch_types(Helyx.Event)
    {:type, {_name, definition, _vars}} = Enum.find(types, &match?({:type, {:type, _, _}}, &1))

    assert Helyx.Event.types() == members(definition)
  end

  defp members({:type, _line, :union, parts}), do: Enum.flat_map(parts, &members/1)
  defp members({:atom, _line, type}), do: [type]
end
