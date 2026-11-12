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
  a pure fold over the session's events. It holds no session state of its own. It runs
  over the wire on the server of the data folder (`docs/features/tui-attach.md`), whose
  handshake checks the protocol. Typing fills the composer (`Helyx.TUI.Composer`); a
  rejected send stays in it. `/help` lists the slash commands (`Helyx.TUI.Command`)
  and these keys, with the full rules in `docs/features/coding-agent.md`, "TUI":

  #{Enum.map_join(@keys, "\n", fn {key, text} -> "* #{key}: #{text}" end)}

  Start it with `run/1`, which blocks until the user quits:

      Helyx.TUI.run(session: %Helyx.TUI.Link{conn: conn, id: id})
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

  @margin 2

  @doc """
  Starts the TUI for a session and blocks until the user quits.

  The options are `:session`, a `Helyx.TUI.Link` with the connection that the caller
  opened (`Helyx.TUI.Wire.Connection`), which the TUI takes; `:resumed` (true when the
  session was resumed: an information cell "resumed session" follows the history),
  `:cwd` (the directory that the footer shows and the folder of `/new` and `/resume`,
  default `File.cwd!/0`), `:home` (the folder of the user skills that the mount scans,
  default `System.user_home!/0`), `:reconnect` (the connect after a lost connection:
  `{:ok, socket, ws}`, owned by the caller, or `{:error, text}`), `:notices` (lines of
  the caller, each a notice cell after those of the skills scan, default none), and
  those of `ExRatatui.App`. The scroll keys read the terminal size through
  `:terminal_size_fn`, the option of `ExRatatui.Server`; the default is
  `ExRatatui.terminal_size/0`.
  """
  @spec run(keyword()) :: :ok | {:error, term()}
  def run(opts), do: Start.run(fn -> start_link(Keyword.put_new(opts, :mouse_capture, true)) end)

  @impl true
  def mount(opts) do
    cwd = Keyword.get_lazy(opts, :cwd, &File.cwd!/0)
    home = Keyword.get_lazy(opts, :home, &System.user_home!/0)

    state = %{
      # The session and its subscription: `Helyx.TUI.Switch.bind/3`.
      session: nil,
      session_ref: nil,
      vm: nil,
      reconnect: opts[:reconnect],
      switch: nil,
      list: nil,
      search: nil,
      question: nil,
      composer: Composer.new(),
      cwd: cwd,
      # The folder of the user skills, for the mount scan.
      home: home,
      # Row 1 of the footer: the branch of a task at mount and after each turn.
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
    notices = Helyx.Skills.scan(cwd, home).notices ++ Keyword.get(opts, :notices, [])
    {:ok, %{state | vm: Enum.reduce(notices, state.vm, &ViewModel.notice(&2, &1))}}
  end

  # The `session_end` of the subscription, and the end of the connection.
  @impl true
  def handle_info({:helyx_end, sub, reason}, %{session_ref: sub} = state),
    do: {:noreply, Switch.down(state, reason)}

  # A reconnect can replay the end of a turn, so the branch is read again.
  def handle_info({:DOWN, _ref, :process, conn, reason}, %{session: %Link{conn: conn}} = state),
    do: {:noreply, settle(sync_busy(read_branch(Switch.reconnect(state, reason))))}

  def handle_info({:helyx_event, sub, event}, %{session_ref: sub} = state) do
    # A turn can change the branch; an event at or below the seq of the fold changes nothing.
    branch? = event.type == :turn_end and event.seq > state.vm.seq
    state = Switch.apply_event(state, event)
    {:noreply, settle(sync_busy(if branch?, do: read_branch(state), else: state))}
  end

  def handle_info({ref, result}, %{switch: %Switch{task: %Task{ref: ref}}} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, settle(sync_busy(Switch.done(state, result)))}
  end

  # ExRatatui traps exits, so a crash of the switch Task reaches the TUI as its `:DOWN`.
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

  # git runs in a task, so a slow git never holds a frame; `Footer.branch/1` bounds it.
  defp read_branch(%{cwd: cwd} = state),
    do: %{state | branch_ref: Task.async(fn -> Footer.branch(cwd) end).ref}

  # The next key press or paste clears the reason of the last reject, then runs as
  # usual. The release and the repeat of the rejected Enter keep the reason.
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

  # A toggle changes the rows of tool cells: a selection ends, a scrolled view stays.
  def handle_event(%Key{code: "o", kind: "press", modifiers: ["ctrl"]}, state) do
    state = %{state | vm: ViewModel.toggle_expanded(state.vm), selection: nil}
    {:noreply, settle(state, &Transcript.keep/4)}
  end

  # Escape aborts, also over a hidden search; a Task keeps the wait off the render loop.
  def handle_event(%Key{code: "esc", kind: "press"} = event, state) do
    if mode(state) == :search,
      do: Search.handle(event, state, layout(state, state.terminal_size_fn.())),
      else: {:noreply, tap(state, &Link.abort_async(&1.session))}
  end

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

  # Ctrl+J is a new line everywhere. Shift+Enter reaches here where the terminal reports it.
  def handle_event(%Key{code: code, kind: kind, modifiers: modifiers}, state)
      when {code, modifiers} in [{"j", ["ctrl"]}, {"enter", ["shift"]}] and
             kind in ["press", "repeat"] do
    {:noreply, edit(state, :insert, "\n")}
  end

  # No text goes to a session that a switch ends.
  def handle_event(%Key{code: "enter", kind: "press"}, %{switch: %Switch{}} = state),
    do: {:noreply, %{state | vm: ViewModel.reject(state.vm, "not sent: a switch runs")}}

  def handle_event(%Key{code: "enter", kind: "press"} = key, state) do
    case Composer.submit(state.composer) do
      :empty -> {:noreply, state}
      {:message, text} -> {:noreply, send_message(text, key, state)}
      # A notice is a new cell, so the position gets its check.
      command -> {:noreply, settle(run_command(command, state))}
    end
  end

  def handle_event(%Key{code: code, kind: kind, modifiers: []}, state)
      when code in ["up", "down"] and kind in ["press", "repeat"],
      do: {:noreply, edit(state, &Composer.recall(&1, state.vm, code))}

  # Only Ctrl+J and Shift+Enter add a line; a repeat or release of Enter does nothing.
  def handle_event(%Key{code: "enter"}, state), do: {:noreply, state}

  def handle_event(%Key{kind: kind} = key, state) when kind in ["press", "repeat"],
    do: {:noreply, edit(state, &Composer.press(&1, key.code, key.modifiers))}

  def handle_event(%Paste{content: content}, state),
    do: {:noreply, edit(state, :paste, content)}

  def handle_event(_event, state), do: {:noreply, state}

  # An edit that changes the composer height changes the screen of the transcript.
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
    do: %{restore(state) | list: SessionList.new(state.session, state.cwd)}

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
      case mode(state) do
        :list -> [{SessionList.widget(state.list), middle}]
        :question -> Question.widgets(state.question, middle)
        :search -> Search.widgets(state.search, marks, middle)
        :composer -> Composer.widgets(state.composer, middle)
      end

    # A switch that runs is an open that the footer shows (tui-attach.md, decision 17).
    loading = state.switch != nil

    hint = Quit.hint(state.quit, Composer.nothing_to_clear?(state.composer))
    bottom = Footer.widget(state.location, state.vm, state.busy, state.scroll, hint, loading)

    Selection.widgets(state.selection, rows, transcript) ++ marks ++ middle ++ [{bottom, footer}]
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

  # The middle of the screen: the list, then the picker, then the search, then the composer.
  defp mode(%{list: %SessionList{}}), do: :list
  defp mode(%{question: question}) when question != nil, do: :question
  defp mode(%{search: search}) when search != nil, do: :search
  defp mode(_state), do: :composer

  # The search takes the box of the composer, so it has the composer's rows.
  defp middle_rows(state, width, room), do: middle_rows(mode(state), state, width, room)
  defp middle_rows(:list, state, _width, room), do: SessionList.rows(state.list, room)
  defp middle_rows(:question, state, width, room), do: Question.rows(state.question, width, room)

  defp middle_rows(_search_or_composer, state, _width, room),
    do: Composer.rows(state.composer, room)

  # The position from the transcript rect, one row at least; with no size the view follows.
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

  # ExRatatui keeps one timer per id, armed while this list holds it: one
  # tick timer while a turn runs, and none while idle.
  @impl true
  def subscriptions(%{busy: nil}), do: []
  def subscriptions(_state), do: [Subscription.interval(:busy, Footer.tick_ms(), :busy_tick)]

  defp sync_busy(state), do: %{state | busy: Footer.busy(state.busy, state.vm)}

  # At quit, a switch that runs ends, and a session that it opened runs on
  # in the server, as the current one does (decision 8); ExRatatui has
  # restored the terminal.
  @impl true
  def terminate(_reason, state) do
    if state.switch, do: Task.shutdown(state.switch.task, :brutal_kill)
    :ok
  end
end
