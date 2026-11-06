defmodule Helyx.TUI.UIBlocksTest do
  # The UI blocks in the TUI (docs/features/ui-blocks.md, "Rendering in the
  # TUI"): the fold of `:ui_block` events, the blocks of a tool result, the
  # fallback text of a kind that the TUI does not know, and the picker by
  # the kind of an ask.
  use ExUnit.Case, async: true

  alias Helyx.{Event, Message}
  alias Helyx.Message.ToolCall
  alias Helyx.Session.Snapshot
  alias Helyx.TUI.{Question, ViewModel}

  import Helyx.Test.TUIRender, only: [texts: 1, texts: 2, view_model: 1]

  defp events(specs) do
    specs
    |> Enum.with_index(1)
    |> Enum.map(fn {{type, data}, seq} ->
      %Event{type: type, session_id: "s", instance_id: "i", turn_id: "t", seq: seq, data: data}
    end)
  end

  defp fold(vm \\ view_model([]), specs),
    do: Enum.reduce(events(specs), vm, &ViewModel.apply(&2, &1))

  defp call(id, name \\ "bash"), do: %ToolCall{id: id, name: name, arguments: %{}}

  defp calls(ids) do
    message = %Message{
      role: :assistant,
      content: Enum.map(ids, &call/1),
      model: "m",
      stop_reason: :tool_use
    }

    {:message_end, %{message: message}}
  end

  defp block(text, fields \\ %{}), do: Map.merge(%{"kind" => "progress", "text" => text}, fields)

  defp shown(call_id, key, text, fields \\ %{}),
    do: {:ui_block, %{call_id: call_id, key: key, block: block(text, fields)}}

  defp result(id, text, blocks \\ []) do
    message = %{Message.tool_result(call(id), {:ok, text}) | ui_blocks: blocks}
    {:tool_execution_end, %{message: message}}
  end

  defp keys(vm),
    do: for(%{call_id: id, key: key, block: b} <- vm.ui_blocks, do: {id, key, b["text"]})

  describe "the fold of :ui_block" do
    test "a later block with the same call id and key replaces the earlier one in place" do
      vm =
        fold([
          {:turn_start, %{}},
          calls(["c1"]),
          shown("c1", "a", "a 1"),
          shown(nil, "a", "turn a"),
          shown("c1", "b", "b 1"),
          shown("c1", "a", "a 2")
        ])

      assert keys(vm) == [{"c1", "a", "a 2"}, {nil, "a", "turn a"}, {"c1", "b", "b 1"}]
    end

    test "the result of a call drops its blocks, and turn_end drops all" do
      vm =
        fold([
          {:turn_start, %{}},
          calls(["c1", "c2"]),
          shown("c1", "a", "one"),
          shown("c2", "a", "two"),
          shown(nil, "a", "turn"),
          result("c1", "done")
        ])

      assert keys(vm) == [{"c2", "a", "two"}, {nil, "a", "turn"}]
      vm = ViewModel.apply(vm, %{hd(events([{:turn_end, %{outcome: :done}}])) | seq: 100})
      assert vm.ui_blocks == []
    end

    test "the snapshot sets the blocks" do
      data = %{call_id: nil, key: "k", block: block("from the snapshot")}

      snapshot = %{
        base_snapshot()
        | ui_blocks: [data],
          turn: %{id: "t", partial: nil, elapsed_ms: 0}
      }

      vm = ViewModel.from_snapshot(snapshot)
      assert vm.ui_blocks == [data]
      assert texts(vm) == ["  ▪ from the snapshot"]
    end
  end

  describe "the render" do
    test "a call's blocks show under its call line while it runs, nil blocks at the end" do
      vm =
        fold([
          {:turn_start, %{}},
          calls(["c1"]),
          shown(nil, "t", "turn line"),
          shown("c1", "p", "50%", %{"cut" => true})
        ])

      assert texts(vm) == [
               "⚙ bash",
               "… awaiting result",
               "  ▪ 50%",
               "    [cut]",
               "  ▪ turn line"
             ]
    end

    test "a block of a call in the streaming message shows under that call" do
      vm =
        fold([
          {:turn_start, %{}},
          {:message_start, %{message: %Message{role: :assistant, content: []}}},
          {:message_update, %{tool_call: call("c9")}},
          shown("c9", "p", "streamed")
        ])

      assert texts(vm) == ["⚙ bash", "… awaiting result", "  ▪ streamed"]
    end

    test "a tool result shows its blocks under it, with the cut mark and the short form" do
      long = Enum.map_join(1..6, "\n", &"line #{&1}")
      blocks = [block("short"), %{"kind" => "table", "text" => long, "cut" => true, "rows" => []}]
      vm = fold([{:turn_start, %{}}, calls(["c1"]), result("c1", "out", blocks)])

      assert texts(vm) == [
               "⚙ bash",
               "  out",
               "  ▪ short",
               "  ▪ line 1",
               "    line 2",
               "    line 3",
               "    line 4",
               "  … 2 more lines (ctrl+o to expand)",
               "    [cut]"
             ]

      expanded = vm |> ViewModel.toggle_expanded() |> texts()
      assert "    line 6" in expanded
      refute Enum.any?(expanded, &String.contains?(&1, "more lines"))
    end

    test "a block text loses its control characters and escape sequences, and wraps" do
      text = "a\e]0;title\a\e[31mred\u009B2J" <> String.duplicate("x", 30)
      vm = fold([{:turn_start, %{}}, calls(["c1"]), result("c1", "out", [block(text)])])
      rows = texts(vm, 20)

      refute Enum.any?(rows, &String.match?(&1, ~r/[\x00-\x1F\x7F\x{80}-\x{9F}]/u))
      assert Enum.join(tl(tl(rows))) =~ "a]0;title[31mred2J"
      assert Enum.all?(rows, &(String.length(&1) <= 20))
    end
  end

  describe "the asks by kind" do
    defp ask(id, tool, request), do: %{ask_id: id, call_id: "c1", tool: tool, request: request}

    defp form, do: %{"kind" => "form", "text" => "1 question", "questions" => [question()]}

    defp question,
      do: %{
        "question" => "Which?",
        "header" => "Pick",
        "multi_select" => false,
        "options" => [
          %{"label" => "a", "description" => ""},
          %{"label" => "b", "description" => ""}
        ]
      }

    defp picked(asks) do
      vm = %{view_model([]) | asks: asks}
      Question.sync(%{vm: vm, question: nil}).question
    end

    test "a form gets the picker, also from another tool" do
      assert %Question{ask_id: "x"} = picked([ask("x", "other", form())])
    end

    test "a request with no kind gets the picker by the tool name question" do
      request = %{"questions" => [question()]}
      assert %Question{ask_id: "x"} = picked([ask("x", "question", request)])
      assert picked([ask("x", "other", request)]) == nil
    end

    test "a kind that the TUI does not know shows its text under its call and gets no picker" do
      unknown = ask("u", "gate", %{"kind" => "approval", "text" => "allow rm?", "action" => "rm"})
      assert picked([unknown]) == nil
      assert %Question{ask_id: "f"} = picked([unknown, ask("f", "question", form())])

      vm = fold([{:turn_start, %{}}, calls(["c1"]), {:ask, unknown}])
      assert texts(vm) == ["⚙ bash", "… awaiting result", "  ▪ allow rm?"]

      vm =
        ViewModel.apply(vm, %{hd(events([{:ask_end, %{ask_id: "u", outcome: :ended}}])) | seq: 99})

      assert texts(vm) == ["⚙ bash", "… awaiting result"]
    end
  end

  describe "the form fields" do
    defp opt(label, description \\ ""), do: %{"label" => label, "description" => description}

    defp item(fields \\ %{}),
      do:
        Map.merge(
          %{
            "question" => "Which?",
            "header" => "Pick",
            "multi_select" => false,
            "options" => [opt("a"), opt("b")]
          },
          fields
        )

    defp form_of(questions),
      do: %{"kind" => "form", "text" => "the form", "questions" => questions}

    defp broken_forms do
      [
        no_questions: %{"kind" => "form", "text" => "the form"},
        questions_text: form_of("x"),
        questions_empty: form_of([]),
        five_questions: form_of(List.duplicate(item(), 5)),
        no_options: form_of([item(%{"options" => []})]),
        question_1001: form_of([item(%{"question" => String.duplicate("q", 1_001)})]),
        header_13: form_of([item(%{"header" => String.duplicate("é", 13)})]),
        label_61: form_of([item(%{"options" => [opt(String.duplicate("l", 61)), opt("b")]})]),
        duplicate_labels: form_of([item(%{"options" => [opt("a"), opt("a", "other")]})]),
        multi_select_text: form_of([item(%{"multi_select" => "yes"})])
      ]
    end

    test "a form with a field out of bounds gets no picker and shows its text" do
      for {name, request} <- broken_forms() do
        broken = ask("f", "other", request)
        refute Question.picker?(broken), "#{name} got the picker"
        assert picked([broken]) == nil, "#{name} got the picker"
        # The ask after it still gets the picker.
        assert %Question{ask_id: "g"} = picked([broken, ask("g", "other", form())])

        vm = fold([{:turn_start, %{}}, calls(["c1"]), {:ask, broken}])

        assert texts(vm) == ["⚙ bash", "… awaiting result", "  ▪ the form"],
               "#{name} did not show its text"
      end
    end

    test "a request with no kind from the question tool with broken fields gets no picker" do
      for {name, request} <- broken_forms() do
        request = Map.drop(request, ["kind", "text"])
        broken = ask("f", "question", request)
        refute Question.picker?(broken), "#{name} got the picker"
        assert picked([broken]) == nil, "#{name} got the picker"
        vm = fold([{:turn_start, %{}}, calls(["c1"]), {:ask, broken}])
        assert texts(vm) == ["⚙ bash", "… awaiting result"]
      end
    end

    test "a form at every bound gets the picker, which renders" do
      at_bound =
        item(%{
          "question" => String.duplicate("q", 1_000),
          # 12 code points of 4 bytes: 48 bytes.
          "header" => String.duplicate("😀", 12),
          "multi_select" => true,
          "options" =>
            for(
              i <- 1..4,
              do: opt(String.pad_trailing("#{i}", 60, "l"), String.duplicate("d", 300))
            )
        })

      [first_option | _] = at_bound["options"]
      assert byte_size(first_option["label"]) == 60
      ask = ask("x", "other", form_of(List.duplicate(at_bound, 4)))
      assert Question.picker?(ask)
      assert %Question{ask_id: "x", questions: questions} = question = picked([ask])
      assert length(questions) == 4

      area = %ExRatatui.Layout.Rect{x: 0, y: 0, width: 80, height: 24}
      assert [_ | _] = Question.widgets(question, area)
    end
  end

  defp base_snapshot do
    %Snapshot{
      instance_id: "i",
      seq: 0,
      messages: [],
      turn: nil,
      model: "fake/m",
      queue: %{steers: 0, follow_ups: 0, running: 0, held: 0, waiting: 0},
      persisting: true,
      more: false,
      usage: %Helyx.Session.Totals{},
      context: nil
    }
  end
end
