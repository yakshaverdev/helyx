defmodule Helyx.Tool.QuestionTest do
  # The question tool: the checks of its arguments at their bounds, the ask
  # and the answer, a run with no client, and a bad answer
  # (docs/features/question-tool.md).
  use ExUnit.Case, async: true

  import Helyx.Test.Events, only: [collect_until: 1, of_type: 2]

  alias Helyx.{Message, Session}
  alias Helyx.Message.ToolCall
  alias Helyx.Provider.Fake
  alias Helyx.Tool.Question

  setup do
    core = :"core_#{System.unique_integer([:positive])}"
    start_supervised!({Helyx.Core, name: core, plugins: [Fake, Question]}, id: core)
    %{core: core}
  end

  defp option(label, description \\ "it"), do: %{"label" => label, "description" => description}

  defp item(fields \\ %{}),
    do:
      Map.merge(
        %{
          "question" => "Which one?",
          "header" => "Pick",
          "options" => [option("a"), option("b")]
        },
        fields
      )

  # Arguments that pass the checks reach the ask, which raises outside a
  # tool call; a bad one gives its error result first.
  defp check(questions) do
    Question.run(%{"questions" => questions}, ".")
  rescue
    e in ArgumentError ->
      assert e.message == "context/0 runs only in a tool call"
      :passes
  end

  defp error(questions) do
    assert {:error, text} = check(questions)
    text
  end

  test "1 to 4 questions" do
    assert check([item()]) == :passes
    assert check(List.duplicate(item(), 4)) == :passes
    assert error([]) =~ "a list of 1 to 4 questions"
    assert error(List.duplicate(item(), 5)) =~ "a list of 1 to 4 questions"
    assert {:error, _} = Question.run(%{"questions" => "one"}, ".")
    assert {:error, _} = Question.run(%{}, ".")
  end

  test "2 to 4 options with labels that differ" do
    four = for label <- ~w(a b c d), do: option(label)
    assert check([item(%{"options" => four})]) == :passes

    assert error([item(%{"options" => [option("a")]})]) ==
             "question 1: options must be a list of 2 to 4 items"

    assert error([item(), item(%{"options" => four ++ [option("e")]})]) =~
             "question 2: options must"

    assert error([item(%{"options" => [option("a"), option("a")]})]) =~ "labels must differ"
    assert error([item(%{"options" => "a, b"})]) =~ "options must be a list"
  end

  test "a question of 1 to 1000 bytes" do
    assert check([item(%{"question" => String.duplicate("a", 1_000)})]) == :passes
    assert check([item(%{"question" => String.duplicate("é", 500)})]) == :passes
    assert error([item(%{"question" => String.duplicate("a", 1_001)})]) =~ "1 to 1000 bytes"
    assert error([item(%{"question" => String.duplicate("é", 500) <> "a"})]) =~ "1 to 1000 bytes"
    assert error([item(%{"question" => ""})]) =~ "1 to 1000 bytes"
    assert error([item(%{"question" => 1})]) =~ "1 to 1000 bytes"
  end

  test "a header of 1 to 12 characters" do
    assert check([item(%{"header" => String.duplicate("a", 12)})]) == :passes
    assert check([item(%{"header" => String.duplicate("😀", 12)})]) == :passes
    assert error([item(%{"header" => String.duplicate("é", 13)})]) =~ "1 to 12 characters"
    assert error([item(%{"header" => String.duplicate("😀", 13)})]) =~ "1 to 12 characters"
    assert error([item(%{"header" => ""})]) =~ "1 to 12 characters"
  end

  test "a label of 1 to 60 bytes and a description of at most 300" do
    passes = [option(String.duplicate("a", 60), String.duplicate("é", 150)), option("b", "")]
    assert check([item(%{"options" => passes})]) == :passes

    for bad <- [
          option(String.duplicate("a", 61)),
          option(String.duplicate("é", 30) <> "a"),
          option(""),
          option("b", String.duplicate("a", 301)),
          %{"label" => "b"},
          "b"
        ] do
      assert error([item(%{"options" => [option("a"), bad]})]) =~ "each option needs"
    end
  end

  test "multi_select is a boolean, and a question needs its three keys" do
    assert check([item(%{"multi_select" => true})]) == :passes
    assert error([item(%{"multi_select" => "yes"})]) =~ "multi_select must be a boolean"
    assert error([Map.delete(item(), "header")]) =~ "needs question, header, and options"
    assert error(["Which one?"]) =~ "needs question, header, and options"
  end

  test "the largest request is under the bound of an ask" do
    # Each byte a control character, six bytes of JSON.
    c = <<1>>
    labels = for x <- ~w(a b c d), do: String.duplicate(c, 59) <> x
    options = for label <- labels, do: option(label, String.duplicate(c, 300))

    question = %{
      "question" => String.duplicate(c, 1_000),
      "header" => String.duplicate(c, 12),
      "options" => options,
      "multi_select" => false
    }

    assert check([question]) == :passes
    size = byte_size(JSON.encode!(%{"questions" => List.duplicate(question, 4)}))
    assert size > 50_000 and size < 65_536
  end

  defp run(core, arguments, subscribe_opts) do
    model = "q_#{System.unique_integer([:positive])}"
    call = %ToolCall{id: "q1", name: "question", arguments: arguments}
    :ok = Fake.script(core, model, [[call], ["Done."]])
    {:ok, session} = Session.start(core, model: "fake/#{model}")
    {:ok, _snapshot, _ref} = Session.subscribe(session, subscribe_opts)
    :ok = Session.prompt(session, "go")
    session
  end

  defp result(events) do
    [%{message: message}] = of_type(events, :tool_execution_end)
    {message.is_error, Message.text(message)}
  end

  test "the client gets the questions and the answers come back as the result", %{core: core} do
    multi = item(%{"question" => "Which ones?", "multi_select" => true, "extra" => 1})
    session = run(core, %{"questions" => [item(), multi]}, answers: true)

    [ask] = of_type(collect_until(:ask), :ask)
    assert ask.tool == "question"

    assert ask.request == %{
             "questions" => [
               Map.put(item(), "multi_select", false),
               Map.delete(multi, "extra")
             ]
           }

    answer = %{
      "answers" => [
        %{"selected" => [], "other" => "neither"},
        %{"selected" => ["a", "b"], "other" => "and c"}
      ]
    }

    assert Session.answer(session, ask.ask_id, answer) == :ok

    assert result(collect_until(:turn_end)) ==
             {false,
              "The user answered:\n\nQ: Which one?\nA: other: neither\n\n" <>
                "Q: Which ones?\nA: a, b; other: and c"}
  end

  test "with no client the tool tells the model to decide", %{core: core} do
    run(core, %{"questions" => [item()]}, [])

    assert result(collect_until(:turn_end)) ==
             {false,
              "No user can answer in this run. Decide yourself, state the assumption in " <>
                "your answer, and go on."}
  end

  test "an answer that does not fit the questions gives an error result", %{core: core} do
    for bad <- [
          %{},
          %{"answers" => []},
          %{"answers" => [%{"selected" => ["c"]}]},
          %{"answers" => [%{"selected" => ["a", "b"]}]},
          %{"answers" => [%{"selected" => ["a", "a"]}]},
          %{"answers" => [%{"selected" => []}]},
          %{"answers" => [%{"selected" => [], "other" => ""}]},
          %{"answers" => [%{"selected" => "a"}]},
          %{"answers" => [%{"other" => "x"}]},
          %{"answers" => [%{"selected" => ["a"]}, %{"selected" => ["a"]}]}
        ] do
      session = run(core, %{"questions" => [item()]}, answers: true)
      [%{ask_id: id}] = of_type(collect_until(:ask), :ask)
      assert Session.answer(session, id, bad) == :ok

      assert result(collect_until(:turn_end)) ==
               {true, "question: the answer of the client did not fit the questions"}
    end
  end
end
