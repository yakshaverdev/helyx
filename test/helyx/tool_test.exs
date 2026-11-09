defmodule Helyx.ToolTest do
  # The name rule of `Helyx.Tool.specs/2`: 1 to 52 bytes of `A-Z`, `a-z`,
  # `0-9`, `_`, and `-`
  # (docs/features/mcp-client.md, slice 1).
  use ExUnit.Case, async: true

  import Helyx.Test.SessionCase, only: [start_core: 1]

  defmodule Named do
    @moduledoc false
    # Its name comes from the process dictionary of the caller of
    # `Helyx.Tool.specs/2`, so one module tries every name.
    @behaviour Helyx.Tool

    @impl true
    def name, do: Process.get({__MODULE__, :name})
    @impl true
    def description, do: "d"
    @impl true
    def parameters, do: %{"type" => "object"}
    @impl true
    def run(_args, _cwd), do: {:ok, ""}
  end

  @label inspect(Named)

  setup do
    %{core: start_core([Helyx.Test.Provider, Named])}
  end

  defp specs(core, name) do
    Process.put({Named, :name}, name)
    Helyx.Tool.specs(core)
  end

  test "a name of 1 to 52 bytes of letters, digits, `_` and `-` is accepted", %{core: core} do
    for name <- [
          "a",
          "Z",
          "0",
          "_",
          "-",
          "read",
          "memory_write",
          "single-a",
          "AZaz09_-",
          String.duplicate("a", 51),
          String.duplicate("x", 52)
        ] do
      assert {:ok, [{Named, %{name: ^name}}]} = specs(core, name)
    end
  end

  test "a name over 52 bytes, or empty, is a bad spec labelled by the module", %{core: core} do
    for name <- ["", String.duplicate("x", 53), String.duplicate("x", 200)] do
      assert specs(core, name) == {:error, {:bad_tool_spec, @label}}
    end
  end

  test "each character outside the set is a bad spec", %{core: core} do
    # `"a\n"` also checks the end anchor: `$` would match before a final newline.
    for char <- [" ", ".", "/", ":", "@", "+", "=", "\n", "\t", <<0>>, "\"", "é", "名", "😀"] do
      for name <- [char, "a" <> char, char <> "a", "a" <> char <> "b"] do
        assert specs(core, name) == {:error, {:bad_tool_spec, @label}}, inspect(name)
      end
    end
  end

  test "a multibyte name of 52 bytes or fewer is still a bad spec", %{core: core} do
    # 26 characters of 2 bytes: 52 bytes, valid UTF-8, outside the set.
    name = String.duplicate("é", 26)
    assert byte_size(name) == 52
    assert specs(core, name) == {:error, {:bad_tool_spec, @label}}
  end

  test "bytes that are not UTF-8 and a name that is not a string are bad specs", %{core: core} do
    for name <- [<<"a", 255>>, <<255>>, :read, nil, ~c"read", 1] do
      assert specs(core, name) == {:error, {:bad_tool_spec, @label}}
    end
  end
end
