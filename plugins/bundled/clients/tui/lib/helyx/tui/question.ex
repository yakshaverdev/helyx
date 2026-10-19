defmodule Helyx.TUI.Question do
  @moduledoc false
  # The picker of the `question` tool in the place of the composer
  # (docs/features/question-tool.md, "The TUI picker"). It shows the oldest
  # open ask of the tool, one question at a time, and sends the answers
  # with `Helyx.TUI.Link.answer/3` after the last one. The request comes
  # from the bundled tool, which checked its shape. `ask_end` closes it.

  alias ExRatatui.Event.{Key, Paste}
  alias ExRatatui.Style
  alias ExRatatui.Text.{Line, Span}
  alias ExRatatui.Widgets.{Block, Paragraph}
  alias Helyx.TUI.{Composer, Link, SessionList, ViewModel, Wrap}
  require Link

  # A longer text cannot pass the answer bound of Core, so the line keeps
  # no more.
  @max_answer_bytes Helyx.Session.max_answer_bytes()

  @dim %Style{modifiers: [:dim]}
  @cursor %Style{modifiers: [:reversed]}

  # `at` is the index of the shown question; `cursor` is an option index,
  # or the option count for the "Other" line; `marks` are the marked labels
  # of a multi-select question; `answers` are those of the questions before
  # `at`, in order; `sent?` is true once the answer went.
  @enforce_keys [:ask_id, :questions]
  defstruct [
    :ask_id,
    :questions,
    at: 0,
    cursor: 0,
    marks: [],
    other: "",
    answers: [],
    sent?: false
  ]

  @type t :: %__MODULE__{
          ask_id: String.t(),
          questions: [map()],
          at: non_neg_integer(),
          cursor: non_neg_integer(),
          marks: [String.t()],
          other: String.t(),
          answers: [map()],
          sent?: boolean()
        }

  @too_large "not sent: the answers are over #{div(@max_answer_bytes, 1024)} KiB"

  # A key or a paste while the picker shows. `Helyx.TUI` gives Ctrl+C,
  # PgUp, PgDn, Ctrl+O, Escape, and the open `/resume` list their usual
  # rule first.
  defguard handles?(question, event)
           when question != nil and (is_struct(event, Key) or is_struct(event, Paste))

  # The picker of the oldest ask of the tool in the view model: the one
  # that shows keeps its progress, and none shows when no ask is open.
  @spec sync(map()) :: map()
  def sync(%{vm: %ViewModel{asks: asks}, question: question} = state) do
    ask = Enum.find(asks, &(&1.tool == "question"))
    %{state | question: picker(question, ask)}
  end

  defp picker(_question, nil), do: nil
  defp picker(%__MODULE__{ask_id: id} = question, %{ask_id: id}), do: question

  # The question text gets its clean pass once, not in each frame.
  defp picker(_question, %{ask_id: id, request: %{"questions" => questions}}) do
    questions =
      Enum.map(questions, &Map.update!(&1, "question", fn t -> SessionList.one_line(t) end))

    %__MODULE__{ask_id: id, questions: questions}
  end

  # The answer of `Helyx.TUI.handle_event/2` to an event that `handles?/2`
  # accepts. After the answer went, the picker takes no other input.
  @spec handle(struct(), map()) :: {:noreply, map()}
  def handle(_event, %{question: %__MODULE__{sent?: true}} = state), do: {:noreply, state}

  def handle(%Key{kind: kind} = key, state) when kind in ["press", "repeat"],
    do: {:noreply, key(state, key)}

  # A paste goes to the "Other" line as one line, cleaned as the search
  # line cleans it.
  def handle(%Paste{content: content}, state) do
    text =
      content
      |> Helyx.Text.cap(@max_answer_bytes, :head)
      |> String.replace(["\r\n", "\r", "\n"], " ")

    {:noreply, other(state, state.question.other <> Wrap.sanitize(text))}
  end

  def handle(_event, state), do: {:noreply, state}

  # A key with Ctrl or Alt does nothing.
  defp key(state, %Key{modifiers: modifiers}) when modifiers not in [[], ["shift"]], do: state

  defp key(%{question: q} = state, %Key{code: "up"}),
    do: %{state | question: %{q | cursor: max(q.cursor - 1, 0)}}

  defp key(%{question: q} = state, %Key{code: "down"}),
    do: %{state | question: %{q | cursor: min(q.cursor + 1, length(options(q)))}}

  defp key(state, %Key{code: "backspace"}),
    do: other(state, String.slice(state.question.other, 0..-2//1))

  defp key(%{question: q} = state, %Key{code: "enter", kind: "press"}) do
    case answer(q) do
      nil -> state
      answer -> next(state, answer)
    end
  end

  # Space marks an option of a multi-select question; on the "Other" line
  # it is a space.
  defp key(%{question: q} = state, %Key{code: " "}) do
    case Enum.at(options(q), q.cursor) do
      nil -> other(state, q.other <> " ")
      %{"label" => label} -> mark(state, label)
    end
  end

  # A typed character goes to the "Other" line, which takes the cursor. The
  # control rule is the one of the composer.
  defp key(state, %Key{code: code}) do
    if String.length(code) == 1 and Wrap.drop_controls(code) == code,
      do: other(state, state.question.other <> code),
      else: state
  end

  defp other(%{question: q} = state, text) do
    text = Helyx.Text.cap(text, @max_answer_bytes, :head)
    %{state | question: %{q | other: text, cursor: length(options(q))}}
  end

  defp mark(%{question: q} = state, label) do
    marks = if label in q.marks, do: List.delete(q.marks, label), else: q.marks ++ [label]
    if multi?(q), do: %{state | question: %{q | marks: marks}}, else: state
  end

  # The answer of the shown question at Enter, or nil when it has none: an
  # empty "Other" line. On a multi-select option, Enter takes the marks, or
  # the option under the cursor when none is marked.
  defp answer(%__MODULE__{} = q) do
    options = options(q)
    labels = for %{"label" => label} <- options, do: label
    marks = Enum.filter(labels, &(&1 in q.marks))

    cond do
      q.cursor == length(options) and q.other == "" ->
        nil

      q.cursor == length(options) ->
        %{"selected" => if(multi?(q), do: marks, else: []), "other" => q.other}

      multi?(q) and marks != [] ->
        %{"selected" => marks}

      true ->
        %{"selected" => [Enum.at(labels, q.cursor)]}
    end
  end

  # The next question, or the send after the last one. An answer goes on
  # only while the answers so far and the longest option of each question
  # after it fit the bound of Core, so each later question can still be
  # answered; else the question stays, and the footer says why. A rejected
  # send keeps the last question too.
  defp next(%{question: q} = state, answer) do
    answers = q.answers ++ [answer]

    cond do
      not fits?(q.questions, answers) ->
        %{state | vm: ViewModel.reject(state.vm, @too_large)}

      q.at + 1 < length(q.questions) ->
        fresh = %__MODULE__{ask_id: q.ask_id, questions: q.questions}
        %{state | question: %{fresh | at: q.at + 1, answers: answers}}

      true ->
        send_answers(state, answers)
    end
  end

  # Each later answer adds its JSON and a comma.
  defp fits?(questions, answers) do
    later = for question <- Enum.drop(questions, length(answers)), do: longest(question) + 1
    {:ok, size} = Helyx.Message.encoded_size(%{"answers" => answers})
    size + Enum.sum(later) <= @max_answer_bytes
  end

  defp longest(question) do
    sizes =
      for %{"label" => label} <- question["options"] do
        {:ok, size} = Helyx.Message.encoded_size(%{"selected" => [label]})
        size
      end

    Enum.max(sizes)
  end

  defp send_answers(%{question: q} = state, answers) do
    case Link.answer(state.session, q.ask_id, %{"answers" => answers}) do
      :ok -> %{state | question: %{q | sent?: true}}
      {:error, reason} -> %{state | vm: ViewModel.reject(state.vm, reject(reason))}
    end
  end

  # The labels and the terminal give valid UTF-8, so only the size fails.
  defp reject(:invalid_answer), do: @too_large

  defp reject(:not_waiting), do: "not sent: the question is closed"
  defp reject(:session_not_found), do: "not sent: the session ended"
  defp reject(reason) when Link.wire_error?(reason), do: Link.error_text(reason)

  defp question(%__MODULE__{questions: questions, at: at}), do: Enum.at(questions, at)

  defp options(q), do: question(q)["options"]
  defp multi?(q), do: question(q)["multi_select"] == true

  # The rows of the picker with its two borders, in `room` rows by the rule
  # of the composer: the question text at `width`, the options, and the
  # "Other" line.
  @spec rows(t(), integer(), integer()) :: pos_integer()
  def rows(%__MODULE__{} = q, width, room),
    do: Composer.fit(length(text_rows(q, width)) + length(options(q)) + 3, room)

  defp text_rows(q, width),
    do: Wrap.rows(question(q)["question"], max(width - 2, 1))

  # The picker in `area`. The header and the place in the questions are the
  # title on the border. The question rows are cut first, so the options
  # and the "Other" line show in the room; a row does not wrap, so a long
  # option is cut at the edge. The texts come from the model, so each gets
  # the clean pass.
  @spec widgets(t(), ExRatatui.Layout.Rect.t()) :: [{Paragraph.t(), ExRatatui.Layout.Rect.t()}]
  def widgets(%__MODULE__{} = q, area) do
    options = options(q)
    room = max(area.height - 2 - length(options) - 1, 0)

    text =
      q
      |> text_rows(area.width)
      |> Enum.take(room)
      |> Enum.map(&%Line{spans: [%Span{content: &1}]})

    lines =
      if q.sent?,
        do: [%Line{spans: [%Span{content: "answer sent", style: @dim}]}],
        else: text ++ Enum.with_index(options, &option(q, &1, &2)) ++ [other_line(q, area.width)]

    [{%Paragraph{text: lines, block: box(q)}, area}]
  end

  defp option(q, %{"label" => label, "description" => description}, index) do
    pointer = if index == q.cursor, do: "› ", else: "  "
    mark = if multi?(q), do: if(label in q.marks, do: "[x] ", else: "[ ] "), else: ""

    %Line{
      spans: [
        %Span{content: pointer <> mark <> SessionList.one_line(label)},
        %Span{content: "  " <> SessionList.one_line(description), style: @dim}
      ]
    }
  end

  # The end of the text that fits the row, so the typed end shows. Only the
  # last 4 bytes for each column are read: a row of text with no zero-width
  # marks.
  defp other_line(q, width) do
    pointer = if q.cursor == length(options(q)), do: "› ", else: "  "
    columns = max(width - 12, 1)
    shown = q.other |> Helyx.Text.cap(4 * columns, :tail) |> tail(columns)

    %Line{
      spans: [
        %Span{content: pointer <> "Other: ", style: @dim},
        %Span{content: shown},
        %Span{content: " ", style: @cursor}
      ]
    }
  end

  defp tail(text, columns) do
    text
    |> String.graphemes()
    |> Enum.reverse()
    |> Enum.reduce_while({[], 0}, fn grapheme, {kept, used} ->
      used = used + Wrap.columns(grapheme)
      if used > columns, do: {:halt, {kept, used}}, else: {:cont, {[grapheme | kept], used}}
    end)
    |> elem(0)
    |> Enum.join()
  end

  defp box(q) do
    place =
      if length(q.questions) > 1,
        do: " #{q.at + 1}/#{length(q.questions)}",
        else: ""

    %Block{
      borders: [:all],
      border_type: :rounded,
      border_style: %Style{fg: :blue},
      title: %Span{content: " " <> SessionList.one_line(question(q)["header"]) <> place <> " "}
    }
  end
end
