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

  describe "cut_result/1" do
    @max 65_536

    test "a valid result at the limit or one under is returned unchanged; one over is cut" do
      for bytes <- [@max - 1, @max] do
        text = String.duplicate("x", bytes)
        assert Message.cut_result(text) == text
      end

      cut = Message.cut_result(String.duplicate("x", @max + 1))
      assert byte_size(cut) <= @max
      assert cut =~ ~r/^\[cut to \d+ of 65537 bytes, start and end kept\]\n/
    end

    test "a result over the limit becomes a notice line, its head, a marker line, and its tail" do
      text = "first line\n" <> String.duplicate("x", 200_000) <> "\nexit 3"
      cut = Message.cut_result(text)

      assert byte_size(cut) <= @max
      assert [notice, "first line", head, marker, tail, "exit 3"] = String.split(cut, "\n")
      kept_head = byte_size("first line\n" <> head)
      kept_tail = byte_size(tail <> "\nexit 3")
      kept = kept_head + kept_tail
      assert notice == "[cut to #{kept} of #{byte_size(text)} bytes, start and end kept]"
      assert marker == "[… cut …]"
      assert head =~ ~r/^x+$/ and tail =~ ~r/^x+$/
      # The head and the tail each get half of the room.
      assert abs(kept_head - kept_tail) <= 1
      # A second cut changes nothing.
      assert Message.cut_result(cut) == cut
    end

    test "the cut drops a character that it splits, at the end of the head and the start of the tail" do
      for pad <- 0..3 do
        emoji = String.duplicate("😀", 20_000)
        text = String.duplicate("x", pad) <> emoji <> String.duplicate("y", pad)
        cut = Message.cut_result(text)
        assert String.valid?(cut)
        assert byte_size(cut) <= @max
        assert String.ends_with?(cut, "😀" <> String.duplicate("y", pad))
        assert Message.cut_result(cut) == cut
      end
    end

    test "invalid bytes are replaced before the cut, so the repaired text is cut to the limit" do
      cut = Message.cut_result(:binary.copy(<<255>>, 60_000))

      assert String.valid?(cut)
      assert byte_size(cut) <= @max

      assert cut =~
               ~r/^\[cut to \d+ of 180000 bytes, start and end kept\]\n\x{FFFD}+\n\[… cut …\]\n\x{FFFD}+$/u
    end
  end
end
