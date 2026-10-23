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
end
