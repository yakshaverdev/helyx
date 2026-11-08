defmodule Helyx.TUI.Approval do
  @moduledoc false
  # The picker of an `approval` UI block in the place of the composer
  # (docs/features/approval-gate.md, "The TUI renderer"). `Helyx.TUI.Question`
  # picks the oldest ask that it can show, a form or an approval, and hands
  # an approval here: the title is the text of the block, the body the
  # arguments, and the user picks Allow or Deny. The answer goes with
  # `Helyx.TUI.Link.answer/3`.

  alias ExRatatui.Event.Key
  alias ExRatatui.Style
  alias ExRatatui.Text.{Line, Span}
  alias ExRatatui.Widgets.{Block, Paragraph}
  alias Helyx.TUI.{Composer, Link, Question, SessionList, ViewModel, Wrap}

  # The bytes of the arguments that the picker keeps: the bound of the
  # gate's own request, so a block of another emitter, up to the 64 KiB of
  # an ask, wraps no more in a frame.
  @max_text_bytes 16_384
  # The rows of the arguments that the picker shows, so the transcript
  # keeps its room; the title is one row.
  @max_rows 8
  # The title is one row on the border, so a longer text, up to the 64 KiB
  # of an ask, is cut before its clean pass.
  @max_title_bytes 1_024
  # The label, the decision of the answer, and the key that sends it.
  @options [{"Allow", "allow", "y"}, {"Deny", "deny", "n"}]

  @dim %Style{modifiers: [:dim]}
  @more %Line{spans: [%Span{content: "… more arguments", style: @dim}]}

  @enforce_keys [:ask_id, :title, :text, :cut?]
  defstruct [:ask_id, :title, :text, :cut?, cursor: 0, sent?: false]

  @type t :: %__MODULE__{
          ask_id: String.t(),
          title: String.t(),
          text: String.t(),
          cut?: boolean(),
          cursor: 0 | 1,
          sent?: boolean()
        }

  # Whether the TUI can read the fields of an approval request
  # (docs/features/ui-blocks.md, "approval").
  @spec readable?(map()) :: boolean()
  def readable?(%{"tool" => tool, "arguments" => arguments} = request)
      when is_binary(tool) and is_binary(arguments),
      do: is_nil(request["provider"]) or is_binary(request["provider"])

  def readable?(_request), do: false

  # The title gets its clean pass once, not in each frame; the arguments
  # get theirs in `Wrap.rows/2`.
  @spec new(Helyx.Session.Snapshot.ask()) :: t()
  def new(%{ask_id: id, request: request}) do
    arguments = request["arguments"]

    %__MODULE__{
      ask_id: id,
      title: request["text"] |> Helyx.Text.cap(@max_title_bytes, :head) |> SessionList.one_line(),
      text: Helyx.Text.cap(arguments, @max_text_bytes, :head),
      cut?: request["cut"] == true or byte_size(arguments) > @max_text_bytes
    }
  end

  # The answer of `Helyx.TUI.handle_event/2` to a key or a paste while the
  # picker shows. After the answer went, it takes no other input.
  @spec handle(struct(), map()) :: {:noreply, map()}
  def handle(_event, %{question: %__MODULE__{sent?: true}} = state), do: {:noreply, state}

  # A repeat moves the cursor and sends nothing.
  def handle(%Key{kind: kind, modifiers: modifiers, code: code}, state)
      when modifiers in [[], ["shift"]] and
             (kind == "press" or (kind == "repeat" and code in ["up", "down"])),
      do: {:noreply, key(state, code)}

  def handle(_event, state), do: {:noreply, state}

  defp key(%{question: a} = state, "up"), do: %{state | question: %{a | cursor: 0}}
  defp key(%{question: a} = state, "down"), do: %{state | question: %{a | cursor: 1}}

  defp key(%{question: a} = state, "enter") do
    {_label, decision, _key} = Enum.at(@options, a.cursor)
    decide(state, decision)
  end

  defp key(state, code) do
    case List.keyfind(@options, code, 2) do
      {_label, decision, _key} -> decide(state, decision)
      nil -> state
    end
  end

  defp decide(%{question: a} = state, decision) do
    case Link.answer(state.session, a.ask_id, %{"decision" => decision}) do
      :ok -> %{state | question: %{a | sent?: true}}
      {:error, reason} -> %{state | vm: ViewModel.reject(state.vm, Question.reject(reason))}
    end
  end

  # The rows of the picker with its two borders, in `room` rows by the rule
  # of the composer: the arguments rows, a row that says what is left out,
  # and the two options.
  @spec rows(t(), integer(), integer()) :: pos_integer()
  def rows(%__MODULE__{} = a, width, room) do
    {shown, more} = body(a, width)
    Composer.fit(length(shown) + length(more) + length(@options) + 2, room)
  end

  # The first rows of the arguments at `width`, and the row that says what
  # is left out, when any part of them is.
  defp body(a, width) do
    rows = Wrap.rows(a.text, max(width - 2, 1))
    more = if a.cut? or length(rows) > @max_rows, do: [@more], else: []
    {Enum.take(rows, @max_rows), more}
  end

  # The picker in `area`. The options and the row of what is left out show
  # first; the arguments rows take the rest of the room. A row does not
  # wrap.
  @spec widgets(t(), ExRatatui.Layout.Rect.t()) :: [{Paragraph.t(), ExRatatui.Layout.Rect.t()}]
  def widgets(%__MODULE__{} = a, area) do
    {shown, more} = body(a, area.width)
    room = max(area.height - 2 - length(@options) - length(more), 0)
    text = shown |> Enum.take(room) |> Enum.map(&%Line{spans: [%Span{content: &1}]})

    lines =
      if a.sent?,
        do: [%Line{spans: [%Span{content: "answer sent", style: @dim}]}],
        else: text ++ more ++ Enum.with_index(@options, &option(a, &1, &2))

    [{%Paragraph{text: lines, block: box(a)}, area}]
  end

  defp option(a, {label, _decision, key}, index) do
    pointer = if index == a.cursor, do: "› ", else: "  "

    %Line{spans: [%Span{content: pointer <> label}, %Span{content: "  (#{key})", style: @dim}]}
  end

  defp box(a) do
    %Block{
      borders: [:all],
      border_type: :rounded,
      border_style: %Style{fg: :yellow},
      title: %Span{content: " " <> a.title <> " "}
    }
  end
end
