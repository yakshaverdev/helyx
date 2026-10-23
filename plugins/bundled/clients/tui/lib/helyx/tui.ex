defmodule Helyx.TUI do
  # The keys that `handle_event/2` dispatches, for the moduledoc and `/help`.
  @keys [
    {"Enter", "sends the composer as a steer, or as a prompt when no turn runs"},
    {"Alt+Enter", "sends it as a follow-up"},
    {"Ctrl+J", "adds a new line; so does Shift+Enter where the terminal reports it"},
    {"Up, Down", "on the first and the last row, recall earlier prompts"},
    {"Escape", "aborts the running turn; its queued messages come back to the composer"},
    {"PgUp, PgDn", "scroll the transcript by one screen"},
    {"wheel, drag", "the wheel scrolls three rows; a drag copies text"},
    {"Home, End", "with an empty composer, the oldest and the newest output; else the cursor"},
    {"Ctrl+A, Ctrl+E", "move the cursor to the start or the end of the line"},
    {"Alt+B, Alt+F", "move the cursor one word back or forward, as Ctrl+Left and Ctrl+Right do"},
    {"Ctrl+O", "shows the full text of every tool result, or four lines again"},
    {"Ctrl+F", "finds text in the loaded transcript"},
    {"Ctrl+C", "clears the composer; a second Ctrl+C within 500 ms quits"}
  ]

  @moduledoc """
  The terminal interface, an `ExRatatui.App` in the alternate screen.

  The TUI subscribes to one session at a time and renders from `Helyx.TUI.ViewModel`,
  a pure fold over the session's events. It holds no session state of its own. It runs in
  the node of its Core, or over the wire on the server of the data folder
  (`docs/features/tui-attach.md`), whose handshake checks the protocol. Typing fills the
  composer (`Helyx.TUI.Composer`), at most 8 lines high; a paste of more than 5 lines shows
  as one marker and is sent in full, and a rejected send stays in the composer. `/help`
  lists the slash commands (`Helyx.TUI.Command`) and these keys, with the full rules in
  `docs/features/coding-agent.md`, "TUI":

  #{Enum.map_join(@keys, "\n", fn {key, text} -> "* #{key}: #{text}" end)}

  Start it with `run/1`, which blocks until the user quits:

      Helyx.TUI.run(session: session)
  """

  use ExRatatui.App

  alias ExRatatui.Event.{Key, Mouse, Paste, Resize}
  alias ExRatatui.Layout
  alias ExRatatui.Layout.Rect
  alias ExRatatui.Subscription
  alias Helyx.TUI.{Command, Composer, Footer, Link, Quit, Selection, SessionList, Start, Switch}
  alias Helyx.TUI.{Question, Search, Transcript, ViewModel}
  require Helyx.TUI.{Question, Quit, Search}

  # One screen of scroll is the rows above the composer and the footer.
  @footer_rows Footer.rows()

  # The empty columns on the left and on the right of every part.
  @margin 2

  @doc """
  Starts the TUI for a session and blocks until the user quits.

  The options are `:session`, a `Helyx.Session` or a `Helyx.TUI.Link` with
  the connection that the caller opened, which the TUI takes; `:resumed`
  (true when the session was resumed: an information cell "resumed
  session" follows the history), `:cwd` (the directory that the footer
  shows and the folder of `/new` and `/resume`, default `File.cwd!/0`),
  `:sessions_dir` (where `/new` saves and `/resume` lists; without it
  `/new` saves nothing and `/resume` lists nothing), `:reconnect` (over the
  wire, the connect after a lost connection: `{:ok, socket}`, owned by the
  caller, or `{:error, text}`), and those of `ExRatatui.App`. The scroll
  keys read the terminal size through `:terminal_size_fn`, the option of
  `ExRatatui.Server`; the default is `ExRatatui.terminal_size/0`.
  """
  @spec run(keyword()) :: :ok | {:error, term()}
  def run(opts), do: Start.run(fn -> start_link(Keyword.put_new(opts, :mouse_capture, true)) end)

  @impl true
  def mount(opts) do
    cwd = Keyword.get_lazy(opts, :cwd, &File.cwd!/0)

    state = %{
      # The session and its subscription: `Helyx.TUI.Switch.bind/3`.
      session: nil,
      session_ref: nil,
      instance_id: nil,
      vm: nil,
      sessions_dir: opts[:sessions_dir],
      reconnect: opts[:reconnect],
      switch: nil,
      list: nil,
      search: nil,
      question: nil,
      composer: Composer.new(),
      cwd: cwd,
      # Row 1 of the footer. The branch comes from a task that starts
      # at mount and after each turn; the result of the latest wins.
      location: Footer.location(cwd, nil),
      branch_ref: nil,
      # A `Transcript.position()`; nil follows the newest output.
      scroll: nil,
      selection: nil,
      # The size seam of `ExRatatui.Server`, so a test sets the size.
      terminal_size_fn: Keyword.get(opts, :terminal_size_fn, &ExRatatui.terminal_size/0),
      # nil while idle, or the monotonic ms of the turn start and the ms
      # since then at the last tick.
      busy: nil,
      quit: nil
    }

    info = if opts[:resumed], do: "resumed session"
    state = state |> Switch.bind(Link.own(Keyword.fetch!(opts, :session)), info) |> read_branch()
    # The notices of the skills scan (docs/features/skills.md), once.
    notices = Helyx.Skills.scan(cwd).notices
    {:ok, %{state | vm: Enum.reduce(notices, state.vm, &ViewModel.notice(&2, &1))}}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{session_ref: ref} = state),
    do: {:noreply, Switch.down(state, reason)}

  def handle_info({:helyx_end, ref, :slow}, %{session_ref: ref}), do: exit({:session_down, :slow})

  # Over the wire: the `session_end` of the subscription, and the end of the connection.
  def handle_info({:helyx_end, sub, reason}, %{session_ref: sub} = state),
    do: {:noreply, Switch.down(state, {:session_end, reason})}

  # A reconnect can replay the end of a turn, so the branch is read again.
  def handle_info({:DOWN, _ref, :process, conn, reason}, %{session: %Link{conn: conn}} = state),
    do: {:noreply, settle(sync_busy(read_branch(Switch.reconnect(state, reason))))}

  def handle_info({:helyx_event, %{instance_id: id} = event}, %{instance_id: id} = state) do
    state = Switch.apply_event(state, event)
    # A turn can change the branch.
    state = if event.type == :turn_end, do: read_branch(state), else: state
    {:noreply, settle(sync_busy(state))}
  end

  def handle_info({ref, result}, %{switch: %Switch{task: %Task{ref: ref}}} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, settle(sync_busy(Switch.done(state, result)))}
  end

  # ExRatatui traps exits, so a crash of the switch Task reaches the TUI as
  # its `:DOWN` (and an `:EXIT`, which the last clause drops).
  def handle_info(
        {:DOWN, ref, :process, _pid, reason},
        %{switch: %Switch{task: %{ref: ref}}} = state
      ),
      do: {:noreply, settle(sync_busy(Switch.done(state, {:error, reason})))}

  # A tick of the `subscriptions/1` timer; none arrives while idle (cancelled).
  def handle_info(:busy_tick, %{busy: busy} = state) do
    elapsed = System.monotonic_time(:millisecond) - busy.started
    {:noreply, %{state | busy: %{busy | elapsed: elapsed}}}
  end

  def handle_info({ref, items}, %{list: %SessionList{task: %Task{ref: ref}}} = state),
    do: {:noreply, %{state | list: SessionList.read(state.list, items)}}

  def handle_info({ref, branch}, %{branch_ref: ref} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, %{state | location: Footer.location(state.cwd, branch), branch_ref: nil}}
  end

  def handle_info({Quit, ref}, state),
    do: {:noreply, %{state | quit: Quit.expire(state.quit, ref)}}

  def handle_info({Link, :abort, text}, state),
    do: {:noreply, %{state | vm: ViewModel.reject(state.vm, text)}}

  # An older branch task or list scan, or its `:DOWN`, is ignored here.
  def handle_info(_msg, state), do: {:noreply, state}

  # git runs in a task, so a slow git never holds a frame;
  # `Footer.branch/1` bounds it and never raises.
  defp read_branch(%{cwd: cwd} = state),
    do: %{state | branch_ref: Task.async(fn -> Footer.branch(cwd) end).ref}

  # The next key press or paste clears the reason of the last reject, then
  # runs as usual, so it can set a new reason. The release and the repeat of
  # a key are not a new press: those of the rejected Enter keep the reason.
  @impl true
  def handle_event(event, %{vm: %ViewModel{reason: reason}} = state)
      when is_binary(reason) and
             (is_struct(event, Paste) or (is_struct(event, Key) and event.kind == "press")),
      do: handle_event(event, %{state | vm: ViewModel.clear_reason(state.vm)})

  def handle_event(event, state) when Quit.handles?(state.quit, event) do
    case Quit.handle(state.quit, event, Composer.nothing_to_clear?(state.composer)) do
      :quit -> {:stop, state}
      {:clear, quit} -> {:noreply, %{edit(state, &Composer.clear/1) | quit: quit}}
      {:pass, quit} -> handle_event(event, %{state | quit: quit})
    end
  end

  # The open list takes the keys and a paste. Up and Down repeat.
  def handle_event(%Key{code: code, kind: kind}, %{list: %SessionList{} = list} = state)
      when kind == "press" or (kind == "repeat" and code in ["up", "down"]) do
    case SessionList.key(list, code) do
      {:move, list} -> {:noreply, %{state | list: list}}
      {:pick, id} -> {:noreply, settle(Switch.start(%{state | list: nil}, {:resume, id}))}
      :close -> {:noreply, settle(%{state | list: SessionList.close(list)})}
      :none -> {:noreply, state}
    end
  end

  def handle_event(%type{}, %{list: %SessionList{}} = state) when type in [Key, Paste],
    do: {:noreply, state}

  def handle_event(%Key{code: code, kind: kind, modifiers: []}, state)
      when code in ["page_up", "page_down"] and kind in ["press", "repeat"],
      do: {:noreply, on_screen(state, &Transcript.page(state.vm, state.scroll, code, &1, &2))}

  # The toggle changes the rows of tool cells: a selection ends, as at a new
  # size, and a scrolled view stays in its item.
  def handle_event(%Key{code: "o", kind: "press", modifiers: ["ctrl"]}, state) do
    state = %{state | vm: ViewModel.toggle_expanded(state.vm), selection: nil}
    {:noreply, settle(state, &Transcript.keep/4)}
  end

  # Escape aborts, also over a hidden search; a Task keeps the wait off the render loop.
  def handle_event(%Key{code: "esc", kind: "press"}, state)
      when state.search == nil or state.question != nil,
      do: {:noreply, tap(state, &Link.abort_async(&1.session))}

  def handle_event(event, state) when Question.handles?(state.question, event),
    do: Question.handle(event, state)

  def handle_event(event, state) when Search.handles?(state.search, event),
    do: Search.handle(event, state, layout(state, state.terminal_size_fn.()))

  def handle_event(%Resize{}, state), do: {:noreply, settle(%{state | selection: nil})}

  def handle_event(%Mouse{} = mouse, state),
    do: Selection.handle(mouse, state, layout(state, state.terminal_size_fn.()))

  # With an empty composer, Home and End scroll; else they move its cursor.
  def handle_event(%Key{code: code, kind: kind, modifiers: []}, state)
      when code in ["home", "end"] and kind in ["press", "repeat"] do
    cond do
      not Composer.empty?(state.composer) -> {:noreply, edit(state, :key, code)}
      code == "end" -> {:noreply, %{state | scroll: nil}}
      true -> {:noreply, on_screen(state, &Transcript.hold(state.vm, {0, 0}, &1, &2))}
    end
  end

  # Ctrl+J is a new line in every terminal. Shift+Enter reaches here only
  # where the terminal reports Shift on Enter; elsewhere it is Enter.
  def handle_event(%Key{code: code, kind: kind, modifiers: modifiers}, state)
      when {code, modifiers} in [{"j", ["ctrl"]}, {"enter", ["shift"]}] and
             kind in ["press", "repeat"] do
    {:noreply, edit(state, :insert, "\n")}
  end

  # No text goes to a session that a switch ends.
  def handle_event(%Key{code: "enter", kind: "press"}, %{switch: %Switch{}} = state),
    do: {:noreply, %{state | vm: ViewModel.reject(state.vm, "not sent: a switch runs")}}

  def handle_event(%Key{code: "enter", kind: "press"} = key, state) do
    case Composer.submit(state.composer, &Helyx.Skills.expand(&1, state.cwd)) do
      :empty -> {:noreply, state}
      {:message, text} -> {:noreply, send_message(text, key, state)}
      # A notice is a new cell, so the position gets its check.
      command -> {:noreply, settle(run_command(command, state))}
    end
  end

  # Up and Down recall earlier prompts at the first and the last row.
  def handle_event(%Key{code: code, kind: kind, modifiers: []}, state)
      when code in ["up", "down"] and kind in ["press", "repeat"],
      do: {:noreply, edit(state, &Composer.recall(&1, state.vm, code))}

  # Only Ctrl+J and Shift+Enter add a line; a repeat or release of Enter does nothing.
  def handle_event(%Key{code: "enter"}, state), do: {:noreply, state}

  # Every other press or repeat goes to the composer: `Composer.press/3`.
  def handle_event(%Key{kind: kind} = key, state) when kind in ["press", "repeat"],
    do: {:noreply, edit(state, &Composer.press(&1, key.code, key.modifiers))}

  def handle_event(%Paste{content: content}, state),
    do: {:noreply, edit(state, :paste, content)}

  def handle_event(_event, state), do: {:noreply, state}

  # An edit that changes the composer height changes the screen of the
  # transcript, so the position gets its check.
  defp edit(state, op, text), do: edit(state, &Composer.edit(&1, op, text))

  defp edit(state, change) do
    rows = Composer.rows(state.composer)
    composer = change.(state.composer)
    state = %{state | composer: composer}
    if Composer.rows(composer) == rows, do: state, else: settle(state)
  end

  # A rejected message stays in the composer, and the footer says why.
  defp send_message(text, key, state) do
    case Link.send_text(state.session, text, "alt" in key.modifiers) do
      :ok -> %{state | composer: Composer.restore(state.composer), scroll: nil}
      {:reject, reason} -> %{state | vm: ViewModel.reject(state.vm, reason)}
    end
  end

  # The footer and the transcript follow the session's events, not this
  # call. A refused command stays in the composer, under a notice.
  defp run_command({:new, ""}, state), do: Switch.start(restore(state), :new)

  defp run_command({:help, ""}, state),
    do: %{restore(state) | vm: ViewModel.info(state.vm, Command.help(@keys))}

  defp run_command({:resume, ""}, state),
    do: %{restore(state) | list: SessionList.new(state.session, state.sessions_dir, state.cwd)}

  defp run_command(command, state) do
    case Command.run(command, state.session) do
      :ok -> restore(state)
      {:notice, text} -> %{state | vm: ViewModel.notice(state.vm, text)}
    end
  end

  defp restore(state), do: %{state | composer: Composer.restore(state.composer)}

  @impl true
  def render(state, frame) do
    [transcript, middle, footer] = layout(state, {frame.width, frame.height})

    rows = Transcript.screen(state.vm, state.scroll, transcript)
    marks = Search.marks(state.search, rows, transcript)

    middle =
      cond do
        state.list -> [{SessionList.widget(state.list), middle}]
        state.question -> Question.widgets(state.question, middle)
        state.search -> Search.widgets(state.search, marks, middle)
        true -> Composer.widgets(state.composer, middle)
      end

    Selection.widgets(state.selection, rows, transcript) ++
      marks ++
      middle ++
      [{Footer.widget(state.location, state.vm, state.busy, state.scroll, state.quit), footer}]
  end

  # The transcript, composer or list, and footer rects, nil with no terminal size. The frame,
  # the scroll, and the mouse share them: one width rule.
  defp layout(state, {width, height}) when is_integer(width) and is_integer(height) do
    Layout.split(
      %Rect{x: 0, y: 0, width: width, height: height},
      :vertical,
      [
        {:min, 0},
        {:length, middle_rows(state, width - 2 * @margin, height - @footer_rows)},
        {:length, @footer_rows}
      ],
      horizontal_margin: @margin
    )
  end

  defp layout(_state, {:error, _reason}), do: nil

  defp middle_rows(%{list: %SessionList{} = list}, _width, room), do: SessionList.rows(list, room)
  defp middle_rows(%{question: %Question{} = q}, width, room), do: Question.rows(q, width, room)
  defp middle_rows(%{composer: composer}, _width, room), do: Composer.rows(composer, room)

  # Scroll position

  # Sets the position from the transcript rect, of at least one row. With no
  # size there is no screen to check, so the view follows the newest output.
  defp on_screen(state, position) do
    case layout(state, state.terminal_size_fn.()) do
      [%Rect{width: width, height: rows} | _] ->
        %{state | scroll: position.(width, max(rows, 1))}

      nil ->
        %{state | scroll: nil}
    end
  end

  # Applies `Transcript.hold/4`, or `rule`, after a change that no scroll
  # key makes: a session event, a client notice, a new size, or Ctrl+O.
  defp settle(state, rule \\ &Transcript.hold/4)
  defp settle(%{scroll: nil} = state, _rule), do: state
  defp settle(state, rule), do: on_screen(state, &rule.(state.vm, state.scroll, &1, &2))

  # Busy indicator

  # ExRatatui keeps one timer per id, armed while this list holds it: one
  # tick timer while a turn runs, and none while idle.
  @impl true
  def subscriptions(%{busy: nil}), do: []
  def subscriptions(_state), do: [Subscription.interval(:busy, Footer.tick_ms(), :busy_tick)]

  defp sync_busy(state), do: %{state | busy: Footer.busy(state.busy, state.vm)}

  # At quit, a switch that runs ends, and a session that it opened stays
  # until Core stops. The turn of the current session aborts before Core
  # stops, and runs on in the server (`Link.quit/1`); ExRatatui has
  # restored the terminal.
  @impl true
  def terminate(_reason, state) do
    if state.switch, do: Task.shutdown(state.switch.task, :brutal_kill)
    _ = Link.quit(state.session)
    :ok
  end
end
