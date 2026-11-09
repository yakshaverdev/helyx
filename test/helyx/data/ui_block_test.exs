defmodule Helyx.UIBlockTest do
  use ExUnit.Case, async: true

  alias Helyx.UIBlock

  @max 65_536

  defp encoded(block), do: byte_size(JSON.encode!(block))

  # A block whose JSON encode is exactly `bytes`, padded with `char` in a field.
  defp block_of(bytes, char) do
    base = %{"kind" => "table", "text" => "t", "rows" => ""}
    per = encoded(char) - 2
    pad = div(bytes - encoded(base), per)
    block = %{base | "rows" => String.duplicate(char, pad)}
    # The rest in plain bytes.
    %{block | "rows" => block["rows"] <> String.duplicate("a", bytes - encoded(block))}
  end

  describe "check/1 envelope" do
    test "a minimal block passes as it is" do
      block = %{"kind" => "form", "text" => "2 questions"}
      assert UIBlock.check(block) == {:ok, block}
    end

    test "kind is 1 to 64 bytes of a-z, 0-9, and _" do
      assert {:ok, _} = UIBlock.check(%{"kind" => String.duplicate("a", 64), "text" => ""})
      assert UIBlock.check(%{"kind" => String.duplicate("a", 65), "text" => ""}) == :error
      assert UIBlock.check(%{"kind" => "", "text" => ""}) == :error
      assert UIBlock.check(%{"kind" => "Diff", "text" => ""}) == :error
      assert UIBlock.check(%{"kind" => "a-b", "text" => ""}) == :error
      assert UIBlock.check(%{"kind" => "é", "text" => ""}) == :error
      assert {:ok, _} = UIBlock.check(%{"kind" => "a_1", "text" => ""})
    end

    test "text is a string, cut a boolean when present" do
      assert UIBlock.check(%{"kind" => "a"}) == :error
      assert UIBlock.check(%{"kind" => "a", "text" => 1}) == :error
      assert UIBlock.check(%{"kind" => "a", "text" => "", "cut" => "yes"}) == :error
      assert UIBlock.check(%{"kind" => "a", "text" => "", "cut" => nil}) == :error
      assert {:ok, _} = UIBlock.check(%{"kind" => "a", "text" => "", "cut" => true})
    end

    test "a value that is not a JSON object with string keys is not a block" do
      assert UIBlock.check([]) == :error
      assert UIBlock.check("x") == :error
      assert UIBlock.check(%{kind: "a", text: ""}) == :error
      assert UIBlock.check(%{"kind" => "a", "text" => "", 1 => 2}) == :error
      assert UIBlock.check(%{"kind" => "a", "text" => "", "x" => {1}}) == :error
      assert UIBlock.check(%{"kind" => "a", "text" => "", "x" => :atom}) == :error
      assert UIBlock.check(%{"kind" => "a", "text" => "", "x" => [1 | 2]}) == :error
      assert UIBlock.check(%{"kind" => "a", "text" => "", "x" => ~D[2026-01-01]}) == :error
      assert UIBlock.check(%{"kind" => "a", "text" => "", "x" => %{"y" => self()}}) == :error
    end

    test "invalid UTF-8 anywhere, a key included, is not a block" do
      assert UIBlock.check(%{"kind" => "a", "text" => <<0xFF>>}) == :error
      assert UIBlock.check(%{"kind" => "a", "text" => "", "x" => [<<0xC3>>]}) == :error
      assert UIBlock.check(%{"kind" => "a", "text" => "", <<0xFF>> => 1}) == :error
    end
  end

  describe "check/1 integers" do
    test "100 digits pass, 101 digits are not a block, at any depth" do
      ok = 10 ** 100 - 1
      big = 10 ** 100

      assert {:ok, _} = UIBlock.check(%{"kind" => "a", "text" => "", "n" => ok})
      assert {:ok, _} = UIBlock.check(%{"kind" => "a", "text" => "", "n" => -ok})
      assert UIBlock.check(%{"kind" => "a", "text" => "", "n" => big}) == :error
      assert UIBlock.check(%{"kind" => "a", "text" => "", "n" => -big}) == :error
      assert UIBlock.check(%{"kind" => "a", "text" => "", "n" => [%{"m" => [big]}]}) == :error
    end

    test "a block over the byte bound with a big integer is not cut" do
      block = %{
        "kind" => "a",
        "text" => "",
        "pad" => String.duplicate("a", 70_000),
        "n" => 10 ** 100
      }

      assert UIBlock.check(block) == :error
    end

    test "a block over the bound with invalid UTF-8 past the bound is not cut" do
      block = %{"kind" => "a", "text" => "", "pad" => String.duplicate("a", 70_000) <> <<0xFF>>}
      assert UIBlock.check(block) == :error
    end
  end

  describe "check/1 bound" do
    for char <- ["a", "é", "\"", "\n", <<1>>, "…"] do
      test "at the bound and one over, padded with #{inspect(char)}" do
        at = block_of(@max, unquote(char))
        assert encoded(at) == @max
        assert UIBlock.check(at) == {:ok, at}

        over = block_of(@max + 1, unquote(char))
        assert encoded(over) == @max + 1

        assert {:ok, %{"kind" => "table", "text" => "t", "cut" => true} = cut} =
                 UIBlock.check(over)

        assert map_size(cut) == 3
      end
    end

    for char <- ["a", "é", "\"", "\n", <<1>>, "…", "😀"] do
      test "a long text of #{inspect(char)} is cut within the bound, start and end kept" do
        text = "START" <> String.duplicate(unquote(char), 200_000) <> "END"
        {:ok, cut} = UIBlock.check(%{"kind" => "diff", "text" => text, "x" => 1})

        assert cut["cut"] == true
        assert Map.keys(cut) |> Enum.sort() == ["cut", "kind", "text"]
        assert encoded(cut) <= @max
        # The budget is used: at most one escaped character and a split
        # character on each side are left over.
        assert encoded(cut) > @max - 30
        assert String.valid?(cut["text"])

        assert cut["text"] =~
                 ~r/\A\[cut to \d+ of #{byte_size(text)} bytes, start and end kept\]\nSTART/

        assert String.ends_with?(cut["text"], "END")
        assert String.contains?(cut["text"], "\n[… cut …]\n")
        # A second check does not change the cut.
        assert UIBlock.check(cut) == {:ok, cut}
      end
    end

    test "a short text of a block over the bound is kept whole" do
      block = %{"kind" => "table", "text" => "3 rows", "rows" => String.duplicate("x", 70_000)}

      assert UIBlock.check(block) ==
               {:ok, %{"kind" => "table", "text" => "3 rows", "cut" => true}}
    end

    test "the longest kind with a long text fits" do
      kind = String.duplicate("z", 64)
      text = String.duplicate(<<1>>, 100_000)
      {:ok, cut} = UIBlock.check(%{"kind" => kind, "text" => text})
      assert encoded(cut) <= @max
    end
  end

  test "key?/1 is valid UTF-8 of 1 to 64 bytes" do
    assert UIBlock.key?("a")
    assert UIBlock.key?(String.duplicate("é", 32))
    refute UIBlock.key?(String.duplicate("é", 32) <> "a")
    refute UIBlock.key?("")
    refute UIBlock.key?(<<0xFF>>)
    refute UIBlock.key?(:a)
  end

  test "envelope?/1 checks kind, text, and cut alone" do
    assert UIBlock.envelope?(%{"kind" => "form", "text" => "x", "questions" => []})
    refute UIBlock.envelope?(%{"questions" => []})
    refute UIBlock.envelope?(%{"kind" => "form", "text" => "x", "cut" => 1})
  end
end
