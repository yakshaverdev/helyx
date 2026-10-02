defmodule Helyx.HarnessIO.StartErrorTest do
  use ExUnit.Case, async: true

  alias Helyx.HarnessIO

  test "a failed-start error has the same cap across port message splits" do
    text = String.duplicate("x", 2_000)

    for chunks <- [
          [text],
          [text <> "x"],
          ["", text],
          ["x", binary_part(text, 1, 1_999)],
          String.graphemes(text)
        ] do
      port = make_ref()
      for chunk <- chunks, do: send(self(), {port, {:data, chunk}})
      # No exit message: reaching the cap must finish the read.
      assert HarnessIO.read_start_error(port, "") == String.duplicate("x", 2_000)
    end
  end

  test "an exit ends an error one byte below the cap" do
    port = make_ref()
    text = String.duplicate("x", 1_999)
    send(self(), {port, {:data, text}})
    send(self(), {port, {:exit_status, 0}})
    assert HarnessIO.read_start_error(port, "") == text
  end

  test "split multibyte characters survive unless the cap cuts them" do
    for {prefix_size, expected} <- [{1_998, "é"}, {1_999, ""}] do
      port = make_ref()
      prefix = String.duplicate("x", prefix_size)
      send(self(), {port, {:data, prefix <> <<195>>}})
      send(self(), {port, {:data, <<169>>}})
      assert HarnessIO.read_start_error(port, "") == prefix <> expected
    end
  end

  test "an exit ends a short error, and invalid UTF-8 is removed" do
    port = make_ref()
    send(self(), {port, {:data, <<"bad ", 255>>}})
    send(self(), {port, {:data, " path"}})
    send(self(), {port, {:exit_status, 0}})
    assert HarnessIO.read_start_error(port, "prefix: ") == "prefix: bad  path"
  end
end
