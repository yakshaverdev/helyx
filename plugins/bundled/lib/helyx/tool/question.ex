defmodule Helyx.Tool.Question do
  @moduledoc """
  Asks the user one to four multiple-choice questions and waits for the
  answers (`Helyx.Tool.ask/1`). The request is a `form` UI block,
  `%{"kind" => "form", "text" => "<n> question(s)", "questions" => questions}`,
  with the checked arguments, `multi_select` filled in; its `text` is the
  count of the questions (`docs/features/ui-blocks.md`). A client answers
  with `%{"answers" => answers}`, one item for each question in order:
  `"selected"`, the picked labels (at most one without `multi_select`), and
  `"other"`, a text of the user, or absent; an item needs one of them. With
  no client that can answer, the tool returns at once and tells the model to
  decide. The design and the bounds are in
  `docs/features/question-tool.md`.
  """

  @behaviour Helyx.Tool

  alias Helyx.Tool.Args

  @no_client "No user can answer in this run. Decide yourself, state the assumption in " <>
               "your answer, and go on."
  @bad_answer "question: the answer of the client did not fit the questions"

  # The most code points of a header. A code point takes at most 4 bytes, so
  # the byte bound of the schema keeps the count over a short text.
  @header_chars 12
  @header_bytes @header_chars * 4

  @impl true
  def name, do: "question"

  @impl true
  def description do
    "Ask the user one to four multiple-choice questions and wait for the answers. Use it " <>
      "when you need a decision or a fact from the user before you go on. Each question " <>
      "has two to four options; the user can also write another answer."
  end

  @impl true
  def parameters do
    option = %{
      "type" => "object",
      "properties" => %{
        "label" => %{
          "type" => "string",
          "minLength" => 1,
          "maxLength" => 60,
          "description" => "The option, 1 to 60 bytes"
        },
        "description" => %{
          "type" => "string",
          "maxLength" => 300,
          "description" => "What it means, 300 bytes at most"
        }
      },
      "required" => ["label", "description"]
    }

    question = %{
      "type" => "object",
      "properties" => %{
        "question" => %{
          "type" => "string",
          "minLength" => 1,
          "maxLength" => 1_000,
          "description" => "The full question, 1 to 1000 bytes"
        },
        "header" => %{
          "type" => "string",
          "minLength" => 1,
          "maxLength" => @header_bytes,
          "description" => "A short label, #{@header_chars} characters at most"
        },
        "options" => %{
          "type" => "array",
          "items" => option,
          "minItems" => 2,
          "maxItems" => 4
        },
        "multi_select" => %{
          "type" => "boolean",
          "default" => false,
          "description" => "More than one option can be picked"
        }
      },
      "required" => ["question", "header", "options"]
    }

    %{
      "type" => "object",
      "properties" => %{
        "questions" => %{
          "type" => "array",
          "items" => question,
          "minItems" => 1,
          "maxItems" => 4
        }
      },
      "required" => ["questions"]
    }
  end

  @impl true
  def run(args, _cwd) do
    with {:ok, args} <- Args.check(args, parameters()),
         {:ok, questions} <- checked(args["questions"]) do
      case Helyx.Tool.ask(form(questions)) do
        {:ok, answer} -> result(questions, answer)
        {:error, :no_client} -> {:ok, @no_client}
        {:error, :not_running} -> {:error, "question: the call no longer runs"}
      end
    end
  end

  # The text is a short line, not a copy of the questions, so the largest
  # request stays under the ask bound.
  defp form([_] = questions),
    do: %{"kind" => "form", "text" => "1 question", "questions" => questions}

  defp form(questions),
    do: %{"kind" => "form", "text" => "#{length(questions)} questions", "questions" => questions}

  # Each question in order, or the error of the first bad one. The schema
  # states the types and the sizes; the rules that it cannot state stay
  # here: the code points of a header and labels that differ.
  defp checked(questions) do
    questions
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, []}, fn {item, n}, {:ok, acc} ->
      case question(item) do
        :ok -> {:cont, {:ok, acc ++ [shape(item)]}}
        {:error, text} -> {:halt, {:error, "question #{n}: #{text}"}}
      end
    end)
  end

  # The fields of a question and of its options, with no other key that the
  # model sent.
  defp shape(item) do
    options = Enum.map(item["options"], &Map.take(&1, ["label", "description"]))
    item |> Map.take(~w(question header options multi_select)) |> Map.put("options", options)
  end

  defp question(item) do
    with :ok <- header(item["header"]), do: labels(item["options"])
  end

  defp header(text) do
    if length(String.to_charlist(text)) <= @header_chars,
      do: :ok,
      else: {:error, "header must be 1 to #{@header_chars} characters"}
  end

  defp labels(options) do
    if Enum.uniq_by(options, & &1["label"]) == options,
      do: :ok,
      else: {:error, "the option labels must differ"}
  end

  # The answer comes from a client, so it is checked against the questions.
  defp result(questions, %{"answers" => answers})
       when is_list(answers) and length(answers) == length(questions) do
    pairs = Enum.zip(questions, answers)

    if Enum.all?(pairs, &answer?/1),
      do: {:ok, "The user answered:\n\n" <> Enum.map_join(pairs, "\n\n", &text/1)},
      else: {:error, @bad_answer}
  end

  defp result(_questions, _answer), do: {:error, @bad_answer}

  defp answer?({question, %{"selected" => selected} = answer}) when is_list(selected) do
    labels = Enum.map(question["options"], & &1["label"])
    other = answer["other"]
    most = if question["multi_select"], do: length(labels), else: 1

    Enum.all?(selected, &(&1 in labels)) and selected == Enum.uniq(selected) and
      length(selected) <= most and (other == nil or (is_binary(other) and other != "")) and
      (selected != [] or other != nil)
  end

  defp answer?(_pair), do: false

  defp text({question, answer}) do
    other = if answer["other"], do: ["other: " <> answer["other"]], else: []
    picked = if answer["selected"] == [], do: [], else: [Enum.join(answer["selected"], ", ")]
    "Q: #{question["question"]}\nA: #{Enum.join(picked ++ other, "; ")}"
  end
end
