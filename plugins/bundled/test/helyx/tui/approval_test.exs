defmodule Helyx.TUI.ApprovalTest do
  # The approval picker of the TUI (docs/features/approval-gate.md, "The TUI
  # renderer"): the TUI callbacks driven on a session with the approval
  # gate, and the choice of the picker by the fields of the request. Not
  # async: the env key `:approval_hook` of `helyx_plugins` is global.
  use ExUnit.Case, async: false

  alias ExRatatui.Event.{Key, Paste}
  alias Helyx.{Event, Message, Session}
  alias Helyx.Message.ToolCall
  alias Helyx.Provider.Fake
  alias Helyx.TUI
  alias Helyx.TUI.{Approval, Question, ViewModel}

  import Helyx.Test.TUIRender, only: [texts: 1, view_model: 1]

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    on_exit(fn -> Application.delete_env(:helyx_plugins, :approval_hook) end)
    core = :"tui_approval_#{System.unique_integer([:positive])}"

    start_supervised!(
      {Helyx.Core, name: core, plugins: [Fake, Helyx.Tool.Read, Helyx.Hook.Approval]}
    )

    File.write!(Path.join(dir, "a.txt"), "the file\n")
    %{core: core}
  end

  # A TUI on a session in `dir` whose model reads `path`, at the ask of the
  # gate.
  defp asked(core, dir, path \\ "a.txt") do
    model = "a_#{System.unique_integer([:positive])}"
    call = %ToolCall{id: "r1", name: "read", arguments: %{"path" => path}}
    :ok = Fake.script(core, model, [[call], ["Done."]])

    {:ok, session} =
      Session.start(core,
        model: "fake/#{model}",
        cwd: dir,
        sessions_dir: Path.join(dir, "sessions")
      )

    link = Helyx.Test.TUIWire.link(session)
    {:ok, state} = TUI.mount(session: link, terminal_size_fn: fn -> {80, 24} end, cwd: dir)
    assert_receive {ref, _branch} when ref == state.branch_ref
    :ok = Session.prompt(session, "go")
    until(state, &(&1.question != nil))
  end

  # The session events through the TUI until `done?` holds for the state.
  defp until(state, done?) do
    if done?.(state) do
      state
    else
      assert_receive {:helyx_event, _sub, %Event{}} = message, 5_000
      {:noreply, state} = TUI.handle_info(message, state)
      until(state, done?)
    end
  end

  # The turn end starts a branch task, whose git port must not outlive the
  # test (see tui_test.exs, `branch_reply/1`).
  defp ended(state) do
    %{branch_ref: ref} = state = until(state, &(not &1.vm.running?))
    assert_receive {^ref, _branch}
    state
  end

  defp press(state, code) do
    {:noreply, state} = TUI.handle_event(%Key{code: code, kind: "press", modifiers: []}, state)
    state
  end

  defp result(state) do
    [{:tool, _call, _line, %Message{} = result}] =
      for {:tool, _, _, _} = cell <- ViewModel.cells(state.vm), do: cell

    Message.text(result)
  end

  defp screen(state, width, height) do
    terminal = ExRatatui.init_test_terminal(width, height)
    :ok = ExRatatui.draw(terminal, TUI.render(state, %{width: width, height: height}))
    ExRatatui.get_buffer_content(terminal)
  end

  describe "in a session" do
    test "the picker shows the call; Enter on Allow runs it", %{core: core, tmp_dir: dir} do
      state = asked(core, dir)
      assert %Approval{cursor: 0} = state.question

      text = screen(state, 80, 24)
      assert text =~ "allow read?"
      assert text =~ ~s({"path":"a.txt"})
      assert text =~ "› Allow  (y)"
      assert text =~ "  Deny  (n)"

      # A paste and a typed key that is no option change nothing.
      {:noreply, pasted} = TUI.handle_event(%Paste{content: "y"}, state)
      assert pasted == state
      assert press(state, "x") == state

      state = press(state, "enter")
      assert screen(state, 80, 24) =~ "answer sent"
      assert press(state, "n") == state

      state = ended(state)
      assert state.question == nil
      assert result(state) =~ "the file"
    end

    test "Down and Enter, or n, deny the call; y allows it", %{core: core, tmp_dir: dir} do
      denied = "the hook Helyx.Hook.Approval denied the call: the user denied the call"

      state = asked(core, dir) |> press("down") |> press("enter") |> ended()
      assert result(state) == denied

      state = asked(core, dir) |> press("down") |> press("up") |> press("n") |> ended()
      assert result(state) == denied

      state = asked(core, dir) |> press("y") |> ended()
      assert result(state) =~ "the file"
    end

    test "long arguments show 8 rows and a row that says more", %{core: core, tmp_dir: dir} do
      state = asked(core, dir, String.duplicate("p", 2_000))
      text = screen(state, 80, 40)
      assert text =~ "… more arguments"
      # The rows in the box: the transcript shows the call too.
      rows = text |> String.split("\n") |> Enum.filter(&(&1 =~ "│" and &1 =~ "pppp"))
      assert length(rows) == 8
      state |> press("n") |> ended()
    end

    # The failure-path probe of round 1: the tail of the path is shown, or
    # the dim row marks it, and both options show, at every height.
    test "a short screen marks what it hides and shows both options", %{core: core, tmp_dir: dir} do
      state = asked(core, dir, String.duplicate("a", 150) <> "_TAIL_rm_rf")

      # A room of 3 to 5 rows is a height of 5 to 7: the footer has 2.
      for height <- 5..12 do
        text = screen(state, 80, height)
        box = text |> String.split("\n") |> Enum.filter(&(&1 =~ "│")) |> Enum.join("\n")
        assert box =~ "Allow  (y)", "height #{height}: #{text}"
        assert box =~ "Deny  (n)", "height #{height}: #{text}"
        assert box =~ "_TAIL_rm_rf" or box =~ "… more arguments", "height #{height}: #{text}"
      end

      text = screen(state, 80, 8)
      assert text =~ "… more arguments"
      refute text =~ "│{\"path\""
      state |> press("n") |> ended()
    end

    test "Escape aborts the turn, and the call does not run", %{core: core, tmp_dir: dir} do
      state = asked(core, dir) |> press("esc") |> ended()
      assert state.question == nil
      refute result(state) =~ "the file"
    end
  end

  describe "the choice of the picker" do
    defp ask(id, request), do: %{ask_id: id, call_id: "c1", tool: "gate", request: request}

    defp approval(fields \\ %{}),
      do:
        Map.merge(
          %{"kind" => "approval", "text" => "allow bash?", "tool" => "bash", "arguments" => "{}"},
          fields
        )

    defp picked(asks) do
      vm = %{view_model([]) | asks: asks}
      Question.sync(%{vm: vm, question: nil}).question
    end

    # The view model after the events of `specs`, `{type, data}` each.
    defp fold(specs) do
      specs
      |> Enum.with_index(1)
      |> Enum.reduce(view_model([]), fn {{type, data}, seq}, vm ->
        event = %Event{
          type: type,
          session_id: "s",
          instance_id: "i",
          turn_id: "t",
          seq: seq,
          data: data
        }

        ViewModel.apply(vm, event)
      end)
    end

    test "an approval with its fields gets the picker, provider nil or a string" do
      assert %Approval{ask_id: "x", title: "allow bash?", text: "{}", cut?: false} =
               picked([ask("x", approval())])

      assert %Approval{} = picked([ask("x", approval(%{"provider" => nil}))])
      assert %Approval{} = picked([ask("x", approval(%{"provider" => "codex"}))])
      assert %Approval{cut?: true} = picked([ask("x", approval(%{"cut" => true}))])
    end

    test "an approval with unreadable fields shows its text and gets no picker" do
      call = %ToolCall{id: "c1", name: "bash", arguments: %{}}
      message = %Message{role: :assistant, content: [call], model: "m", stop_reason: :tool_use}

      for broken <- [
            Map.delete(approval(), "tool"),
            Map.delete(approval(), "arguments"),
            approval(%{"tool" => 1}),
            approval(%{"arguments" => %{}}),
            approval(%{"provider" => 1})
          ] do
        refute Question.picker?(ask("u", broken))
        assert picked([ask("u", broken)]) == nil
        assert %Approval{ask_id: "g"} = picked([ask("u", broken), ask("g", approval())])

        vm =
          fold([
            {:turn_start, %{}},
            {:message_end, %{message: message}},
            {:ask, ask("u", broken)}
          ])

        assert texts(vm) == ["⚙ bash", "… awaiting result", "  ▪ allow bash?"]
      end
    end

    test "the oldest ask that has a picker shows, a form or an approval" do
      form = %{
        "kind" => "form",
        "text" => "1 question",
        "questions" => [
          %{
            "question" => "Which?",
            "header" => "Pick",
            "options" => [
              %{"label" => "a", "description" => ""},
              %{"label" => "b", "description" => ""}
            ]
          }
        ]
      }

      assert %Question{ask_id: "f"} = picked([ask("f", form), ask("x", approval())])
      assert %Approval{ask_id: "x"} = picked([ask("x", approval()), ask("f", form)])
    end

    test "the picker keeps 16,384 bytes of the arguments and its title is one line" do
      at = String.duplicate("é", 8_192)

      assert %Approval{text: ^at, cut?: false} =
               picked([ask("x", approval(%{"arguments" => at}))])

      over = at <> "a"

      assert %Approval{text: ^at, cut?: true} =
               picked([ask("x", approval(%{"arguments" => over}))])

      title = "allow\nbash\e[31m?" <> String.duplicate("t", 70_000)
      %Approval{title: shown} = picked([ask("x", approval(%{"text" => title}))])
      refute shown =~ "\n"
      refute shown =~ "\e"
      assert byte_size(shown) <= 1_024
    end

    test "the title is cut at 1,024 bytes, at a character boundary" do
      at = String.duplicate("t", 1_024)
      assert %Approval{title: ^at} = picked([ask("x", approval(%{"text" => at}))])
      assert %Approval{title: ^at} = picked([ask("x", approval(%{"text" => at <> "u"}))])

      # 1,025 bytes whose last character the cut splits.
      split = "t" <> String.duplicate("é", 512)
      kept = "t" <> String.duplicate("é", 511)
      assert %Approval{title: ^kept} = picked([ask("x", approval(%{"text" => split}))])
    end
  end

  describe "the layout of the picker" do
    # The picker of an approval with `arguments` drawn in a box of `width`
    # and `height`, as text.
    defp draw(fields, width, height) do
      request =
        Map.merge(
          %{"kind" => "approval", "text" => "allow bash?", "tool" => "bash", "arguments" => ""},
          fields
        )

      picker = Approval.new(%{ask_id: "x", request: request})
      area = %ExRatatui.Layout.Rect{x: 0, y: 0, width: width, height: height}
      terminal = ExRatatui.init_test_terminal(width, height)
      :ok = ExRatatui.draw(terminal, Approval.widgets(picker, area))
      {picker, ExRatatui.get_buffer_content(terminal)}
    end

    defp body_rows(text), do: text |> String.split("\n") |> Enum.filter(&(&1 =~ "│x"))

    # The box is 80 wide, so a row holds 78 characters.
    test "8 rows show with no dim row; 9 show 8 and the dim row" do
      {_picker, text} = draw(%{"arguments" => String.duplicate("x", 78 * 8)}, 80, 20)
      assert length(body_rows(text)) == 8
      refute text =~ "… more arguments"

      {_picker, text} = draw(%{"arguments" => String.duplicate("x", 78 * 8 + 1)}, 80, 20)
      assert length(body_rows(text)) == 8
      assert text =~ "… more arguments"
    end

    test "a request with cut true draws the dim row" do
      {_picker, text} = draw(%{"arguments" => "x", "cut" => true}, 80, 20)
      assert length(body_rows(text)) == 1
      assert text =~ "… more arguments"
    end

    test "with 3 to 5 rows of room the picker takes 5: the dim row and both options" do
      {picker, _text} = draw(%{"arguments" => String.duplicate("x", 500)}, 80, 5)

      for room <- 3..5 do
        assert Approval.rows(picker, 80, room) == 5
      end

      {_picker, text} = draw(%{"arguments" => String.duplicate("x", 500)}, 80, 5)
      assert body_rows(text) == []
      assert text =~ "… more arguments"
      assert text =~ "Allow  (y)"
      assert text =~ "Deny  (n)"

      # One row that fits shows with no dim row.
      {_picker, text} = draw(%{"arguments" => "x"}, 80, 5)
      assert length(body_rows(text)) == 1
      refute text =~ "… more arguments"
    end

    test "with fewer rows than 3 inside, the options share one line" do
      {_picker, text} = draw(%{"arguments" => String.duplicate("x", 500)}, 80, 4)
      assert text =~ "│… more arguments"
      assert text =~ "│› Allow  (y)    Deny  (n)"

      # One row that fits shows beside the options.
      {_picker, text} = draw(%{"arguments" => "x"}, 80, 4)
      assert length(body_rows(text)) == 1
      refute text =~ "… more arguments"

      {_picker, text} = draw(%{"arguments" => "x"}, 80, 3)
      assert text =~ "│… more arguments  › Allow  (y)    Deny  (n)"
    end
  end
end
