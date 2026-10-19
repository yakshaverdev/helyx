defmodule Helyx.TUI.LinkTest do
  # The TUI over the wire (docs/features/tui-attach.md, slice 3), driven
  # through the app callbacks on a real server: the test process, or a
  # Task, is the TUI process.
  use ExUnit.Case, async: true

  import Helyx.Test.Events, only: [wait_ms: 0]

  alias ExRatatui.Event.{Key, Paste}
  alias Helyx.{Event, Message}
  alias Helyx.Provider.Fake
  alias Helyx.Transport.WebSocket
  alias Helyx.TUI
  alias Helyx.TUI.{Link, SessionList, Switch, ViewModel, Wire}
  alias Helyx.TUI.Wire.Connection

  @moduletag :tmp_dir

  # A tool call that holds the turn open for a minute.
  @slow %Message.ToolCall{id: "c", name: "slow", arguments: %{"ms" => 60_000, "text" => "x"}}

  setup %{tmp_dir: dir} do
    core = :"link_core_#{System.unique_integer([:positive])}"
    sessions = Path.join(dir, "sessions")
    plugins = [Fake, Helyx.TUI.Test.Tool.Slow]
    core_opts = [name: core, plugins: plugins, sessions_dir: sessions, model: "fake/echo"]
    start_supervised!({Helyx.Core, core_opts})
    transport = start_supervised!({WebSocket, core: core, port: 0})
    %{core: core, port: WebSocket.port(transport), cwd: dir, sessions: sessions}
  end

  defp connect(port) do
    {:ok, socket} = Wire.connect({127, 0, 0, 1}, port, fn -> "token" end, 5_000)
    {:ok, conn, ref} = Connection.open(socket)
    {conn, ref}
  end

  # A TUI over the wire on a new session of `model` in its own connection.
  defp started(c, model \\ "fake/echo") do
    {conn, _ref} = connect(c.port)
    {:ok, id} = Connection.start(conn, cwd: c.cwd, model: model)
    mount!(%Link{conn: conn, id: id}, c.cwd)
  end

  # No terminal: the default size function forks and can block in a test (#730).
  defp mount!(session, cwd) do
    opts = [session: session, cwd: cwd, terminal_size_fn: fn -> {:error, :no_tty} end]
    {:ok, state} = TUI.mount(opts)
    branch_reply(state)
  end

  # The reply of the branch task after a mount or a turn_end: a git port
  # that closes while OTP still starts it prints on stderr.
  defp branch_reply(%{branch_ref: ref} = state) do
    assert_receive {^ref, _branch} = reply
    info(reply, state)
  end

  defp info(message, state) do
    {:noreply, state} = TUI.handle_info(message, state)
    state
  end

  defp key(state, code) do
    {:noreply, state} = TUI.handle_event(%Key{code: code, kind: "press", modifiers: []}, state)
    state
  end

  defp command(state, text) do
    {:noreply, state} = TUI.handle_event(%Paste{content: text}, state)
    key(state, "enter")
  end

  # Feeds session events until one that `match?` takes.
  defp until(state, match?) do
    assert_receive {:helyx_event, %Event{} = event}
    state = info({:helyx_event, event}, state)
    state = if event.type == :turn_end, do: branch_reply(state), else: state
    if match?.(event), do: state, else: until(state, match?)
  end

  # A saved session of the folder with one prompt, older than the others.
  defp saved_file(c, prompt) do
    id = Helyx.Session.Id.new()
    {:ok, file} = Helyx.Session.File.create(c.sessions, id, c.cwd, "fake/echo")
    Helyx.Test.SessionFile.append_message(file, Message.user(prompt))
    File.touch!(file.path, 1_000)
  end

  defp tool_running?(event),
    do: match?(%Event{type: :message_end, data: %{message: %{role: :assistant}}}, event)

  # Feeds the messages of the TUI process until the switch ends.
  defp finish(%{switch: nil} = state), do: state

  defp finish(%{switch: %Switch{task: %Task{ref: task}}} = state) do
    receive do
      {:helyx_event, _event} = message -> finish(info(message, state))
      {:helyx_end, _sub, _reason} = message -> finish(info(message, state))
      {^task, _result} = message -> finish(info(message, state))
    after
      wait_ms() -> flunk("the switch did not end")
    end
  end

  defp listed(%{list: %SessionList{task: %Task{ref: ref}}} = state) do
    assert_receive {^ref, _items} = answer
    info(answer, state)
  end

  # A process in the place of the connection, which answers each request
  # of `op` with `answer.(op)`.
  defp stub(answer), do: spawn_link(fn -> stub_loop(answer) end)

  defp stub_loop(answer) do
    receive do
      {:"$gen_call", from, {:request, op, _params}} -> GenServer.reply(from, answer.(op))
    end

    stub_loop(answer)
  end

  test "the quit aborts nothing: the turn runs on, and a TUI that resumes the folder joins it",
       c do
    :ok = Fake.script(c.core, "slow", [[@slow], ["done"]])
    {conn, ref} = connect(c.port)
    {:ok, id} = Connection.start(conn, cwd: c.cwd, model: "fake/slow")

    # The TUI process takes the connection, which ends with it at the quit.
    tui =
      Task.async(fn ->
        state =
          mount!(%Link{conn: conn, id: id}, c.cwd) |> command("go") |> until(&tool_running?/1)

        TUI.terminate(:normal, state)
      end)

    assert Task.await(tui, :infinity) == :ok
    assert_receive {:DOWN, ^ref, :process, ^conn, :normal}
    assert [%{id: ^id, status: :running}] = Helyx.Sessions.list_live(c.core)

    {conn, _ref} = connect(c.port)
    assert {:ok, ^id} = Connection.resume(conn, cwd: c.cwd)
    state = mount!(%Link{conn: conn, id: id}, c.cwd)
    assert state.busy
    assert Enum.any?(ViewModel.cells(state.vm), &match?({:tool, %{id: "c"}, _line, nil}, &1))
  end

  test "a new session gets the default model of the server; Alt+Enter sends a follow-up", c do
    {conn, _ref} = connect(c.port)
    {:ok, id} = Connection.start(conn, cwd: c.cwd)
    state = mount!(%Link{conn: conn, id: id}, c.cwd)
    assert state.vm.model == "fake/echo"

    {:noreply, state} = TUI.handle_event(%Paste{content: "later"}, state)

    {:noreply, state} =
      TUI.handle_event(%Key{code: "enter", kind: "press", modifiers: ["alt"]}, state)

    state = until(state, &(&1.type == :turn_end))
    assert Enum.any?(ViewModel.cells(state.vm), &match?(%Message{role: :user}, &1))
    assert Link.answer(state.session, "no-ask", %{"answers" => []}) == {:error, :not_waiting}
  end

  test "a subscribe that the wire refuses at the mount ends the TUI", c do
    {conn, _ref} = connect(c.port)
    {:ok, id} = Connection.start(conn, cwd: c.cwd)
    Process.exit(conn, :kill)

    opts = [
      session: %Link{conn: conn, id: id},
      cwd: c.cwd,
      terminal_size_fn: fn -> {:error, :no_tty} end
    ]

    assert catch_exit(TUI.mount(opts)) == {:connection_down, :closed}
  end

  # The answers of the wire that Core does not give, from a stub in the
  # place of the connection.
  test "a refused abort shows why, a refused stop fails the switch, and a text over 4 MiB is not sent",
       c do
    state = started(c)
    id = state.session.id

    answers = fn
      "abort" -> {:error, :timeout}
      "start" -> {:ok, "AAAAAAAAAAAA"}
      "stop" -> {:error, :busy}
    end

    state = %{state | session: %Link{conn: stub(answers), id: id}}

    state = key(state, "esc")
    assert_receive {Link, :abort, "no answer from the server"} = message
    assert info(message, state).vm.reason == "no answer from the server"

    state = state |> command("/new") |> finish()
    assert state.session.id == id

    assert List.last(ViewModel.cells(state.vm)) ==
             {:infos, ["could not switch: too many requests wait"]}

    # The stub answers no steer, compact, or set_model: each is refused here.
    big = String.duplicate("a", Helyx.Session.max_text_bytes() + 1)
    assert command(state, big).vm.reason == "not sent: over 4 MiB"
    assert Link.compact(state.session, big) == {:error, :text_too_large}
    assert Link.set_model(state.session, big) == {:error, {:invalid_model_ref, big}}
  end

  test "Escape aborts the turn and /model sets the model over the wire", c do
    :ok = Fake.script(c.core, "slow", [[@slow], ["done"]])
    state = c |> started("fake/slow") |> command("go") |> until(&tool_running?/1)
    state = key(state, "esc")
    state = until(state, &match?(%Event{type: :turn_end, data: %{outcome: :aborted}}, &1))
    state = state |> command("/model fake/echo") |> until(&(&1.type == :model_change))
    assert state.vm.model == "fake/echo"
  end

  test "/new stops the session it leaves, and /resume lists the saved sessions over the wire",
       c do
    state = c |> started() |> command("first") |> until(&(&1.type == :turn_end))
    first = state.session.id

    state = state |> command("/new") |> finish()
    assert %Link{id: second} = state.session
    assert Enum.map(Helyx.Sessions.list_live(c.core), & &1.id) == [second]
    assert List.last(ViewModel.cells(state.vm)) == {:infos, ["new session"]}

    # The new session has no message, so it is not listed. One page holds
    # every session of a scan, more than the default page of 50.
    for _n <- 1..50, do: saved_file(c, "older")
    state = state |> command("/resume") |> listed()
    assert length(state.list.items) == 51
    assert {^first, _line} = hd(state.list.items)
    state = state |> key("enter") |> finish()
    assert state.session.id == first
    cells = ViewModel.cells(state.vm)
    assert Message.text(hd(cells)) == "first"
    assert List.last(cells) == {:infos, ["resumed session"]}
  end

  test "a request that the wire refuses stays in the composer, and the TUI says why", c do
    closed = "no connection to the server"

    for {text, check} <- [
          {"hello", &(&1.vm.reason == closed)},
          {"/model fake/other", &(List.last(ViewModel.cells(&1.vm)) == {:notice, closed})}
        ] do
      state = started(c)
      Process.exit(state.session.conn, :kill)
      state = command(state, text)
      assert check.(state), text
      assert ExRatatui.textarea_get_value(state.composer.input) == text
    end

    state = started(c)
    Process.exit(state.session.conn, :kill)
    state = state |> command("/resume") |> listed()
    assert state.list.items == []
    assert state.list.empty == "could not list the sessions: " <> closed
  end

  test "the end of the session and the end of the connection end the TUI", c do
    state = started(c)
    :ok = Helyx.Sessions.stop(%Helyx.Session{id: state.session.id, core: c.core})
    sub = state.session_ref
    assert_receive {:helyx_end, ^sub, :stopped} = message
    assert catch_exit(info(message, state)) == {:session_down, :stopped}

    state = started(c)
    conn = state.session.conn
    Process.exit(conn, :kill)
    assert_receive {:DOWN, _ref, :process, ^conn, :killed} = down
    assert catch_exit(info(down, state)) == {:connection_down, :killed}

    for {reason, text} <- [
          {{:shutdown, :broken}, "the server broke the wire contract"},
          {{:shutdown, {:closed, 4408}}, "the server closed a slow connection"},
          {{:shutdown, {:closed, nil}}, "the server closed the connection"},
          {:timeout, "could not subscribe to the session: no answer from the server"},
          {:killed, "the connection to the server ended"}
        ],
        do: assert(Link.down_text(reason) == text)
  end
end
