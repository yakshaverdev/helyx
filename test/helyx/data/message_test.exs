defmodule Helyx.MessageTest do
  use ExUnit.Case, async: true

  alias Helyx.Message

  test "cap_integers replaces only an integer of more than 100 digits, at any depth" do
    at = 10 ** 100 - 1
    over = 10 ** 100
    marker = "integer of more than 100 digits removed"

    small = %{
      "under" => 10 ** 99 - 1,
      at => "key",
      "a" => at,
      "b" => -at,
      "c" => 1.0e300,
      "d" => "é",
      "e" => nil,
      "f" => []
    }

    assert Message.cap_integers(small) == small

    assert Message.cap_integers(%{over => 1}) == %{marker => 1}

    assert Message.cap_integers(%{"a" => over, "b" => [1, [-over], %{"c" => over - 1}]}) ==
             %{"a" => marker, "b" => [1, [marker], %{"c" => over - 1}]}

    # A tuple and an improper list are walked.
    assert Message.cap_integers(%{"a" => {over, 1}, "b" => [1 | over]}) ==
             %{"a" => {marker, 1}, "b" => [1 | marker]}

    # A struct that holds such an integer becomes the marker as a whole: JSON
    # encodes a Date and a Duration.
    assert Message.cap_integers([%Date{year: over, month: 1, day: 1}, %Duration{second: -over}]) ==
             [marker, marker]

    assert Message.cap_integers([~D[2026-09-19], self()]) == [~D[2026-09-19], self()]

    # The predicate takes the same walk and agrees with the cap.
    refute Message.big_integer?([small, ~D[2026-09-19], self()])

    for value <- [-over, %{over => 1}, {1, over}, [1 | over], %Duration{second: over}] do
      assert Message.big_integer?(value)
    end
  end

  test "stop_reasons is the closed set of a message end" do
    assert Message.stop_reasons() == [:end_turn, :tool_use, :max_tokens, :aborted, :error]
  end

  test "resume_id? accepts valid UTF-8 of 1 to 256 bytes" do
    assert Message.resume_id?("a")
    assert Message.resume_id?(String.duplicate("a", 256))
    refute Message.resume_id?("")
    refute Message.resume_id?(String.duplicate("a", 257))
    refute Message.resume_id?(<<255>>)
  end

  test "valid tool output passes through unchanged" do
    call = %Message.ToolCall{id: "c1", name: "bash", arguments: %{}}
    text = "héllo\n"

    assert Message.text(Message.tool_result(call, {:ok, text})) == text
  end
end
