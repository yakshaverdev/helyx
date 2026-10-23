defmodule Helyx.TUI.LinkTest do
  # The TUI over the wire (docs/features/tui-attach.md, slice 3), driven
  # through the app callbacks on a real server: the test process, or a
  # Task, is the TUI process.
  use ExUnit.Case, async: true

  import Helyx.Test.Events, only: [wait_ms: 0, wait_until: 1]

  alias ExRatatui.Event.{Key, Paste}
  alias Helyx.{Event, Message}
  alias Helyx.Provider.Fake
  alias Helyx.Session.File.Scan
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
    plugins = [Fake, Helyx.TUI.Test.Tool.Slow, Helyx.Tool.Question]
    core_opts = [name: core, plugins: plugins, sessions_dir: sessions, model: "fake/echo"]
    start_supervised!({Helyx.Core, core_opts})
    transport = start_supervised!({WebSocket, core: core, port: 0})
    %{core: core, port: WebSocket.port(transport), cwd: dir, sessions: sessions}
  end

  # The handshake is a wait that must happen: the one cap of the tests, so
  # load does not fail it (#805).
  defp connect(port) do
    {:ok, socket} = Wire.connect({127, 0, 0, 1}, port, fn -> "token" end, wait_ms())
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
  defp mount!(session, cwd, opts \\ []) do
    opts = [session: session, cwd: cwd, terminal_size_fn: fn -> {:error, :no_tty} end] ++ opts
    {:ok, state} = TUI.mount(opts)
    branch_reply(state)
  end

  # The server side of the client `socket`: its end is a lost connection
  # for the client.
  defp server_of(socket) do
    {:ok, {_ip, mine}} = :inet.sockname(socket)

    [server] =
      for port <- Port.list(),
          Port.info(port, :name) == {:name, ~c"tcp_inet"},
          :inet.peername(port) == {:ok, {{127, 0, 0, 1}, mine}},
          {:connected, pid} = Port.info(port, :connected),
          do: pid

    server
  end

  # Kills the server side of the connection of the TUI, and gives the
  # `:DOWN` of the connection that the TUI takes.
  defp lose(state) do
    conn = state.session.conn
    Process.exit(server_of(:sys.get_state(conn).socket), :kill)
    assert_receive {:DOWN, _ref, :process, ^conn, {:shutdown, {:closed, _code}}} = down
    down
  end

  # A turn of a prompt of another client, to its end, while the TUI has no
  # connection.
  defp other_turn(c, id, text) do
    Task.await(
      Task.async(fn ->
        {conn, _ref} = connect(c.port)
        {:ok, _snapshot, _sub} = Connection.subscribe(conn, id)
        :ok = Connection.steer(conn, id, text)
        turn_ends(1)
      end)
    )
  end

  defp texts(state, role),
    do: for(%Message{role: ^role} = m <- ViewModel.cells(state.vm), do: Message.text(m))

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

  # A process in the place of the connection: it tells the test each
  # request of `op` as `{:stub, op}`, and answers it with `answer.(op)`.
  defp stub(answer) do
    test = self()
    spawn_link(fn -> stub_loop(test, answer) end)
  end

  defp stub_loop(test, answer) do
    receive do
      {:"$gen_call", from, {:request, op, _params}} ->
        send(test, {:stub, op})
        GenServer.reply(from, answer.(op))
    end

    stub_loop(test, answer)
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
      _steer_or_compact -> :ok
    end

    state = %{state | session: %Link{conn: stub(answers), id: id}}

    state = key(state, "esc")
    assert_receive {Link, :abort, "no answer from the server"} = message
    assert info(message, state).vm.reason == "no answer from the server"

    state = state |> command("/new") |> finish()
    assert state.session.id == id

    assert List.last(ViewModel.cells(state.vm)) ==
             {:infos, ["could not switch: too many requests wait"]}

    # A text at the bound of Core goes; one byte more gets the answer of
    # Core, and no request.
    at = String.duplicate("a", Helyx.Session.max_text_bytes())
    assert command(state, at).vm.reason == nil
    assert_receive {:stub, "steer"}
    assert Link.compact(state.session, at) == :ok
    assert_receive {:stub, "compact"}
    assert Link.set_model(state.session, at) == :ok
    assert_receive {:stub, "set_model"}

    big = at <> "a"
    assert command(state, big).vm.reason == "not sent: over 4 MiB"
    assert Link.compact(state.session, big) == {:error, :text_too_large}
    assert Link.set_model(state.session, big) == {:error, {:invalid_model_ref, big}}
    for op <- ["steer", "compact", "set_model"], do: refute_received({:stub, ^op})
  end

  # The acceptance of #821. On this machine the old write in the connection
  # process passed it too; the tests of `Helyx.TUI.Wire.Connection` with a
  # server that does not read while it writes show the reads during a write.
  test "a plain text at the bound, then a follow-up: the connection stays open", c do
    {conn, ref} = connect(c.port)
    {:ok, id} = Connection.start(conn, cwd: c.cwd)
    {:ok, _snapshot, _sub} = Connection.subscribe(conn, id)
    session = %Link{conn: conn, id: id}
    text = String.duplicate("a", Helyx.Session.max_text_bytes())

    assert Link.send_text(session, text, false) == :ok
    assert Link.send_text(session, text, true) == :ok
    turn_ends(2)
    refute_received {:DOWN, ^ref, :process, ^conn, _reason}
  end

  # The worst JSON form of the bound, 4 MiB of control characters, is about
  # 24 MiB of JSON for each event of its turn. A client that reads them late
  # passes the outbound queue of the server, 64 MiB, which closes it with
  # 4408 (an accepted hole of tui-attach.md). The client gives the owner
  # 4408, or nil when a write of the client, such as a pong, fails at the
  # close: gen_tcp then drops the close frame that waits to be read.
  @tag :slow
  test "the worst JSON form at the bound and a slow client: the server closes it with 4408", c do
    {:ok, socket} = Wire.connect({127, 0, 0, 1}, c.port, fn -> "token" end, wait_ms())
    server = server_of(socket)
    {:ok, conn, ref} = Connection.open(socket)
    {:ok, id} = Connection.start(conn, cwd: c.cwd)
    {:ok, _snapshot, _sub} = Connection.subscribe(conn, id)
    text = String.duplicate("\u0001", Helyx.Session.max_text_bytes())
    assert Link.send_text(%Link{conn: conn, id: id}, text, false) == :ok

    # The client reads nothing until the queue of the server is over its
    # bound: the server process has the close in its mailbox.
    :erlang.suspend_process(conn)
    wait_until(fn -> {:close, 4408} in elem(Process.info(server, :messages), 1) end)
    :erlang.resume_process(conn)
    assert_receive {:DOWN, ^ref, :process, ^conn, {:shutdown, {:closed, code}}}
    assert code in [4408, nil]
  end

  defp turn_ends(0), do: :ok

  defp turn_ends(n) do
    assert_receive {:helyx_event, %Event{type: type}}, wait_ms()
    turn_ends(if type == :turn_end, do: n - 1, else: n)
  end

  test "a refused switch shows a fixed text for each reason, and no term", c do
    state = started(c)

    for {reason, text} <- [
          {:too_many_sessions, "too many sessions on the server"},
          {{:start_failed, ~s({:session_locked, "x"})}, "the server could not open the session"},
          {{:unknown_provider, "nope"}, "the model has an unknown provider"},
          {:bad_params, "the session did not open"}
        ] do
      session = %Link{conn: stub(fn "start" -> {:error, reason} end), id: state.session.id}
      state = %{state | session: session} |> command("/new") |> finish()
      assert List.last(ViewModel.cells(state.vm)) == {:infos, ["could not switch: " <> text]}
    end
  end

  test "the id of a /resume line, from the server, gets the clean pass" do
    summary = %Scan.Summary{id: "a\e[2J\nb", cwd: "/w", model: "m", mtime: 0, prompt: "p"}
    assert SessionList.line(summary, false) =~ ~r/\Aa\?\[2J b  /
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

  # docs/features/tui-attach.md, decision 11.
  test "a lost connection connects again: a replay gives the missed events once, a snapshot replaces the state",
       c do
    {conn, _ref} = connect(c.port)
    {:ok, id} = Connection.start(conn, cwd: c.cwd)
    reconnect = fn -> Wire.connect({127, 0, 0, 1}, c.port, fn -> "token" end, wait_ms()) end
    state = mount!(%Link{conn: conn, id: id}, c.cwd, reconnect: reconnect)
    state = state |> command("one") |> until(&(&1.type == :turn_end))
    instance = state.instance_id

    # The events of the turn of another client come in the replay.
    down = lose(state)
    other_turn(c, id, "two")
    state = branch_reply(info(down, state))
    refute state.session.conn == conn
    assert state.instance_id == instance
    assert texts(state, :user) == ["one", "two"]
    assert texts(state, :assistant) == ["one", "two"]
    assert List.last(ViewModel.cells(state.vm)) == {:infos, ["reconnected"]}

    # The new connection carries the live events. An event at or below
    # the seq of the fold changes nothing: no ack, fold, composer, or read
    # of the branch.
    state = state |> command("three") |> until(&(&1.type == :turn_end))
    assert texts(state, :user) == ["one", "two", "three"]

    for {type, data} <- [
          queue_dropped: %{messages: [Message.user("again")], texts: ["again"]},
          turn_end: %{outcome: :done}
        ] do
      again = %Event{
        type: type,
        session_id: id,
        instance_id: instance,
        turn_id: nil,
        seq: state.vm.seq,
        data: data
      }

      assert info({:helyx_event, again}, state) == state
    end

    # A resume makes a new instance: the reconnect gets a snapshot.
    down = lose(state)
    :ok = Helyx.Sessions.stop(%Helyx.Session{id: id, core: c.core})
    {other, _ref} = connect(c.port)
    {:ok, ^id} = Connection.resume(other, id: id)
    state = branch_reply(info(down, state))
    refute state.instance_id == instance
    assert texts(state, :user) == ["one", "two", "three"]
    assert List.last(ViewModel.cells(state.vm)) == {:infos, ["reconnected"]}

    # A failed reconnect, and a session that ended meanwhile, end the TUI.
    down = lose(state)
    failed = %{state | reconnect: fn -> {:error, "no server runs for /d"} end}

    assert catch_exit(info(down, failed)) ==
             {:connection_down, {:reconnect, "no server runs for /d"}}

    assert Link.down_text({:reconnect, "no server runs for /d"}) ==
             "lost the connection to the server: no server runs for /d"

    :ok = Helyx.Sessions.stop(%Helyx.Session{id: id, core: c.core})
    assert catch_exit(info(down, state)) == {:session_down, :session_not_found}
  end

  # A seq above the last event makes the server answer `after` with a
  # snapshot (wire-protocol.md, "Join, pages, and replay").
  test "a snapshot reconnect keeps the picker of the same ask; another ask gets a fresh one", c do
    question = fn text ->
      %{
        "question" => text,
        "header" => "Pick",
        "multi_select" => false,
        "options" => [
          %{"label" => "a", "description" => "A"},
          %{"label" => "b", "description" => "B"}
        ]
      }
    end

    call = %Message.ToolCall{
      id: "q1",
      name: "question",
      arguments: %{"questions" => [question.("One?"), question.("Two?")]}
    }

    :ok = Fake.script(c.core, "ask", [[call], ["Done."]])
    {conn, _ref} = connect(c.port)
    {:ok, id} = Connection.start(conn, cwd: c.cwd, model: "fake/ask")
    reconnect = fn -> Wire.connect({127, 0, 0, 1}, c.port, fn -> "token" end, wait_ms()) end
    state = mount!(%Link{conn: conn, id: id}, c.cwd, reconnect: reconnect)
    state = state |> command("go") |> until(&match?(%Event{type: :ask}, &1))

    # The answer of the first question, then unsent text on the second.
    state = state |> key("down") |> key("enter")
    state = Enum.reduce(~w(x y), state, &key(&2, &1))
    picker = state.question
    assert %{at: 1, answers: [_], other: "xy"} = picker

    down = lose(state)
    state = branch_reply(info(down, put_in(state.vm.seq, state.vm.seq + 1_000)))
    assert List.last(ViewModel.cells(state.vm)) == {:infos, ["reconnected"]}
    assert state.question == picker

    down = lose(state)
    other = put_in(state.question.ask_id, "another")
    state = branch_reply(info(down, %{other | vm: %{other.vm | seq: other.vm.seq + 1_000}}))
    assert %{ask_id: ask, at: 0, answers: [], other: ""} = state.question
    assert ask == picker.ask_id
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
