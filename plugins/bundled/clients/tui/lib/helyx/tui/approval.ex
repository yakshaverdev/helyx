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
  alias Helyx.TUI.{Link, Question, SessionList, ViewModel, Wrap}

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
  # The least rows of the picker: two borders, the row of what is left
  # out, and the two options.
  @min_rows 5
  # The label, the decision of the answer, and the key that sends it.
  @options [{"Allow", "allow", "y"}, {"Deny", "deny", "n"}]

  @dim %Style{modifiers: [:dim]}
  @more %Line{spans: [%Span{content: "… more arguments", style: @dim}]}
  @sent %Line{spans: [%Span{content: "answer sent", style: @dim}]}

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

  # The rows of the picker with its two borders in `room` rows: the rule of
  # the composer (`Helyx.TUI.Composer.fit/2`) with a least of 5 rows, so
  # the row of what is left out and both options always have their room.
  @spec rows(t(), integer(), integer()) :: pos_integer()
  def rows(%__MODULE__{} = a, width, room) do
    wanted = length(body(a, width, @max_rows + 1 + length(@options))) + 2
    min(wanted, max(room - 1, @min_rows))
  end

  # The picker in `area`. A row does not wrap.
  @spec widgets(t(), ExRatatui.Layout.Rect.t()) :: [{Paragraph.t(), ExRatatui.Layout.Rect.t()}]
  def widgets(%__MODULE__{sent?: true} = a, area),
    do: [{%Paragraph{text: [@sent], block: box(a)}, area}]

  def widgets(%__MODULE__{} = a, area),
    do: [{%Paragraph{text: body(a, area.width, area.height - 2), block: box(a)}, area}]

  # The lines in `inner` rows: every arguments row and the options when they
  # fit, else the arguments rows that fit beside the row of what is left
  # out and the options, then that row, then the options. The trim of the
  # room comes first, so a part that it hides is marked too. In fewer than
  # 3 rows, as when the screen squeezes the picker, the options share one
  # line, and in one row the row of what is left out joins it.
  defp body(a, width, inner) do
    rows = Wrap.rows(a.text, max(width - 2, 1))
    options = options(a, inner)
    room = inner - length(options)

    cond do
      not a.cut? and length(rows) <= min(@max_rows, room) -> lines(rows) ++ options
      inner <= 1 -> [%Line{spans: @more.spans ++ [%Span{content: "  "} | hd(options).spans]}]
      true -> lines(Enum.take(rows, max(min(@max_rows, room - 1), 0))) ++ [@more] ++ options
    end
  end

  defp options(a, inner) when inner >= 3, do: Enum.with_index(@options, &option(a, &1, &2))

  defp options(a, _inner) do
    spans =
      @options
      |> Enum.with_index(&option(a, &1, &2).spans)
      |> Enum.intersperse([%Span{content: "  "}])

    [%Line{spans: List.flatten(spans)}]
  end

  defp lines(rows), do: Enum.map(rows, &%Line{spans: [%Span{content: &1}]})

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
