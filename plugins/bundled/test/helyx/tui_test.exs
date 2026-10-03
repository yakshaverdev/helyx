defmodule Helyx.TUI.Test.Tool.Slow do
  @moduledoc false
  # Sleeps, so a test can hold a turn open while it fills the queues.
  @behaviour Helyx.Tool

  @impl true
  def name, do: "slow"
  @impl true
  def description, do: "Sleeps, then echoes."
  @impl true
  def parameters, do: %{"type" => "object"}
  @impl true
  def run(%{"ms" => ms, "text" => text}, _cwd) do
    Process.sleep(ms)
    {:ok, text}
  end
end

defmodule Helyx.TUI.Test.Provider.Other do
  @moduledoc false
  # A second provider module, so a test can switch away from Fake and back.
  use Helyx.Provider.Loop

  @impl true
  def id, do: "other"

  @impl true
  def stream(_model, _context, _opts) do
    {:ok, [{:text_delta, "from other"}, {:done, %{stop_reason: :end_turn, usage: %{}}}]}
  end
end

defmodule Helyx.TUITest do
  # The app callbacks, driven directly: mount subscribes the caller, key
  # events edit and send the composer, session events fold into the view
  # model. The fold itself is tested in view_model_test.exs.
  use ExUnit.Case, async: true

  import Helyx.Test.TUIRender

  alias ExRatatui.Event.Key
  alias ExRatatui.Layout.Rect
  alias ExRatatui.Widgets.Paragraph
  alias Helyx.{Event, Message, Session}
  alias Helyx.Provider.Fake
  alias Helyx.TUI
  alias Helyx.TUI.{Transcript, ViewModel}

  setup do
    core = :"tui_core_#{System.unique_integer([:positive])}"

    plugins = [
      Fake,
      Helyx.TUI.Test.Provider.Other,
      Helyx.TUI.Test.Tool.Slow
    ]

    start_supervised!({Helyx.Core, name: core, plugins: plugins})
    %{core: core}
  end

  defp mounted(core, model, responses) do
    :ok = Fake.script(core, model, responses)
    {:ok, session} = Session.start(core, model: "fake/#{model}")
    {:ok, state} = TUI.mount(session: session)
    state
  end

  defp press(state, code, modifiers \\ []) do
    {:noreply, state} =
      TUI.handle_event(%Key{code: code, kind: "press", modifiers: modifiers}, state)

    state
  end

  defp status_text(state) do
    {%ExRatatui.Widgets.Paragraph{text: line}, _rect} =
      state |> TUI.render(%{width: 120, height: 10}) |> List.last()

    Enum.map_join(line.spans, & &1.content)
  end

  # Feeds arriving session events through handle_info until agent_end.
  defp drain(state) do
    receive do
      {:helyx_event, %Event{} = event} ->
        {:noreply, state} = TUI.handle_info({:helyx_event, event}, state)
        if event.type == :agent_end, do: state, else: drain(state)
    after
      Helyx.Test.Events.wait_ms() -> flunk("no agent_end; view model: #{inspect(state.vm)}")
    end
  end

  test "the optional-dependency guard matches what is loaded" do
    # ex_ratatui is always present in this project. The build without it is
    # checked with a scratch product, see ADR 0005.
    for guard <- [
          Helyx.TUI.Available,
          Helyx.TUI.Composer.Available,
          Helyx.TUI.Transcript.Available
        ] do
      assert guard.available?()
      refute guard.__mix_recompile__?()
    end
  end

  test "a rejected send keeps the composer text", %{core: core} do
    call = %Helyx.Message.ToolCall{
      id: "c",
      name: "slow",
      arguments: %{"ms" => 60_000, "text" => "x"}
    }

    state = mounted(core, "hold", [[call]])

    state = state |> press("g") |> press("o") |> press("enter")
    assert_receive {:helyx_event, %Event{type: :tool_execution_start}}

    for n <- 1..32, do: :ok = Session.steer(state.session, "s#{n}")

    state = state |> press("x") |> press("enter")
    assert ExRatatui.textarea_get_value(state.composer.input) == "x"
    assert state.vm.reason == "not sent: the queue is full"
    assert status_text(state) =~ "not sent: the queue is full"

    # The line does not wrap, so the reason comes before a long model ref.
    long = %{state | vm: %{state.vm | model: String.duplicate("m", 256)}}
    assert String.starts_with?(status_text(long), " ✕ not sent: the queue is full ")

    # The release and the repeat of the rejected Enter keep the reason, and
    # do not edit the composer.
    for kind <- ["release", "repeat"] do
      {:noreply, kept} = TUI.handle_event(%Key{code: "enter", kind: kind}, state)
      assert kept.vm.reason == "not sent: the queue is full"
      assert ExRatatui.textarea_get_value(kept.composer.input) == "x"
    end

    # Enter again is a key press and a reject at once: the reason stays set.
    state = press(state, "enter")
    assert state.vm.reason == "not sent: the queue is full"

    # The follow-up queue has its own cap.
    for n <- 1..32, do: :ok = Session.follow_up(state.session, "f#{n}")
    state = state |> press("left") |> press("enter", ["alt"])
    assert state.vm.reason == "not sent: the queue is full"

    state = press(state, "y")
    assert state.vm.reason == nil
    assert ExRatatui.textarea_get_value(state.composer.input) == "yx"
    refute status_text(state) =~ "not sent"
  end

  test "a paste and a modified key clear the reason", %{core: core} do
    state = mounted(core, "clear", [])

    for event <- [
          %ExRatatui.Event.Paste{content: "p"},
          %Key{code: "x", kind: "press", modifiers: ["ctrl"]}
        ] do
      rejected = %{state | vm: ViewModel.reject(state.vm, "r")}
      {:noreply, cleared} = TUI.handle_event(event, rejected)
      assert cleared.vm.reason == nil
    end
  end

  test "typing edits the composer and ignores command keys", %{core: core} do
    state = mounted(core, "typing", [])

    state = state |> press("h") |> press("i") |> press("!", ["shift"])
    assert ExRatatui.textarea_get_value(state.composer.input) == "hi!"

    state = press(state, "backspace")
    assert ExRatatui.textarea_get_value(state.composer.input) == "hi"

    state = state |> press("x", ["ctrl"]) |> press("f1")
    assert ExRatatui.textarea_get_value(state.composer.input) == "hi"

    # The widget owns the cursor: Home then typing inserts at the front.
    state = state |> press("home") |> press("a")
    assert ExRatatui.textarea_get_value(state.composer.input) == "ahi"

    {:noreply, state} = TUI.handle_event(%ExRatatui.Event.Paste{content: " there"}, state)
    assert ExRatatui.textarea_get_value(state.composer.input) == "a therehi"
  end

  test "enter sends the composer and the answer streams into the view model", %{core: core} do
    state = mounted(core, "answer", [["Hello ", "there."]])

    state = state |> press("h") |> press("i") |> press("enter")
    assert ExRatatui.textarea_get_value(state.composer.input) == ""

    state = drain(state)

    assert [%Helyx.Message{role: :user} = prompt, %Helyx.Message{role: :assistant} = answer] =
             state.vm.cells

    assert Helyx.Message.text(prompt) == "hi"
    assert Helyx.Message.text(answer) == "Hello there."
    refute state.vm.running?
  end

  test "alt+enter sends a follow-up and enter with an empty composer does nothing", %{core: core} do
    state = mounted(core, "later", [["Done."]])

    state = press(state, "enter")
    refute_received {:helyx_event, _}

    state = state |> press("g") |> press("o") |> press("enter", ["alt"])
    state = drain(state)
    assert [%Helyx.Message{role: :user}, %Helyx.Message{role: :assistant}] = state.vm.cells
  end

  test "escape aborts without blocking the caller", %{core: core} do
    state = mounted(core, "quiet", [])
    pid = Session.pid(state.session)
    :erlang.trace(pid, true, [:receive])
    {:noreply, _state} = TUI.handle_event(%Key{code: "esc", kind: "press"}, state)

    # The TUI's Task sends the abort. A later call returns after the session
    # handled it, and the session sends its events before its reply.
    assert_receive {:trace, ^pid, :receive, {:"$gen_call", _from, :abort}}
    :sys.get_state(pid)
    refute_received {:helyx_event, %Event{type: :agent_end}}
  end

  test "ctrl+c stops the app", %{core: core} do
    state = mounted(core, "bye", [])
    assert {:stop, _state} = TUI.handle_event(%Key{code: "c", modifiers: ["ctrl"]}, state)
  end

  test "the TUI exits on the end signal of its session, and only then", %{core: core} do
    state = mounted(core, "gone", [])

    # A `:DOWN` of another monitor in the TUI process does nothing.
    # spawn_monitor/1: a monitor set after spawn/1 can give `:noproc`.
    spawn_monitor(fn -> :ok end)
    assert_receive {:DOWN, _ref, :process, _pid, :normal} = other
    assert {:noreply, ^state} = TUI.handle_info(other, state)

    # The end signal of another session does nothing.
    other = {{:helyx_session_end, "other"}, make_ref(), :process, self(), :killed}
    assert {:noreply, ^state} = TUI.handle_info(other, state)

    Process.exit(Session.pid(state.session), :kill)
    id = state.session.id
    assert_receive {{:helyx_session_end, ^id}, _ref, :process, _pid, :killed} = signal
    assert catch_exit(TUI.handle_info(signal, state)) == {:session_down, :crashed}
  end

  @tag :tmp_dir
  test "a resumed session shows its history, then the notice only with resumed: true", %{
    core: core,
    tmp_dir: dir
  } do
    call = %Message.ToolCall{id: "c1", name: "slow", arguments: %{"ms" => 0, "text" => "slept"}}
    :ok = Fake.script(core, "history", [[call], ["hello there"]])
    {:ok, session} = Session.start(core, model: "fake/history", sessions_dir: dir, cwd: dir)
    {:ok, _} = Session.subscribe(session)
    :ok = Session.prompt(session, "hi")
    assert_receive {:helyx_event, %Event{type: :agent_end}}

    :ok =
      DynamicSupervisor.terminate_child(Helyx.Core.session_supervisor(core), Session.pid(session))

    assert Session.pid(session) == nil

    {:ok, resumed} = Session.resume(core, sessions_dir: dir, cwd: dir)
    {:ok, %{vm: vm}} = TUI.mount(session: resumed, resumed: true)

    # The live cell shapes: the user message, the assistant message and its
    # tool cell with the result, the reply, then the notice.
    assert [
             %Message{role: :user},
             %Message{role: :assistant, content: [^call]},
             {:tool, ^call, line, %Message{role: :tool_result} = result},
             %Message{role: :assistant} = reply,
             {:notice, "resumed session"}
           ] = vm.cells

    assert line == ViewModel.call_line(call)
    assert Message.text(result) == "slept"
    assert Message.text(reply) == "hello there"

    {:ok, %{vm: live}} = TUI.mount(session: resumed)
    assert live.cells == Enum.drop(vm.cells, -1)
  end

  # The review of #188, round 4, spec item 1: a resume keeps the session
  # id, and the new instance starts `seq` at 0 again. The old screen gets
  # events of the new instance only as stale messages of a later
  # subscription of its process.
  @tag :tmp_dir
  test "an event of a resumed instance does not change the screen of the old one (#204)", %{
    core: core,
    tmp_dir: dir
  } do
    # The second reply has more deltas than the first turn has events, so
    # its last events have a `seq` above the one of the old screen.
    :ok = Fake.script(core, "again", [["first"], List.duplicate("second ", 20)])
    {:ok, session} = Session.start(core, model: "fake/again", sessions_dir: dir, cwd: dir)
    {:ok, state} = TUI.mount(session: session)
    :ok = Session.prompt(session, "hi")
    state = drain(state)

    :ok =
      DynamicSupervisor.terminate_child(Helyx.Core.session_supervisor(core), Session.pid(session))

    assert_receive {{:helyx_session_end, _id}, _ref, :process, _pid, :shutdown}
    {:ok, resumed} = Session.resume(core, sessions_dir: dir, cwd: dir)
    {:ok, _} = Session.subscribe(resumed)
    :ok = Session.prompt(resumed, "again")

    assert drain(state) == state
  end

  test "mounting on a dead session exits instead of hanging", %{core: core} do
    :ok = Fake.script(core, "dead", [])
    {:ok, session} = Session.start(core, model: "fake/dead")

    pid = Session.pid(session)
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}

    # The Registry drops the dead entry later, but a lookup by name skips a
    # dead pid.
    assert Session.pid(session) == nil

    assert catch_exit(TUI.mount(session: session)) ==
             {:session_down, :session_not_found}

    assert Process.get({Session, core, session.id}) == nil
  end

  test "a send and a model switch to an ended session keep the composer", %{core: core} do
    state = mounted(core, "ended", [])
    :ok = GenServer.stop(Session.pid(state.session))

    state = state |> press("x") |> press("enter")
    assert ExRatatui.textarea_get_value(state.composer.input) == "x"
    assert state.vm.reason == "not sent: the session ended"

    state = state |> press("enter", ["alt"])
    assert state.vm.reason == "not sent: the session ended"

    ExRatatui.textarea_set_value(state.composer.input, "/model fake/other")
    state = press(state, "enter")
    assert List.last(state.vm.cells) == {:notice, "the session ended"}
    assert ExRatatui.textarea_get_value(state.composer.input) == "/model fake/other"
  end

  test "a snapshot of an unsupported contract version shows a message, not the session", %{
    core: core
  } do
    # A fake session that answers the subscribe call with version 3.
    id = "future"
    test = self()

    fake =
      spawn(fn ->
        {:ok, _} = Registry.register(Helyx.Core.sessions_registry(core), id, nil)
        send(test, :registered)

        receive do
          {:"$gen_call", from, {:subscribe, _pid}} ->
            GenServer.reply(from, %Session.Snapshot{
              contract_version: 3,
              instance_id: "i",
              seq: 7,
              messages: [%Message{role: :user, content: [%Message.Text{text: "secret"}]}],
              turn: nil,
              model: "fake/future",
              queue: %{steers: 0, follow_ups: 0}
            })

            Process.sleep(:infinity)
        end
      end)

    assert_receive :registered
    {:ok, state} = TUI.mount(session: %Session{id: id, core: core})

    assert [{%Paragraph{} = message, _rect}] = TUI.render(state, %{width: 80, height: 10})
    assert inspect(message) =~ "contract version"
    refute inspect(message) =~ "secret"

    # Session events and keys do nothing; Ctrl+C quits.
    event = %Event{
      type: :agent_end,
      session_id: id,
      instance_id: "i",
      turn_id: "t",
      seq: 8,
      data: %{}
    }

    assert {:noreply, ^state} = TUI.handle_info({:helyx_event, event}, state)
    assert {:noreply, ^state} = TUI.handle_event(%Key{code: "enter", kind: "press"}, state)
    assert {:stop, _state} = TUI.handle_event(%Key{code: "c", modifiers: ["ctrl"]}, state)

    # The end of the session still ends the TUI.
    Process.exit(fake, :kill)
    assert_receive {{:helyx_session_end, ^id}, _ref, :process, ^fake, :killed} = signal
    assert catch_exit(TUI.handle_info(signal, state)) == {:session_down, :crashed}
  end

  test "tool results truncate after four lines, ignoring a trailing newline" do
    call = %Helyx.Message.ToolCall{id: "c", name: "bash", arguments: %{}}

    texts = fn output ->
      result = Helyx.Message.tool_result(call, {:ok, output})

      vm = %ViewModel{
        ViewModel.new("fake/m")
        | cells: [{:tool, call, ViewModel.call_line(call), result}]
      }

      for line <- Transcript.lines(vm, 80), span <- line.spans, do: span.content
    end

    for at_or_under <- ["1\n2\n3", "1\n2\n3\n4", "1\n2\n3\n4\n"] do
      refute Enum.any?(texts.(at_or_under), &String.contains?(&1, "more"))
    end

    assert "  … 1 more line" in texts.("1\n2\n3\n4\n5")
    assert "  … 2 more lines" in texts.("1\n2\n3\n4\n5\n6")
    refute "  5" in texts.("1\n2\n3\n4\n5")
  end

  describe "wrapping by display width" do
    test "a narrow grapheme is one column, also with a combining mark" do
      assert wrapped(String.duplicate("a", 7), 5) == ["aaaaa", "aa"]

      assert wrapped(String.duplicate("e\u0301", 7), 5) == [
               String.duplicate("e\u0301", 5),
               String.duplicate("e\u0301", 2)
             ]
    end

    test "a CJK glyph is two columns, so no line goes past the width" do
      assert wrapped("日本語日本", 5) == ["日本", "語日", "本"]
      assert wrapped("a日本語", 5) == ["a日本", "語"]
      assert wrapped("한글ｆ", 4) == ["한글", "ｆ"]
    end

    test "an emoji, also one that a selector makes wide, is two columns" do
      for glyph <- ["\u2764\uFE0F", "✅", "👍"] do
        assert wrapped(String.duplicate(glyph, 3), 5) == [String.duplicate(glyph, 2), glyph]
      end
    end

    # ExRatatui draws each of these as two columns. The rule has no table of
    # the emoji sequences, so it counts each emoji in the grapheme.
    test "an emoji with a modifier, a joiner, or a flag is never split and never past the width" do
      thumb = "👍🏽"
      family = "👨\u200D👩\u200D👧"
      flag = "🇮🇳"

      for glyph <- [thumb, family, flag] do
        assert wrapped(String.duplicate(glyph, 3), 5) == [glyph, glyph, glyph]
      end

      assert wrapped(String.duplicate(thumb, 3), 8) == [thumb <> thumb, thumb]
    end

    test "a zero-width grapheme takes no column and stays on its line" do
      assert wrapped("abcde\u200B", 5) == ["abcde\u200B"]
    end

    test "a wide glyph at width one, and width zero, still give one glyph per line" do
      assert wrapped("日本", 1) == ["日", "本"]
      assert wrapped("ab", 0) == ["a", "b"]
    end

    test "an empty line is one empty row" do
      assert wrapped("", 5) == [""]
      assert wrapped("", 0) == [""]
    end

    # ExRatatui cuts a row at the edge of its area. A row that the width rule
    # counts too narrow loses a glyph here.
    test "the terminal library draws every wrapped row in full" do
      text = "a日本語ｆ한글👍🏽❤\uFE0F✅🇮🇳👨\u200D👩\u200D👧e\u0301⚡zक्षिस्त्रीநிกำｶﾞ🟠〈䷀z"

      # From 4: the widest glyph of the text is a Devanagari cluster of 4 columns.
      for width <- 4..11 do
        rows = Enum.reject(wrapped(text, width), &(&1 == ""))
        drawn = rows |> draw(width) |> String.replace(" ", "")
        assert drawn == Enum.join(rows, "\n"), "width #{width}"
      end
    end
  end

  test "control characters never reach the terminal" do
    call = %Helyx.Message.ToolCall{id: "c", name: "bash", arguments: %{}}
    result = Helyx.Message.tool_result(call, {:ok, "\e]0;evil\a\e[2Jcol1\tcol2\r"})

    vm = %ViewModel{
      ViewModel.new("fake/m")
      | cells: [
          Helyx.Message.user("hi\e[31m there"),
          {:tool, call, ViewModel.call_line(call), result}
        ]
    }

    texts = for line <- Transcript.lines(vm, 80), span <- line.spans, do: span.content

    assert "› hi[31m there" in texts
    assert "  ]0;evil[2Jcol1  col2" in texts
    refute Enum.any?(texts, &String.contains?(&1, "\e"))

    # Tool text is valid UTF-8 when it reaches the TUI (the session and
    # stream tests cover the repair), so a CSI is the character U+009B.
    csi = Helyx.Message.tool_result(call, {:ok, <<"a", 0x9B::utf8, "[2Jb">>})

    vm = %ViewModel{
      ViewModel.new("fake/m")
      | cells: [{:tool, call, ViewModel.call_line(call), csi}]
    }

    texts = for line <- Transcript.lines(vm, 80), span <- line.spans, do: span.content
    assert "  a[2Jb" in texts
  end

  test "the transcript renders width-bounded lines with tool cells" do
    call = %Helyx.Message.ToolCall{id: "c", name: "bash", arguments: %{"command" => "ls -la"}}
    result = Helyx.Message.tool_result(call, {:ok, "a\nb\nc\nd\ne\nf"})

    vm = %ViewModel{
      ViewModel.new("fake/m")
      | cells: [
          Helyx.Message.user("hello world"),
          {:tool, call, ViewModel.call_line(call), result}
        ],
        streaming: [%Helyx.Message.Text{text: String.duplicate("s", 35)}]
    }

    lines = Transcript.lines(vm, 30)
    texts = for line <- lines, span <- line.spans, do: span.content

    assert "› hello world" in texts
    assert Enum.any?(texts, &String.starts_with?(&1, "⚙ bash"))
    assert "  … 2 more lines" in texts
    assert String.duplicate("s", 30) in texts
    assert String.duplicate("s", 5) in texts
    assert Enum.all?(texts, &(String.length(&1) <= 30))
  end

  test "a tool call line is cut at 8,192 bytes" do
    # U+00A0 renders as `\u00A0` through `inspect/1`, and the keys are raw.
    arguments = Map.new(1..2_000, &{"k#{&1}", String.duplicate("\u00A0", 100)})
    call = %Helyx.Message.ToolCall{id: "c", name: "bash", arguments: arguments}

    vm = %ViewModel{
      ViewModel.new("fake/m")
      | cells: [{:tool, call, ViewModel.call_line(call), nil}]
    }

    texts = for line <- Transcript.lines(vm, 80), span <- line.spans, do: span.content
    {call_rows, ["… running"]} = Enum.split(texts, -1)
    call_line = Enum.join(call_rows)

    assert byte_size(call_line) in 8_190..8_192
    assert String.starts_with?(call_line, "⚙ bash k")
  end

  describe "scrollback" do
    # A 20 by 9 terminal: the transcript has 5 rows. Each message is one row
    # and one empty row. `resize/2` gives the terminal a new size.
    defp size, do: Process.get(:terminal_size, {20, 9})

    defp resize(state, size) do
      Process.put(:terminal_size, size)
      {:noreply, state} = TUI.handle_event(%ExRatatui.Event.Resize{}, state)
      state
    end

    defp fold(state, type, data) do
      event = %Event{
        type: type,
        session_id: "s",
        instance_id: state.vm.instance_id,
        turn_id: "t",
        seq: state.vm.seq + 1,
        data: data
      }

      {:noreply, state} = TUI.handle_info({:helyx_event, event}, state)
      state
    end

    defp scroll_state(core, count) do
      :ok = Fake.script(core, "scroll", [["ok"]])
      {:ok, session} = Session.start(core, model: "fake/scroll")

      {:ok, state} =
        TUI.mount(session: session, terminal_size_fn: &size/0)

      Enum.reduce(1..count//1, state, &say(&2, "m#{&1}"))
    end

    defp say(state, text), do: fold(state, :message_end, %{message: Helyx.Message.user(text)})

    defp screen(state) do
      {width, height} = size()
      [{%Paragraph{text: lines}, _rect} | _] = TUI.render(state, %{width: width, height: height})
      for line <- lines, span <- line.spans, do: span.content
    end

    test "PgUp and PgDn move one screen, new output does not move the view", %{core: core} do
      state = scroll_state(core, 10)
      assert screen(state) == ["› m9", "› m10"]
      refute status_text(state) =~ "scrolled"

      state = press(state, "page_up")
      assert screen(state) == ["› m6", "› m7", "› m8"]
      assert status_text(state) =~ "scrolled"

      state = say(state, "new")
      assert screen(state) == ["› m6", "› m7", "› m8"]

      state = press(state, "page_down")
      assert screen(state) == ["› m9", "› m10"]
      assert status_text(state) =~ "scrolled"

      state = press(state, "page_down")
      assert screen(state) == ["› m10", "› new"]
      refute status_text(state) =~ "scrolled"
    end

    test "the offset stops at the first row, and the same count of PgDn returns", %{core: core} do
      state = scroll_state(core, 6)
      up = Enum.reduce(1..50, state, fn _, acc -> press(acc, "page_up") end)
      assert screen(up) == ["› m1", "› m2", "› m3"]

      down = up |> press("page_down") |> press("page_down")
      assert down.scroll == nil
      assert screen(down) == ["› m5", "› m6"]
    end

    test "a transcript that fits the screen does not scroll", %{core: core} do
      state = core |> scroll_state(2) |> press("page_up")
      assert state.scroll == nil
      assert press(state, "page_down").scroll == nil
    end

    test "a position holds only when the rows to the end are more than one screen", %{core: core} do
      # 5 rows are one screen: a message of two rows, one of one row, and an
      # empty row after each. 4 rows and 5 rows do not scroll, 6 rows do.
      five = core |> scroll_state(0) |> say(String.duplicate("a", 30)) |> say("b")
      assert press(five, "page_up").scroll == nil
      assert press(scroll_state(core, 2), "page_up").scroll == nil
      assert press(scroll_state(core, 3), "page_up").scroll == {0, 0}
    end

    test "after a resize the row of the position is a row of its cell", %{core: core} do
      state = core |> scroll_state(0) |> say(String.duplicate("word ", 200))
      state = Enum.reduce(1..30, state, &say(&2, "m#{&1}"))
      state = Enum.reduce(1..13, state, fn _, acc -> press(acc, "page_up") end)
      assert {0, row} = state.scroll
      assert row > 20

      # At width 200 the first cell has 6 rows and the empty row.
      wide = resize(state, {200, 9})
      assert {index, row} = wide.scroll
      assert index > 0 and row < 2
      assert length(screen(wide)) in 2..3
    end

    test "a frame before the Resize event wraps only the cells on the screen", %{core: core} do
      state = core |> scroll_state(0) |> say(String.duplicate("a", 8_000))
      state = Enum.reduce(1..100, state, &say(&2, "m#{&1}"))
      state = Enum.reduce(1..61, state, fn _, acc -> press(acc, "page_up") end)
      assert {0, row} = state.scroll
      assert row > 200

      # The width changes, a typing key comes, and a frame is drawn. No check
      # of the position ran: the old row is far past the 41 rows of the cell.
      Process.put(:terminal_size, {200, 9})
      state = press(state, "x")
      assert {0, ^row} = state.scroll

      # Only the calls of the render process count: an async module that
      # renders at the same time calls the same function. A process cannot
      # trace its own calls, so the frame is drawn in another one.
      size = size()

      render =
        spawn_link(fn ->
          Process.put(:terminal_size, size)

          receive do
            {:go, test} -> send(test, {:rows, screen(state)})
          end

          receive do
            :stop -> :ok
          end
        end)

      wrap = {Transcript, :item_lines, 2}
      :erlang.trace_pattern(wrap, true, [:local])
      :erlang.trace(render, true, [:call])
      send(render, {:go, self()})
      assert_receive {:rows, rows}
      :erlang.trace_pattern(wrap, false, [:local])
      ref = :erlang.trace_delivered(render)
      assert_receive {:trace_delivered, ^render, ^ref}
      send(render, :stop)
      {:messages, messages} = Process.info(self(), :messages)

      wraps =
        Enum.count(messages, &match?({:trace, ^render, :call, {Transcript, :item_lines, _}}, &1))

      # The last row of the first cell is its empty row, then the next cells.
      assert wraps in 1..5
      assert rows == ["› m1", "› m2"]
    end

    test "a change of the composer height checks the position", %{core: core} do
      # Three new lines leave the transcript 2 rows; PgUp is then 4 rows from
      # the end. One line less gives 3 rows, two lines less give 4 rows: the
      # rest fits the screen, so the view follows the newest output again.
      state = scroll_state(core, 10)
      state = Enum.reduce(1..3, state, fn _, acc -> press(acc, "j", ["ctrl"]) end)
      state = press(state, "page_up")
      assert {_index, _row} = state.scroll

      state = press(state, "backspace")
      assert {_index, _row} = state.scroll
      assert press(state, "backspace").scroll == nil
    end

    test "on a small terminal the composer shrinks, so the drawn screen is the scroll screen",
         %{core: core} do
      # 11 rows: a full composer would leave the transcript no row. It gets
      # 9 rows, the transcript 1, and PgUp moves by that 1 row.
      Process.put(:terminal_size, {20, 11})
      state = scroll_state(core, 10)
      state = Enum.reduce(1..8, state, fn _, acc -> press(acc, "j", ["ctrl"]) end)

      [{_, transcript}, {_, composer}, _status] = TUI.render(state, %{width: 20, height: 11})
      assert {transcript.height, composer.height} == {1, 9}

      state = press(state, "page_up")
      assert screen(state) == ["› m10"]

      # At 6 rows the composer has 2 lines, at 5 one; below that the transcript has none.
      for {height, rows} <- [{6, {1, 4}}, {5, {1, 3}}, {4, {0, 3}}] do
        [{_, transcript}, {_, composer}, _] = TUI.render(state, %{width: 20, height: height})
        assert {transcript.height, composer.height} == rows
      end
    end

    test "an event at a moment with no terminal size returns to the newest output", %{core: core} do
      state = core |> scroll_state(10) |> press("page_up")
      Process.put(:terminal_size, {:error, :no_tty})
      assert say(state, "new").scroll == nil
    end

    test "Ctrl+End and a sent prompt return to the newest output", %{core: core} do
      state = core |> scroll_state(10) |> press("page_up")
      assert press(state, "end", ["ctrl"]).scroll == nil

      sent = state |> press("h") |> press("enter")
      assert sent.scroll == nil
      assert drain(sent).scroll == nil
    end

    test "with no terminal size the scroll keys return to the newest output", %{core: core} do
      state = scroll_state(core, 10)
      scrolled = press(state, "page_up")
      Process.put(:terminal_size, {:error, :no_tty})
      assert press(state, "page_up").scroll == nil
      assert press(scrolled, "page_up").scroll == nil
      assert press(scrolled, "page_down").scroll == nil
    end

    test "a notice while the view is in the open message keeps the row in its cell", %{core: core} do
      text = Enum.map_join(1..40, "\n", &"line#{&1}")

      state =
        core
        |> scroll_state(1)
        |> fold(:message_start, %{message: %Helyx.Message{role: :assistant, content: []}})
        |> fold(:message_update, %{text_delta: text})
        |> press("page_up")
        |> press("page_up")

      assert {1, row} = state.scroll
      {:noreply, state} = TUI.handle_event(%ExRatatui.Event.Paste{content: "/model"}, state)
      # The usage notice has three rows at width 20 and takes index 1.
      assert press(state, "enter").scroll == {2, row - 3}
    end

    test "one screen is the height minus 4 rows, and 1 row at that height or less", %{core: core} do
      for {height, rows} <- [{6, 2}, {5, 1}, {4, 1}, {3, 1}, {0, 1}] do
        Process.put(:terminal_size, {20, 9})
        state = scroll_state(core, 10)
        Process.put(:terminal_size, {20, height})
        # Row 19 is the empty row after m10, and row 18 is m10.
        assert press(state, "page_up").scroll == {div(20 - 2 * rows, 2), rem(20 - 2 * rows, 2)}
      end
    end

    test "the view moves by rows in a cell of wide glyphs, and no row is past the width",
         %{core: core} do
      # 60 glyphs of two columns at width 20: 6 rows, then the empty row.
      state = core |> scroll_state(0) |> say(String.duplicate("語", 59)) |> say("end")
      up = press(state, "page_up")
      assert up.scroll == {0, 0}

      assert screen(up) ==
               ["› " <> String.duplicate("語", 9)] ++ List.duplicate(String.duplicate("語", 10), 4)

      down = press(up, "page_down")
      assert down.scroll == nil
      glyphs = String.duplicate("語", 10)
      assert screen(down) == [glyphs, glyphs, "› end"]
    end

    test "a failed turn while the view is in the open message returns to the newest output",
         %{core: core} do
      text = Enum.map_join(1..40, "\n", &"line#{&1}")

      state =
        core
        |> scroll_state(1)
        |> fold(:message_start, %{message: %Helyx.Message{role: :assistant, content: []}})
        |> fold(:message_update, %{text_delta: text})
        |> press("page_up")
        |> press("page_up")

      assert {1, _row} = state.scroll
      assert screen(state) == Enum.map(27..31, &"line#{&1}")

      for data <- [%{stop_reason: :aborted}, %{stop_reason: :error, error: :boom}] do
        ended = fold(state, :agent_end, data)
        assert ended.scroll == nil
        assert "› m1" in screen(ended)
        refute status_text(ended) =~ "scrolled"
      end
    end

    test "a wider terminal never leaves the screen empty", %{core: core} do
      state = core |> scroll_state(0) |> say(String.duplicate("word ", 60)) |> press("page_up")
      assert {0, _row} = state.scroll

      wide = resize(state, {200, 9})
      assert wide.scroll == nil
      assert screen(wide) != []
    end
  end

  describe "/model" do
    defp submit(state, text) do
      {:noreply, state} = TUI.handle_event(%ExRatatui.Event.Paste{content: text}, state)
      press(state, "enter")
    end

    defp fold_model_change(state) do
      assert_receive {:helyx_event, %Event{type: :model_change} = event}
      {:noreply, state} = TUI.handle_info({:helyx_event, event}, state)
      state
    end

    defp last_answer(state), do: Helyx.Message.text(List.last(state.vm.cells))

    test "a valid ref switches provider for the next turn, and back", %{core: core} do
      state = mounted(core, "switch", [["from fake"]])
      assert status_text(state) =~ "fake/switch"

      state = state |> submit("/model other/any") |> fold_model_change()
      assert ExRatatui.textarea_get_value(state.composer.input) == ""
      assert status_text(state) =~ "other/any"
      assert GenServer.call(Session.pid(state.session), :snapshot).model == "other/any"

      state = state |> submit("hi") |> drain()
      assert last_answer(state) == "from other"

      state = state |> submit("  /model \u00A0 fake/switch ") |> fold_model_change()
      assert status_text(state) =~ "fake/switch"
      state = state |> submit("hi") |> drain()
      assert last_answer(state) == "from fake"
    end

    test "a rejected ref shows a notice and changes nothing", %{core: core} do
      state = mounted(core, "stay", [])

      for {text, notice} <- [
            {"/model nope/any", "unknown provider: nope"},
            {"/model fake", "invalid model ref"},
            {"/model fake/" <> String.duplicate("m", 252), "invalid model ref"},
            {"/model", "usage: /model"},
            {"/model fake/a b", "invalid model ref"},
            {"/model\u00A0fake/a\u00A0b", "invalid model ref"},
            {"/model \u00A0 ", "usage: /model"}
          ] do
        ExRatatui.textarea_set_value(state.composer.input, "")
        state = submit(state, text)

        assert {:notice, shown} = List.last(state.vm.cells)
        assert shown =~ notice
        # At most the provider id: never the whole ref, whatever its size.
        assert byte_size(shown) < 80
        assert ExRatatui.textarea_get_value(state.composer.input) == text
        assert status_text(state) =~ "fake/stay"
        assert GenServer.call(Session.pid(state.session), :snapshot).model == "fake/stay"
      end

      refute_received {:helyx_event, _}
    end

    test "a line that starts with /model but has no separator shows usage and is never sent",
         %{core: core} do
      state = mounted(core, "plain", [["ok"]])

      for text <- ["/models are fun", "/model-x"] do
        ExRatatui.textarea_set_value(state.composer.input, "")
        state = submit(state, text)
        assert {:notice, "usage: /model" <> _} = List.last(state.vm.cells)
        assert ExRatatui.textarea_get_value(state.composer.input) != ""
      end

      refute_received {:helyx_event, _}

      # A slash elsewhere, or another first word, is a message.
      ExRatatui.textarea_set_value(state.composer.input, "")
      state = state |> submit("see /model") |> drain()
      assert last_answer(state) == "ok"
    end

    test "during a turn, with Enter or Alt+Enter, the command is never queued", %{core: core} do
      call = %Helyx.Message.ToolCall{
        id: "c",
        name: "slow",
        arguments: %{"ms" => 60_000, "text" => "x"}
      }

      state = mounted(core, "busy", [[call]])
      state = submit(state, "go")
      assert_receive {:helyx_event, %Event{type: :tool_execution_start}}

      for {text, model} <- [{"/model other/any", "other/any"}, {"/model fake/busy", "fake/busy"}] do
        {:noreply, _} = TUI.handle_event(%ExRatatui.Event.Paste{content: text}, state)
        press(state, "enter", if(model == "other/any", do: ["alt"], else: []))
        assert_receive {:helyx_event, %Event{type: :model_change, data: %{model: ^model}}}
        assert ExRatatui.textarea_get_value(state.composer.input) == ""
      end

      # A rejected command stays in the composer, and nothing joins a queue.
      {:noreply, _} = TUI.handle_event(%ExRatatui.Event.Paste{content: "/model nope/x"}, state)
      state = press(state, "enter", ["alt"])
      assert {:notice, "unknown provider: nope"} = List.last(state.vm.cells)
      assert ExRatatui.textarea_get_value(state.composer.input) == "/model nope/x"
      refute_received {:helyx_event, %Event{type: :queue_update}}

      :ok = Session.abort(state.session)
    end

    test "the rule is on bytes: a line that only looks like the command is a message", %{
      core: core
    } do
      # The stated limit of the rule (feature doc, bounds table): an invisible
      # character inside the word, one outside category C before it, and a
      # homoglyph each make a message.
      lines = ["/mo\u200Bdel other/any", "\u3164/model other/any", "/mo\u0434el other/any"]
      state = mounted(core, "looks", Enum.map(lines, fn _ -> ["ok"] end))

      for text <- lines do
        ExRatatui.textarea_set_value(state.composer.input, "")
        state = state |> submit(text) |> drain()
        assert last_answer(state) == "ok"
        assert GenServer.call(Session.pid(state.session), :snapshot).model == "fake/looks"
      end
    end

    test "invisible characters around the command word do not hide it", %{core: core} do
      state = mounted(core, "bom", [])

      for text <- [
            "\uFEFF/model other/any",
            "/model\u200Bother/any",
            "\u2060 /model\u180E other/any"
          ] do
        :ok = Session.set_model(state.session, "fake/bom")
        assert_receive {:helyx_event, %Event{type: :model_change}}
        ExRatatui.textarea_set_value(state.composer.input, "")
        submit(state, text)
        assert_receive {:helyx_event, %Event{type: :model_change, data: %{model: "other/any"}}}
        assert ExRatatui.textarea_get_value(state.composer.input) == ""
      end

      # Inside the ref, or after it, such a character is the ref's problem:
      # it is not trimmed, so the ref is rejected, and nothing is sent.
      for text <- ["/model fake/a\u200Bb", "/model fake/ab\u200B"] do
        ExRatatui.textarea_set_value(state.composer.input, "")
        state = submit(state, text)
        assert {:notice, "invalid model ref" <> _} = List.last(state.vm.cells)
        assert ExRatatui.textarea_get_value(state.composer.input) == text
      end

      refute_received {:helyx_event, _}
    end
  end

  describe "multiline composer" do
    defp paste(state, text) do
      {:noreply, state} = TUI.handle_event(%ExRatatui.Event.Paste{content: text}, state)
      state
    end

    defp value(state), do: ExRatatui.textarea_get_value(state.composer.input)

    defp composer_height(state) do
      [_transcript, {_widget, %Rect{height: height}}, _status] =
        TUI.render(state, %{width: 40, height: 30})

      height
    end

    defp lines(count), do: Enum.map_join(1..count, "\n", &"l#{&1}\tx")

    defp marker(id, lines), do: "[Pasted text ##{id}, #{lines} lines]\u0001"

    test "Ctrl+J and Shift+Enter add a new line, Enter sends it all", %{core: core} do
      state = mounted(core, "lines", [["ok"]])

      state =
        state
        |> press("a")
        |> press("j", ["ctrl"])
        |> press("b")
        |> press("enter", ["shift"])
        |> press("c")

      assert value(state) == "a\nb\nc"
      assert status_text(state) =~ "Ctrl+J newline"

      state = state |> press("enter") |> drain()
      assert value(state) == ""
      assert [prompt, _answer] = state.vm.cells
      assert Helyx.Message.text(prompt) == "a\nb\nc"
    end

    test "the composer grows to 8 lines and the transcript screen shrinks with it", %{
      core: core
    } do
      state = mounted(core, "grow", [])
      assert composer_height(state) == 3

      state = Enum.reduce(1..6, state, fn _, state -> press(state, "j", ["ctrl"]) end)
      assert composer_height(state) == 9

      state = press(state, "j", ["ctrl"])
      assert composer_height(state) == 10

      state = press(state, "j", ["ctrl"])
      assert ExRatatui.textarea_line_count(state.composer.input) == 9
      assert composer_height(state) == 10
    end

    test "a paste of 5 lines or fewer is text, with its tabs and new lines", %{core: core} do
      state = mounted(core, "short", [])

      for count <- [4, 5] do
        ExRatatui.textarea_set_value(state.composer.input, "")
        state = paste(state, lines(count))
        assert value(state) == lines(count)
        assert state.composer.pastes == %{}
      end

      # Lines count by new lines, not by bytes or characters.
      ExRatatui.textarea_set_value(state.composer.input, "")
      wide = Enum.map_join(1..5, "\n", fn _ -> "日本語\t🙂é" end)
      state = paste(state, wide)
      assert value(state) == wide
      assert paste(state, wide <> "\nü").composer.pastes |> Map.keys() == [marker(1, 6)]

      # A final new line does not start a line; CR and CRLF are new lines.
      ExRatatui.textarea_set_value(state.composer.input, "")
      state = paste(state, "a\r\nb\rc\nd\ne\n")
      assert value(state) == "a\nb\nc\nd\ne\n"
      assert state.composer.pastes == %{}

      # Control characters other than tab and new line drop.
      ExRatatui.textarea_set_value(state.composer.input, "")
      state = paste(state, "a\e[31mb\u009Bc")
      assert value(state) == "a[31mbc"
    end

    test "a paste of more than 5 lines is one marker and is sent in full", %{core: core} do
      state = mounted(core, "long", [["ok"]])
      big = lines(6) <> "\n"

      state = state |> press("é") |> paste(big) |> press("!") |> paste("ü\n" <> lines(19))
      assert value(state) == "é" <> marker(1, 6) <> "!" <> marker(2, 20)

      state = state |> press("enter") |> drain()
      assert [prompt, _answer] = state.vm.cells
      assert Helyx.Message.text(prompt) == "é" <> big <> "!ü\n" <> lines(19)
      assert state.composer.pastes == %{}

      # The ids start again with the next prompt.
      state = paste(state, lines(6))
      assert value(state) == marker(1, 6)

      # A two-digit id and a three-digit count are one marker too.
      state = Enum.reduce(2..10, state, fn _, acc -> paste(acc, lines(6)) end)
      state = state |> paste(lines(100)) |> press("backspace")
      assert String.ends_with?(value(state), marker(10, 6))
      state = press(state, "backspace")
      assert String.ends_with?(value(state), marker(9, 6))
    end

    test "a marker is one unit for every key", %{core: core} do
      state = mounted(core, "unit", [])

      # Backspace right after a marker removes it whole.
      state = state |> press("ß") |> paste(lines(7)) |> press("x")
      state = press(state, "backspace")
      assert value(state) == "ß" <> marker(1, 7)
      state = press(state, "backspace")
      assert value(state) == "ß"

      # Up and Down keep the column, so they can put the cursor inside a
      # marker: text then goes after it, and Backspace removes it whole.
      ExRatatui.textarea_set_value(state.composer.input, "")
      state = state |> press("a") |> press("b") |> press("c") |> press("j", ["ctrl"])
      state = paste(state, lines(6))
      up_down = fn state -> state |> press("up") |> press("down") end

      state = state |> up_down.() |> press("x")
      assert value(state) == "abc\n" <> marker(2, 6) <> "x"
      state = state |> up_down.() |> paste("p") |> up_down.() |> press("j", ["ctrl"])
      assert value(state) == "abc\n" <> marker(2, 6) <> "\npx"
      state = state |> press("right") |> press("up") |> press("backspace")
      assert value(state) == "abc\n\npx"

      # Delete at the start of a marker or inside it removes it whole.
      ExRatatui.textarea_set_value(state.composer.input, "")
      state = state |> press("a") |> paste(lines(6)) |> press("z") |> press("home")
      state = state |> press("right") |> press("delete")
      assert value(state) == "az"
      state = state |> press("j", ["ctrl"]) |> paste(lines(6)) |> up_down.() |> press("delete")
      assert value(state) == "a\nz"

      # Left and Right pass over a marker in one step.
      ExRatatui.textarea_set_value(state.composer.input, "")
      state = state |> press("q") |> paste(lines(6)) |> press("r")
      state = state |> press("left") |> press("left") |> press("p")
      assert value(state) == "qp" <> marker(5, 6) <> "r"
      state = state |> press("right") |> press("s")
      assert value(state) == "qp" <> marker(5, 6) <> "sr"

      # Zero-width text after a marker does not stop the cursor short of its
      # end.
      ExRatatui.textarea_set_value(state.composer.input, "")
      state = state |> press("x") |> paste(lines(6)) |> press("\u200b") |> press("home")
      state = state |> press("right") |> press("right") |> press("y")
      assert value(state) == "x" <> marker(6, 6) <> "y\u200b"
      state = state |> press("home") |> press("right") |> press("delete")
      assert value(state) == "xy\u200b"
    end

    test "only the markers that the composer made are replaced", %{core: core} do
      state = mounted(core, "forge", [["ok"], ["ok"]])
      look = "[Pasted text #1, 6 lines]"

      # Typed or pasted, the text of a live marker is sent as it is, and
      # Backspace after them removes only the typed character.
      state = paste(state, lines(6))
      state = Enum.reduce(String.graphemes(look), state, &press(&2, &1))
      state = state |> paste(" " <> look) |> press("x") |> press("backspace")
      state = state |> press("enter") |> drain()
      assert [prompt, _answer] = state.vm.cells
      assert Helyx.Message.text(prompt) == lines(6) <> look <> " " <> look

      # A key code or a paste with the end character of a marker cannot
      # forge one: the key goes nowhere, and the paste drops the character.
      state = paste(state, lines(6))
      state = state |> press("\u0001") |> paste(look <> "\u0001")
      assert value(state) == marker(1, 6) <> look
      state = state |> press("enter") |> drain()
      assert Helyx.Message.text(Enum.at(state.vm.cells, 2)) == lines(6) <> look
    end

    test "a pasted tab after /model is a separator", %{core: core} do
      state = mounted(core, "tab", [["ok"]])

      # The Tab key indents in the composer.
      state = press(state, "tab")
      assert value(state) != ""
      ExRatatui.textarea_set_value(state.composer.input, "")

      state = state |> paste("/model\tother/any") |> press("enter")
      assert_receive {:helyx_event, %Event{type: :model_change, data: %{model: "other/any"}}}
      assert value(state) == ""

      # A new line is whitespace: before the ref it separates, after it the
      # trim drops it. Text on a later line makes the ref invalid.
      for {text, model} <- [{"/model\nfake/r", "fake/r"}, {"/model fake/q\n", "fake/q"}] do
        state = state |> paste(text) |> press("enter")
        assert_receive {:helyx_event, %Event{type: :model_change, data: %{model: ^model}}}
        assert value(state) == ""
      end

      state = state |> paste("/model fake/a\nhello") |> press("enter")
      assert {:notice, "invalid model ref" <> _} = List.last(state.vm.cells)
      assert value(state) == "/model fake/a\nhello"
    end
  end
end
