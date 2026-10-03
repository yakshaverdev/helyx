defmodule Helyx.Test.TUIRender do
  @moduledoc false
  # The wrap of the TUI and the draw of ExRatatui, for the tests that
  # compare the width rule with what the terminal library draws.

  alias ExRatatui.Layout.Rect
  alias ExRatatui.Text.{Line, Span}
  alias ExRatatui.Widgets.Paragraph
  alias Helyx.TUI.{Transcript, ViewModel}

  @doc "The rows of `text` as one assistant message, wrapped at `width`."
  def wrapped(text, width) do
    message = %Helyx.Message{role: :assistant, content: [%Helyx.Message.Text{text: text}]}
    vm = %ViewModel{ViewModel.new("fake/m") | cells: :array.from_list([message])}
    for line <- Transcript.lines(vm, width), span <- line.spans, do: span.content
  end

  @doc "The text ExRatatui draws for `rows` in an area of `width` columns."
  def draw(rows, width) do
    height = length(rows)
    terminal = ExRatatui.init_test_terminal(width, height)
    lines = Enum.map(rows, &%Line{spans: [%Span{content: &1}]})
    area = %Rect{x: 0, y: 0, width: width, height: height}
    :ok = ExRatatui.draw(terminal, [{%Paragraph{text: lines}, area}])
    ExRatatui.get_buffer_content(terminal)
  end
end
