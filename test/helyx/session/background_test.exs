defmodule Helyx.Session.BackgroundTest do
  use ExUnit.Case, async: true

  alias Helyx.Message
  alias Helyx.Message.ToolCall
  alias Helyx.Session.Background

  @id "abcdefghijkl"

  defp start_result(id, status \\ :ok) do
    call = %ToolCall{id: "c-" <> id, name: "bash", arguments: %{}}
    Message.tool_result(call, {status, Background.start(id, "go")})
  end

  test "the start and the end open with a fixed line that names the run" do
    assert Background.start(@id, "go") ==
             ~s(<background id="#{@id}" status="started">\ngo\n</background>)

    assert Background.finish(@id, {:ok, "out"}) ==
             ~s(<background id="#{@id}" status="done">\nout\n</background>)

    assert Background.finish(@id, {:error, "x"}) ==
             ~s(<background id="#{@id}" status="error">\nx\n</background>)
  end

  # The UTF-8 repair is in the hands (`hands_test.exs`).
  test "the start text is cut to 4,096 bytes" do
    at = String.duplicate("a", 4096)
    assert Background.start(@id, at) == Background.start(@id, at <> "b")

    assert Background.start(@id, String.duplicate("a", 4095)) =~
             "\n" <> String.duplicate("a", 4095) <> "\n"
  end

  test "each start answer with no end message is lost, in start order; an error result is no start" do
    other = "mnopqrstuvwx"
    third = "yz0123456789"

    transcript = [
      Message.user("go"),
      start_result(@id),
      start_result(other),
      start_result(third, :error),
      Message.user(Background.finish(@id, {:ok, "done"}))
    ]

    assert [%Message{origin: %{kind: :background, id: ^other}} = lost] =
             Background.lost(transcript)

    assert Message.text(lost) ==
             ~s(<background id="#{other}" status="lost">\n) <>
               "The session stopped while this background command ran, and its end was lost. " <>
               "The command may have run in full or in part. " <>
               "Check its effects before you run it again. " <>
               "Its output file was deleted with the session.\n</background>"

    assert Background.lost(transcript ++ [lost]) == []

    assert [first, second] = Background.lost([start_result(other), start_result(@id)])
    assert {first.origin.id, second.origin.id} == {other, @id}
  end
end
