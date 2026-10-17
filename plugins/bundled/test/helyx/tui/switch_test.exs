defmodule Helyx.TUI.Test.Tool.Raises do
  @moduledoc false
  # A tool whose check raises once a test sets the flag, so the open of a
  # session in a switch Task crashes. Only one test registers it.
  @behaviour Helyx.Tool

  def flag, do: {__MODULE__, :raise}
  @impl true
  def name, do: "raises"
  @impl true
  def description, do: "Raises in check/0."
  @impl true
  def parameters, do: %{"type" => "object"}
  @impl true
  def check, do: if(:persistent_term.get(flag(), false), do: raise("check failed"), else: :ok)
  @impl true
  def run(_args, _cwd), do: {:ok, ""}
end

defmodule Helyx.TUI.SwitchTest do
  # /new and /resume (docs/features/tui-session-switch.md), driven through
  # the app callbacks: the test process is the TUI process.
  use ExUnit.Case, async: true

  alias ExRatatui.Event.{Key, Paste}
  alias ExRatatui.Widgets.List, as: Rows
  alias ExRatatui.Widgets.Paragraph
  alias Helyx.{Event, Message, Session}
  alias Helyx.Provider.Fake
  alias Helyx.Session.File.Scan
  alias Helyx.TUI
  alias Helyx.TUI.{Command, Composer, SessionList, Switch, ViewModel}

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    core = :"switch_core_#{System.unique_integer([:positive])}"
    start_supervised!({Helyx.Core, name: core, plugins: [Fake, Helyx.TUI.Test.Tool.Slow]})
    %{core: core, dir: dir, opts: [sessions_dir: Path.join(dir, "sessions"), cwd: dir]}
  end

  defp start(core, opts, model \\ "fake/echo"),
    do: Session.start(core, [model: model] ++ Keyword.take(opts, [:sessions_dir, :cwd]))

  # A session with one prompt and its answer. With `stop?` its process
  # ends, so its lock is free for a resume.
  defp saved(core, opts, text, stop? \\ true) do
    {:ok, session} = start(core, opts)
    {:ok, _snapshot, ref} = Session.subscribe(session)
    :ok = Session.prompt(session, text)
    assert_receive {:helyx_event, %Event{type: :turn_end}}, 5_000

    if stop? do
      Helyx.Test.SessionFile.stop(session)
      assert_receive {:DOWN, ^ref, :process, _pid, _reason}
    end

    session
  end

  # No terminal: the default size function forks and can block in a test (#730).
  defp mount!(session, opts) do
    opts = [session: session] ++ opts ++ [terminal_size_fn: fn -> {:error, :no_tty} end]
    {:ok, %{branch_ref: ref} = state} = TUI.mount(opts)
    assert_receive {^ref, _branch} = reply
    info(reply, state)
  end

  defp info(message, state) do
    {:noreply, state} = TUI.handle_info(message, state)
    state
  end

  defp key(state, code, kind \\ "press") do
    {:noreply, state} = TUI.handle_event(%Key{code: code, kind: kind, modifiers: []}, state)
    state
  end

  defp type(state, text) do
    {:noreply, state} = TUI.handle_event(%Paste{content: text}, state)
    state
  end

  defp command(state, text), do: state |> type(text) |> key("enter")

  defp value(state), do: ExRatatui.textarea_get_value(state.composer.input)

  # Feeds the messages of the TUI process until the switch ends.
  defp finish(%{switch: nil} = state), do: state

  defp finish(%{switch: %Switch{task: %Task{ref: task}}, session_ref: session} = state) do
    receive do
      {:helyx_event, _event} = message -> finish(info(message, state))
      {:DOWN, ^session, :process, _pid, _reason} = message -> finish(info(message, state))
      {^task, _result} = message -> finish(info(message, state))
    after
      5_000 -> flunk("the switch did not end")
    end
  end

  # Feeds session events until one that `match?` takes.
  defp until(state, match?) do
    assert_receive {:helyx_event, %Event{} = event}, 5_000
    state = info({:helyx_event, event}, state)
    if match?.(event), do: state, else: until(state, match?)
  end

  test "the commands take no argument", %{core: core, opts: opts} do
    assert Command.parse("/new") == {:new, ""}
    assert Command.parse(" /resume ") == {:resume, ""}
    assert Command.parse("/newer") == {:usage, :new}
    {:ok, session} = start(core, opts)
    assert Command.parse("/new x") == {:usage, :new}
    assert Command.run(Command.parse("/new x"), session) == {:notice, "usage: /new"}
    assert Command.run(Command.parse("/resume x"), session) == {:notice, "usage: /resume"}
  end

  test "/new ends the session and starts one in the folder with the current model",
       %{core: core, dir: dir, opts: opts} do
    {:ok, old} = start(core, opts)
    old_pid = Session.pid(old)
    state = mount!(old, opts)
    :ok = Session.set_model(old, "fake/other")
    state = until(state, &(&1.type == :model_change))
    old_instance = state.instance_id
    # The Ctrl+O toggle is client state: it stays across a switch.
    {:noreply, state} =
      TUI.handle_event(%Key{code: "o", kind: "press", modifiers: ["ctrl"]}, state)

    state = command(state, "/new")
    assert value(state) == ""
    # A search that opens while the switch runs closes at the join: its
    # cursor is an item of the old session.
    {:noreply, state} =
      TUI.handle_event(%Key{code: "f", kind: "press", modifiers: ["ctrl"]}, state)

    assert state.search
    state = finish(state)
    assert state.vm.expanded?
    assert state.search == nil

    refute Process.alive?(old_pid)
    assert state.session.id != old.id
    assert state.vm.model == "fake/other"
    assert ViewModel.cells(state.vm) == [{:info, "new session"}]
    assert File.exists?(Helyx.Session.File.path(opts[:sessions_dir], dir, state.session.id))

    # An event of the old instance that is still in the mailbox goes.
    event = %Event{
      type: :notice,
      session_id: old.id,
      instance_id: old_instance,
      turn_id: nil,
      seq: 9,
      data: %{text: "old"}
    }

    assert info({:helyx_event, event}, state) == state
  end

  test "/new during a turn saves the aborted turn, keeps the draft, and drops the queue",
       %{core: core, dir: dir, opts: opts} do
    call = %Message.ToolCall{id: "c", name: "slow", arguments: %{"ms" => 60_000, "text" => "x"}}
    :ok = Fake.script(core, "busy", [[call], ["done"]])
    {:ok, old} = start(core, opts, "fake/busy")
    state = mount!(old, opts)
    :ok = Session.prompt(old, "go")

    state =
      until(state, &match?(%{type: :message_end, data: %{message: %{role: :assistant}}}, &1))

    :ok = Session.follow_up(old, "queued")

    state = command(state, "/new") |> type("draft")
    # No text goes to the session that the switch ends.
    state = key(state, "enter")
    assert state.vm.reason == "not sent: a switch runs"
    state = finish(state)

    assert value(state) == "draft"
    path = Helyx.Session.File.path(opts[:sessions_dir], dir, old.id)
    assert File.read!(path) =~ ~s("aborted")
  end

  test "a queue that comes back during a failed switch goes to the composer",
       %{core: core, opts: opts} do
    call = %Message.ToolCall{id: "c", name: "slow", arguments: %{"ms" => 60_000, "text" => "x"}}
    :ok = Fake.script(core, "busy", [[call], ["done"]])
    {:ok, current} = start(core, opts, "fake/busy")
    state = mount!(current, opts) |> type("draft")
    :ok = Session.prompt(current, "go")

    state =
      until(state, &match?(%{type: :message_end, data: %{message: %{role: :assistant}}}, &1))

    :ok = Session.follow_up(current, "queued")
    task = Task.async(fn -> :ok end)
    Task.await(task)
    state = %{state | switch: %Switch{task: task, target: {:resume, "AAAAAAAAAAAA"}}}

    # Escape during the switch gives the queue back; the switch then fails.
    state = state |> key("esc") |> until(&(&1.type == :queue_dropped))
    assert value(state) == "draft"
    state = Switch.done(state, {:error, :not_found})

    assert state.session == current
    assert value(state) == "queued\ndraft"
  end

  test "a queue of a dead session that waits before its end signal comes back",
       %{core: core, opts: opts} do
    call = %Message.ToolCall{id: "c", name: "slow", arguments: %{"ms" => 60_000, "text" => "x"}}
    :ok = Fake.script(core, "busy", [[call], ["done"]])
    {:ok, current} = start(core, opts, "fake/busy")
    state = mount!(current, opts) |> type("draft")
    :ok = Session.prompt(current, "go")

    state =
      until(state, &match?(%{type: :message_end, data: %{message: %{role: :assistant}}}, &1))

    :ok = Session.follow_up(current, "queued")
    task = Task.async(fn -> :ok end)
    Task.await(task)
    state = %{state | switch: %Switch{task: task, target: {:resume, "AAAAAAAAAAAA"}}}

    # The `queue_dropped` of the abort and the `:DOWN` wait in the mailbox
    # when the failed answer comes.
    :ok = Session.abort(current)
    :ok = GenServer.stop(Session.pid(current))
    state = info({task.ref, {:error, :not_found}}, state)

    assert %Switch{target: :new} = state.switch
    # The drained `turn_end` stops the busy timer.
    assert state.busy == nil
    assert value(finish(state)) == "queued\ndraft"
  end

  test "the queue of a session that ended during a failed switch comes back",
       %{core: core, opts: opts} do
    {:ok, current} = start(core, opts)
    state = mount!(current, opts) |> type("draft")
    task = Task.async(fn -> :ok end)
    Task.await(task)

    dropped = %Event{
      type: :queue_dropped,
      session_id: current.id,
      instance_id: state.instance_id,
      turn_id: nil,
      seq: 0,
      data: %{texts: ["queued"]}
    }

    switch = %Switch{task: task, target: {:resume, "AAAAAAAAAAAA"}, dropped: [dropped]}
    state = info({:DOWN, state.session_ref, :process, self(), :killed}, %{state | switch: switch})

    state = Switch.done(state, {:error, :not_found})
    assert %Switch{target: :new, dropped: []} = state.switch
    assert value(finish(state)) == "queued\ndraft"
  end

  test "/resume lists the other sessions, and Enter resumes the selected one",
       %{core: core, dir: dir, opts: opts} do
    first = saved(core, opts, "first prompt")
    second = saved(core, opts, "second prompt")
    {:ok, current} = start(core, opts)
    current_pid = Session.pid(current)
    state = current |> mount!(opts) |> command("/resume")

    expected =
      for s <- Scan.list(opts[:sessions_dir], dir), s.id != current.id do
        {s.id, SessionList.line(s, false)}
      end

    assert Enum.sort(Enum.map(expected, &elem(&1, 0))) == Enum.sort([first.id, second.id])
    assert state.list.items == expected
    assert value(state) == ""

    # The list draws in the place of the composer.
    [_transcript, {%Rows{items: items, selected: 0}, rect}, _footer] =
      TUI.render(state, %{width: 160, height: 20})

    assert items == Enum.map(expected, &elem(&1, 1))
    assert rect.height == 4

    assert key(state, "up").list.selected == 0
    state = key(state, "down", "repeat")
    assert state.list.selected == 1
    assert key(state, "down").list.selected == 1

    {target, _line} = Enum.at(expected, 1)
    state = key(state, "enter")
    assert state.list == nil
    state = finish(state)

    refute Process.alive?(current_pid)
    assert state.session.id == target
    cells = ViewModel.cells(state.vm)
    assert List.last(cells) == {:info, "resumed session"}
    prompt = if target == first.id, do: "first prompt", else: "second prompt"
    assert Enum.any?(cells, &match?(%Message{role: :user}, &1))
    assert Message.text(hd(cells)) == prompt
  end

  test "Escape closes the list; a list with no other session says so",
       %{core: core, opts: opts} do
    {:ok, current} = start(core, opts)
    state = current |> mount!(opts) |> command("/resume")
    assert state.list.items == []

    [_transcript, {%Paragraph{text: "no other session in this folder"}, _rect}, _footer] =
      TUI.render(state, %{width: 80, height: 20})

    # Other keys and a paste do nothing while the list shows.
    assert key(state, "x").list == state.list
    ctrl_o = %Key{code: "o", kind: "press", modifiers: ["ctrl"]}
    assert TUI.handle_event(ctrl_o, state) == {:noreply, state}
    assert type(state, "x") == state

    state = key(state, "esc")
    assert state.list == nil
    assert state.switch == nil
    assert state.session == current
  end

  test "a failed resume shows the error and stays on the current session",
       %{core: core, opts: opts} do
    # The session runs in another Core, so its lock is held. A resume in
    # the same Core would attach to it (#657).
    other = :"switch_other_#{System.unique_integer([:positive])}"
    start_supervised!({Helyx.Core, name: other, plugins: [Fake]}, id: other)
    open = saved(other, opts, "still open", false)
    {:ok, current} = start(core, opts)
    state = current |> mount!(opts) |> command("/resume")
    assert [{id, _line}] = state.list.items
    assert id == open.id

    state = state |> key("enter") |> finish()

    assert state.session == current
    assert Process.alive?(Session.pid(current))

    assert List.last(ViewModel.cells(state.vm)) ==
             {:info, "could not switch: session #{open.id} is open in another process"}
  end

  test "when the session ends during a failed switch, a new one takes its place; a failed /new then ends the TUI",
       %{core: core, opts: opts} do
    {:ok, current} = start(core, opts)
    state = mount!(current, opts)
    task = Task.async(fn -> :ok end)
    Task.await(task)

    # The end signal during a switch waits for the result of the switch.
    switch = %Switch{task: task, target: {:resume, "AAAAAAAAAAAA"}}
    state = info({:DOWN, state.session_ref, :process, self(), :killed}, %{state | switch: switch})
    assert state.switch.down == {:down, :killed}

    state = Switch.done(state, {:error, :not_found})
    assert %Switch{target: :new, down: {:down, :killed}} = state.switch
    assert {:info, "could not switch: " <> _reason} = List.last(ViewModel.cells(state.vm))
    state = finish(state)
    assert state.session.id != current.id
    assert ViewModel.cells(state.vm) == [{:info, "new session"}]

    failed = %{state | switch: %Switch{task: task, target: :new, down: {:down, :killed}}}

    assert catch_exit(Switch.done(failed, {:error, :invalid_cwd})) ==
             {:session_down, :crashed}
  end

  test "terminate ends a switch and aborts the turn of the current session",
       %{core: core, opts: opts} do
    call = %Message.ToolCall{id: "c", name: "slow", arguments: %{"ms" => 60_000, "text" => "x"}}
    :ok = Fake.script(core, "quit", [[call], ["done"]])
    {:ok, idle} = start(core, opts)
    state = idle |> mount!(opts) |> command("/new")
    pid = state.switch.task.pid
    ref = Process.monitor(pid)
    assert TUI.terminate(:normal, state) == :ok
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}

    # With no switch, the quit aborts the turn of the current session.
    {:ok, busy} = start(core, opts, "fake/quit")
    state = mount!(busy, opts)
    :ok = Session.prompt(busy, "go")

    state =
      until(state, &match?(%{type: :message_end, data: %{message: %{role: :assistant}}}, &1))

    assert TUI.terminate(:normal, state) == :ok
    until(state, &match?(%{type: :turn_end, data: %{outcome: :aborted}}, &1))
  end

  test "a crash of the switch Task is a failed switch, and Enter works again", %{opts: opts} do
    core = :"switch_raise_#{System.unique_integer([:positive])}"
    plugins = [Fake, Helyx.TUI.Test.Tool.Raises]
    start_supervised!({Helyx.Core, name: core, plugins: plugins}, id: core)
    {:ok, current} = start(core, opts)
    state = mount!(current, opts)
    :persistent_term.put(Helyx.TUI.Test.Tool.Raises.flag(), true)
    on_exit(fn -> :persistent_term.erase(Helyx.TUI.Test.Tool.Raises.flag()) end)

    # The TUI traps exits, as `ExRatatui.Server` does.
    Process.flag(:trap_exit, true)
    %{switch: %{task: %Task{ref: ref}}} = state = command(state, "/new")
    assert_receive {:DOWN, ^ref, :process, _pid, _reason} = down
    state = info(down, state)

    assert state.switch == nil
    assert state.session == current
    assert {:info, "could not switch: " <> _reason} = List.last(ViewModel.cells(state.vm))
    assert command(state, "hi").vm.reason == nil
  end

  test "an end signal with a nil reason still counts as ended", %{core: core, opts: opts} do
    {:ok, current} = start(core, opts)
    state = mount!(current, opts)
    task = Task.async(fn -> :ok end)
    Task.await(task)
    switch = %Switch{task: task, target: {:resume, "AAAAAAAAAAAA"}}
    state = info({:DOWN, state.session_ref, :process, self(), nil}, %{state | switch: switch})

    assert %Switch{target: :new, down: {:down, nil}} =
             Switch.done(state, {:error, :not_found}).switch
  end

  test "a session that died with its end signal still on the way counts as ended",
       %{core: core, opts: opts} do
    {:ok, current} = start(core, opts)
    state = mount!(current, opts)
    task = Task.async(fn -> :ok end)
    Task.await(task)
    :ok = GenServer.stop(Session.pid(current))

    state = %{state | switch: %Switch{task: task, target: {:resume, "AAAAAAAAAAAA"}}}
    state = Switch.done(state, {:error, :not_found})
    assert %Switch{target: :new, down: {:down, :normal}} = state.switch
    assert finish(state).session.id != current.id
  end

  test "without a sessions directory /new saves nothing and /resume lists nothing",
       %{core: core, opts: opts} do
    _other = saved(core, opts, "saved")
    {:ok, current} = start(core, opts)
    opts = Keyword.delete(opts, :sessions_dir)
    state = current |> mount!(opts) |> command("/resume")
    assert state.list.items == []
    state = state |> key("esc") |> command("/new") |> finish()

    assert ViewModel.cells(state.vm) == [
             {:notice, Helyx.Reason.text(:not_saved)},
             {:info, "new session"}
           ]
  end

  test "the list keeps one item row, and the transcript one row from 4 rows of room" do
    list = %SessionList{items: for(n <- 1..5, do: {"id#{n}", "line #{n}"})}
    assert SessionList.rows(list, 3) == 3
    assert SessionList.rows(list, 4) == 3
    assert SessionList.rows(list, 5) == 4
    assert SessionList.rows(list, 8) == 7
    assert SessionList.rows(list, 9) == 7
    assert SessionList.rows(%SessionList{items: []}, 9) == 3
  end

  test "a recall that shows at the join ends, and the draft and the prompt stay",
       %{core: core, opts: opts} do
    state = core |> saved(opts, "earlier", false) |> mount!(opts) |> type("draft") |> key("up")
    assert value(state) == "earlier"
    composer = Composer.end_recall(state.composer)
    assert composer.recall == nil
    assert ExRatatui.textarea_get_value(composer.input) == "draft\nearlier"
    assert Composer.end_recall(composer) == composer
  end
end
