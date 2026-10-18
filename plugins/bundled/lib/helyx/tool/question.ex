defmodule Helyx.Tool.Question do
  @moduledoc """
  Asks the user one to four multiple-choice questions and waits for the
  answers (`Helyx.Tool.ask/1`). The request is `%{"questions" => questions}`
  with the checked arguments, `multi_select` filled in. A client answers
  with `%{"answers" => answers}`, one item for each question in order:
  `"selected"`, the picked labels (at most one without `multi_select`), and
  `"other"`, a text of the user, or absent; an item needs one of them. With
  no client that can answer, the tool returns at once and tells the model to
  decide. The design and the bounds are in
  `docs/features/question-tool.md`.
  """

  @behaviour Helyx.Tool

  @no_client "No user can answer in this run. Decide yourself, state the assumption in " <>
               "your answer, and go on."
  @bad_answer "question: the answer of the client did not fit the questions"

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
        "label" => %{"type" => "string", "description" => "The option, 1 to 60 bytes"},
        "description" => %{
          "type" => "string",
          "description" => "What it means, 300 bytes at most"
        }
      },
      "required" => ["label", "description"]
    }

    question = %{
      "type" => "object",
      "properties" => %{
        "question" => %{"type" => "string", "description" => "The full question, 1 to 1000 bytes"},
        "header" => %{"type" => "string", "description" => "A short label, 12 characters at most"},
        "options" => %{"type" => "array", "items" => option, "minItems" => 2, "maxItems" => 4},
        "multi_select" => %{
          "type" => "boolean",
          "description" => "More than one option can be picked"
        }
      },
      "required" => ["question", "header", "options"]
    }

    %{
      "type" => "object",
      "properties" => %{
        "questions" => %{"type" => "array", "items" => question, "minItems" => 1, "maxItems" => 4}
      },
      "required" => ["questions"]
    }
  end

  @impl true
  def run(%{"questions" => questions}, _cwd)
      when is_list(questions) and length(questions) in 1..4 do
    with {:ok, questions} <- check(questions) do
      case Helyx.Tool.ask(%{"questions" => questions}) do
        {:ok, answer} -> result(questions, answer)
        {:error, :no_client} -> {:ok, @no_client}
        {:error, :not_running} -> {:error, "question: the call no longer runs"}
      end
    end
  end

  def run(_args, _cwd), do: {:error, "question needs questions, a list of 1 to 4 questions"}

  # Each question in order, or the error of the first bad one.
  defp check(questions) do
    questions
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, []}, fn {item, n}, {:ok, acc} ->
      case question(item) do
        {:ok, checked} -> {:cont, {:ok, acc ++ [checked]}}
        {:error, text} -> {:halt, {:error, "question #{n}: #{text}"}}
      end
    end)
  end

  defp question(%{"question" => text, "header" => header, "options" => options} = item) do
    multi? = Map.get(item, "multi_select", false)

    cond do
      not bytes?(text, 1, 1_000) ->
        {:error, "question must be 1 to 1000 bytes"}

      not header?(header) ->
        {:error, "header must be 1 to 12 characters"}

      not is_boolean(multi?) ->
        {:error, "multi_select must be a boolean"}

      true ->
        with {:ok, options} <- options(options), do: {:ok, checked(text, header, options, multi?)}
    end
  end

  defp question(_item), do: {:error, "needs question, header, and options"}

  defp checked(text, header, options, multi?),
    do: %{"question" => text, "header" => header, "options" => options, "multi_select" => multi?}

  defp options(options) when is_list(options) and length(options) in 2..4 do
    cond do
      not Enum.all?(options, &option?/1) ->
        {:error,
         "each option needs a label of 1 to 60 bytes and a description of 300 bytes at most"}

      Enum.uniq_by(options, & &1["label"]) != options ->
        {:error, "the option labels must differ"}

      true ->
        {:ok, Enum.map(options, &Map.take(&1, ["label", "description"]))}
    end
  end

  defp options(_options), do: {:error, "options must be a list of 2 to 4 items"}

  defp option?(%{"label" => label, "description" => text}),
    do: bytes?(label, 1, 60) and bytes?(text, 0, 300)

  defp option?(_option), do: false

  defp bytes?(text, min, max), do: is_binary(text) and byte_size(text) in min..max

  # 12 code points take at most 48 bytes, so the count reads a short text.
  defp header?(header),
    do: bytes?(header, 1, 48) and length(String.to_charlist(header)) <= 12

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
