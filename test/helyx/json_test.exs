defmodule Helyx.JSONTest do
  use ExUnit.Case, async: true

  test "an integer over the largest BEAM integer is an error, not a raise" do
    # 1,262,593 nines are over the largest integer of the BEAM (OTP 28).
    assert {:error, _reason} = Helyx.JSON.decode(String.duplicate("9", 1_262_593))
  end

  test "other text decodes or fails as with JSON.decode/1" do
    assert {:ok, %{"a" => [1]}} = Helyx.JSON.decode(~s({"a":[1]}))
    assert {:error, _reason} = Helyx.JSON.decode("{")
  end

  describe "decode/2 with :unique_keys" do
    test "an object with a repeated key, at any depth, is an error" do
      for text <- [~s({"a":1,"a":2}), ~s({"a":{"b":1,"b":1}}), ~s([{"c":{"a":1,"a":2}}])] do
        assert Helyx.JSON.decode(text, :unique_keys) == {:error, :duplicate_key}
      end
    end

    test "other text decodes or fails as with decode/1" do
      assert Helyx.JSON.decode(~s({"a":1,"b":{"a":2}}), :unique_keys) ==
               {:ok, %{"a" => 1, "b" => %{"a" => 2}}}

      assert Helyx.JSON.decode(~s([{"a":1},{"a":2}]), :unique_keys) ==
               {:ok, [%{"a" => 1}, %{"a" => 2}]}

      for text <- ["{", ~s({"a":1} x), String.duplicate("9", 1_262_593)] do
        assert Helyx.JSON.decode(text, :unique_keys) == Helyx.JSON.decode(text)
      end
    end
  end
end
