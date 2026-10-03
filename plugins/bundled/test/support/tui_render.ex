defmodule Helyx.Test.TUIRender do
  @moduledoc false
  # The wrap of the TUI and the draw of ExRatatui, for the tests that
  # compare the width rule with what the terminal library draws.

  alias ExRatatui.Layout.Rect
  alias ExRatatui.Text.{Line, Span}
  alias ExRatatui.Widgets.Paragraph
  alias Helyx.Session.Snapshot
  alias Helyx.TUI.{Transcript, ViewModel}

  @doc "A view model on `model` with `cells`, from the snapshot of an empty session."
  def view_model(cells, model \\ "fake/m") do
    snapshot = %Snapshot{
      instance_id: "i",
      seq: 0,
      messages: [],
      turn: nil,
      model: model,
      queue: %{steers: 0, follow_ups: 0}
    }

    %{ViewModel.from_snapshot(snapshot) | cells: :array.from_list(cells)}
  end

  @doc "The text of every transcript row of `vm` at `width`, from its first row."
  def texts(vm, width \\ 80) do
    # More rows than any test transcript has, so the widget shows them all.
    %Paragraph{text: lines} =
      Transcript.widget(vm, {0, 0}, %Rect{x: 0, y: 0, width: width, height: 10_000_000})

    for line <- lines, span <- line.spans, do: span.content
  end

  @doc "The rows of `text` as one assistant message, wrapped at `width`."
  def wrapped(text, width) do
    message = %Helyx.Message{role: :assistant, content: [%Helyx.Message.Text{text: text}]}
    texts(view_model([message]), width)
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
