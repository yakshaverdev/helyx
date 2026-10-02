# ex_ratatui is an optional dependency (ADR 0005): without it Helyx.TUI does
# not exist, and a product that wants the TUI adds ex_ratatui itself.
defmodule Helyx.TUI.Available do
  @moduledoc false
  # A product can add or remove ex_ratatui after its first build, and Mix does
  # not see that as a reason to compile this file again. Two parts make it do
  # so, and both are necessary (measurements in ADR 0005). This module always
  # exists and lives in this file, because Mix reaches a stale source only
  # through a module the source defines. `__mix_recompile__?/0` tells Mix on
  # every compile whether the answer changed.

  @available Code.ensure_loaded?(ExRatatui.App)

  @spec available?() :: boolean()
  def available?, do: @available

  @spec __mix_recompile__?() :: boolean()
  def __mix_recompile__?, do: Code.ensure_loaded?(ExRatatui.App) != @available
end

if Helyx.TUI.Available.available?() do
  defmodule Helyx.TUI do
    @moduledoc """
    The terminal interface, an `ExRatatui.App` in the alternate screen.

    The TUI subscribes to one session and renders from `Helyx.TUI.ViewModel`,
    a pure fold over the session's events. It holds no session state of its
    own. It supports version 1 of the client contract (ADR 0006). For a
    snapshot of another version it shows a message and not the session. Then
    only Ctrl+C and the end of the session stop it. Keys:

      * typing fills the composer (`ExRatatui.Widgets.Textarea`: cursor
        movement, Home/End, Delete, Backspace). It grows to at most 8 lines
        and scrolls to the cursor past that
      * Ctrl+J adds a new line; so does Shift+Enter where the terminal
        reports Shift on Enter
      * a paste keeps its new lines and tabs. A paste of more than 5 lines
        shows as one marker, `[Pasted text #1, 20 lines]`, and is sent in
        full. A marker is one unit: Backspace and Delete remove it whole,
        Left and Right pass over it, and text typed in it goes after it.
        Text that only looks like a marker is sent as typed
      * Enter sends the composer as a steer (a prompt when no turn runs)
      * Alt+Enter sends it as a follow-up. A rejected send (full queue) stays
        in the composer, and the status bar
        shows the reason until the next key press or paste
      * `/model provider/model` in the composer switches the model; the next
        turn uses it. A rejected ref shows a notice and stays in the composer
      * Escape aborts the running turn
      * PgUp and PgDn scroll the transcript by one screen. While the view is
        scrolled, new output does not move it, and the status bar says so.
        Ctrl+End, a PgDn at the end, or a sent prompt returns to the newest
        output
      * Ctrl+C quits and restores the terminal

    Start it with `run/1`, which blocks until the user quits:

        Helyx.TUI.run(session: session)
    """

    use ExRatatui.App

    alias ExRatatui.Event.{Key, Paste, Resize}
    alias ExRatatui.Layout
    alias ExRatatui.Layout.Rect
    alias ExRatatui.Style
    alias ExRatatui.Text.{Line, Span}
    alias ExRatatui.Widgets.{Block, Paragraph, Textarea}
    alias Helyx.{Message, Session}
    alias Helyx.TUI.ViewModel

    # The one version of the client contract (ADR 0006) that this client
    # supports. A snapshot of another version shows only a message.
    @contract_version 2

    @dim %Style{modifiers: [:dim]}
    @bold %Style{modifiers: [:bold]}
    @tool %Style{fg: :cyan}
    @bad %Style{fg: :red}

    # The rows under the transcript. One screen of scroll is the rest. The
    # composer shows at most `@composer_lines` lines inside its two borders.
    @composer_lines 8
    @status_rows 1

    # A paste of more lines than this shows as one marker.
    @paste_lines 5

    # The last character of a marker, a control character. A paste drops it.
    # A key code with it goes nowhere. ExRatatui does not draw it. So only a
    # marker that the composer made ends with it, and text that looks like a
    # marker is sent as typed.
    @marker_end "\u0001"

    # East Asian Wide and Fullwidth blocks, the emoji blocks, and other ranges
    # that ExRatatui draws as two columns.
    @wide_ranges [
      0x1100..0x115F,
      0x2329..0x232A,
      0x2630..0x2637,
      0x268A..0x268F,
      0x2E80..0x303E,
      0x3041..0xA4CF,
      0xA960..0xA97F,
      0xAC00..0xD7A3,
      0xF900..0xFAFF,
      0xFE10..0xFE19,
      0xFE30..0xFE6F,
      0xFF01..0xFF60,
      0xFFE0..0xFFE6,
      0x16FE0..0x18DFF,
      0x1AFF0..0x1B2FF,
      0x1D300..0x1D37F,
      0x1F18E..0x1F19A,
      0x1F1E6..0x1F2FF,
      0x1F300..0x1F64F,
      0x1F680..0x1F6FF,
      0x1F7E0..0x1F7F0,
      0x1F900..0x1F9FF,
      0x1FA70..0x1FAFF,
      0x20000..0x3FFFD
    ]

    # The emoji outside the emoji blocks that are two columns with no selector.
    @wide_symbols Enum.concat([
                    [0x231A, 0x231B, 0x23F0, 0x23F3, 0x25FD, 0x25FE, 0x2614, 0x2615],
                    [0x267F, 0x2693, 0x26A1, 0x26AA, 0x26AB, 0x26BD, 0x26BE, 0x26C4],
                    [0x26C5, 0x26CE, 0x26D4, 0x26EA, 0x26F2, 0x26F3, 0x26F5, 0x26FA],
                    [0x26FD, 0x2705, 0x270A, 0x270B, 0x2728, 0x274C, 0x274E, 0x2757],
                    [0x27B0, 0x27BF, 0x2B1B, 0x2B1C, 0x2B50, 0x2B55, 0x1F004, 0x1F0CF],
                    0x23E9..0x23EC,
                    0x2648..0x2653,
                    0x2753..0x2755,
                    0x2795..0x2797
                  ])

    @doc """
    Starts the TUI for a session and blocks until the user quits.

    The options are `:session`, `:resumed` (true when the session was
    resumed: a notice "resumed session" follows the history), and those of
    `ExRatatui.App`. The scroll keys read the terminal size through
    `:terminal_size_fn`, the option of `ExRatatui.Server`; the default is
    `ExRatatui.terminal_size/0`.
    """
    @spec run(keyword()) :: :ok | {:error, term()}
    def run(opts) do
      # A failed init (dead session, no terminal) exits the linked caller
      # before start_link can return the error. Trapping for just the start
      # window turns that into the {:error, reason} return; the flag is
      # restored before blocking, so the caller's other links keep their kill
      # semantics while the TUI runs.
      trap = Process.flag(:trap_exit, true)

      case start_link(opts) do
        {:ok, pid} ->
          ref = Process.monitor(pid)
          # Unlinked, an abnormal exit reaches the receive as a DOWN instead
          # of killing the caller through the link before it can return the
          # error. Unlink before restoring the flag, so no kill window opens.
          Process.unlink(pid)
          Process.flag(:trap_exit, trap)

          receive do
            {:DOWN, ^ref, :process, ^pid, :normal} -> flush_exit(pid, :ok)
            {:DOWN, ^ref, :process, ^pid, reason} -> flush_exit(pid, {:error, reason})
          end

        {:error, reason} ->
          # proc_lib unlinks and flushes the dead child's exit signal before
          # start_link returns an error, so there is nothing to drain here.
          Process.flag(:trap_exit, trap)
          {:error, reason}
      end
    end

    # A crash inside the trap window queues an {:EXIT, pid, _} message the
    # restored flag can no longer prevent; drop it with the result.
    defp flush_exit(pid, result) do
      receive do
        {:EXIT, ^pid, _reason} -> result
      after
        0 -> result
      end
    end

    @impl true
    def mount(opts) do
      session = Keyword.fetch!(opts, :session)

      # The screen starts from the snapshot: the history of a resumed
      # session, and the turn a late client joins.
      snapshot = subscribe!(session)

      # The end signal of the subscription ends the TUI (see handle_info/2).
      case snapshot do
        %Session.Snapshot{contract_version: @contract_version} ->
          session_state(session, snapshot, opts)

        # ADR 0006, section 5: say so, and do not read or render the session.
        %Session.Snapshot{} ->
          {:ok, %{unsupported: true, session: session}}
      end
    end

    defp session_state(session, snapshot, opts) do
      vm = ViewModel.from_snapshot(snapshot)
      vm = if opts[:resumed], do: ViewModel.notice(vm, "resumed session"), else: vm

      {:ok,
       %{
         session: session,
         vm: vm,
         input: ExRatatui.textarea_new(),
         # Marker text to the full paste it stands for. Emptied with the
         # composer, so a marker id is the map size plus one.
         pastes: %{},
         # nil follows the newest output. `{cell, row}` is the first row on
         # the screen: a cell index and a row in that cell.
         scroll: nil,
         # The size seam of `ExRatatui.Server`, so a test sets the size.
         terminal_size_fn: Keyword.get(opts, :terminal_size_fn, &ExRatatui.terminal_size/0)
       }}
    end

    # A dead session leaves nothing to render; exiting surfaces the reason
    # through run/1 instead of an idle screen that rejects every key. The
    # events before the signal are already applied.
    @impl true
    def handle_info(
          {{:helyx_session_end, id}, _ref, :process, _pid, reason},
          %{session: %Session{id: id}}
        ),
        do: exit({:session_down, Session.end_reason(reason)})

    # An unsupported session shows only its message; its events do nothing.
    def handle_info({:helyx_event, _event}, %{unsupported: true} = state),
      do: {:noreply, state}

    def handle_info({:helyx_event, event}, state) do
      {:noreply, settle(%{state | vm: ViewModel.apply(state.vm, event)})}
    end

    def handle_info(_msg, state), do: {:noreply, state}

    # A session that is not running leaves nothing to render.
    defp subscribe!(session) do
      case Session.subscribe(session) do
        {:ok, snapshot} -> snapshot
        {:error, :session_not_found} -> exit({:session_down, :session_not_found})
      end
    end

    # The next key press or paste clears the reason of the last reject, then
    # runs as usual, so it can set a new reason. The release and the repeat of
    # a key are not a new press: those of the rejected Enter keep the reason.
    @impl true
    def handle_event(%Key{kind: "press"} = key, %{vm: %ViewModel{reason: reason}} = state)
        when is_binary(reason),
        do: handle_event(key, %{state | vm: ViewModel.clear_reason(state.vm)})

    def handle_event(%Paste{} = paste, %{vm: %ViewModel{reason: reason}} = state)
        when is_binary(reason),
        do: handle_event(paste, %{state | vm: ViewModel.clear_reason(state.vm)})

    def handle_event(%Key{code: "c", modifiers: ["ctrl"]}, state), do: {:stop, state}

    def handle_event(_event, %{unsupported: true} = state), do: {:noreply, state}

    def handle_event(%Key{code: "esc", kind: "press"}, state) do
      # Abort waits for the hands to kill every OS process; a Task keeps that
      # wait off the render loop.
      session = state.session
      Task.start(fn -> Session.abort(session) end)
      {:noreply, state}
    end

    def handle_event(%Key{code: code, kind: kind, modifiers: []}, state)
        when code in ["page_up", "page_down"] and kind in ["press", "repeat"] do
      {:noreply, on_screen(state, &scroll(state, code, &1, &2))}
    end

    def handle_event(%Resize{}, state), do: {:noreply, settle(state)}

    def handle_event(%Key{code: "end", kind: "press", modifiers: ["ctrl"]}, state),
      do: {:noreply, %{state | scroll: nil}}

    # Ctrl+J is a new line in every terminal. Shift+Enter reaches here only
    # where the terminal reports Shift on Enter; elsewhere it is Enter.
    def handle_event(%Key{code: code, kind: kind, modifiers: modifiers}, state)
        when {code, modifiers} in [{"j", ["ctrl"]}, {"enter", ["shift"]}] and
               kind in ["press", "repeat"] do
      {:noreply, edit(state, "\n", &insert/2)}
    end

    def handle_event(%Key{code: "enter", kind: "press"} = key, state) do
      case ExRatatui.textarea_get_value(state.input) do
        "" ->
          {:noreply, state}

        value ->
          text = expand(value, state.pastes)

          case command(text) do
            # A notice is a new cell, so the position gets its check.
            {:model, ref} -> {:noreply, settle(switch_model(ref, state))}
            :message -> {:noreply, send_message(text, key, state)}
          end
      end
    end

    # Only Ctrl+J and Shift+Enter add a line: the repeat and the release of
    # Enter do nothing.
    def handle_event(%Key{code: "enter"}, state), do: {:noreply, state}

    # Everything else goes to the input widget, which inserts printable
    # characters and handles its own editing keys. A paste marker is one
    # unit for every key.
    def handle_event(%Key{} = key, state) do
      if key.kind in ["press", "repeat"] and key.modifiers -- ["shift"] == [] do
        {:noreply, edit(state, key.code, &widget_key/2)}
      else
        {:noreply, state}
      end
    end

    def handle_event(%Paste{content: content}, state),
      do: {:noreply, edit(state, content, &paste/2)}

    def handle_event(_event, state), do: {:noreply, state}

    # The only path by which event text reaches the widget. The widget raises
    # `ArgumentError` on text that is not valid UTF-8, and a raise in a
    # callback kills the TUI process. Reject, do not repair: a silent
    # replacement would send text the user did not type. An edit that
    # changes the composer height changes the screen of the transcript, so
    # the position gets its check.
    defp edit(state, text, fun) do
      if is_binary(text) and String.valid?(text) do
        rows = composer_rows(state.input)
        state = fun.(state, text)
        if composer_rows(state.input) == rows, do: state, else: settle(state)
      else
        %{state | vm: ViewModel.reject(state.vm, "input rejected: not valid UTF-8")}
      end
    end

    # Text never goes inside a marker: it goes after it.
    defp insert(state, text) do
      state = out_of_marker(state)
      ExRatatui.textarea_insert_str(state.input, text)
      state
    end

    # A marker is one unit for every key. Backspace in a marker or right
    # after it, and Delete at a marker or in it, remove the whole marker.
    # Left and Right pass over it in one step. Any other key with the cursor
    # inside a marker acts at its end.
    defp widget_key(state, code) when code in ["backspace", "delete", "left", "right"] do
      case marker_at(state, code) do
        nil ->
          key(state, code)

        {value, {start, stop}} when code in ["backspace", "delete"] ->
          cut(state, value, start, stop)

        {value, {_start, stop}} when code == "right" ->
          cut(state, value, stop, stop)

        {value, {start, _stop}} ->
          cut(state, value, start, start)
      end
    end

    # A key code with a control character could forge the end of a marker.
    defp widget_key(state, code) do
      if drop_controls(code) == code,
        do: state |> out_of_marker() |> key(code),
        else: state
    end

    defp hit?(code, cursor, {start, stop}) when code in ["backspace", "left"],
      do: start < cursor and cursor <= stop

    defp hit?(code, cursor, {start, stop}) when code in ["delete", "right"],
      do: start <= cursor and cursor < stop

    defp hit?(:inside, cursor, {start, stop}), do: start < cursor and cursor < stop

    defp out_of_marker(state) do
      case marker_at(state, :inside) do
        nil -> state
        {value, {_start, stop}} -> cut(state, value, stop, stop)
      end
    end

    defp key(state, code) do
      ExRatatui.textarea_handle_key(state.input, code, [])
      state
    end

    # The composer becomes `value` without the bytes from `from` to `to`,
    # with the cursor at `from`. ExRatatui has no call to set the cursor or to
    # delete a range, and its Right key stops short of zero-width characters
    # at the end of a line. `textarea_insert_str/2` leaves the cursor exactly
    # at the end of the text it inserts, so the TUI sets the text after the
    # cursor and inserts the text before it. Linear in the composer text.
    defp cut(state, value, from, to) do
      ExRatatui.textarea_set_value(state.input, binary_part(value, to, byte_size(value) - to))
      ExRatatui.textarea_insert_str(state.input, binary_part(value, 0, from))
      state
    end

    # The composer text and the byte span of the live marker that `hit?/3`
    # finds for the cursor, or nil. The cursor column counts code points, so
    # one walk of the cursor line turns it into a byte offset. One read of
    # the composer and one search for all markers: linear in the composer
    # text.
    defp marker_at(%{pastes: pastes}, _code) when map_size(pastes) == 0, do: nil

    defp marker_at(state, code) do
      {row, column} = ExRatatui.textarea_cursor(state.input)
      value = ExRatatui.textarea_get_value(state.input)
      {above, [line | _]} = value |> String.split("\n", parts: row + 2) |> Enum.split(row)
      line_start = Enum.reduce(above, 0, &(byte_size(&1) + 1 + &2))

      cursor =
        line |> String.to_charlist() |> Enum.take(column) |> List.to_string() |> byte_size()

      spans =
        for {at, size} <- :binary.matches(value, Map.keys(state.pastes)), do: {at, at + size}

      case Enum.find(spans, &hit?(code, line_start + cursor, &1)) do
        nil -> nil
        span -> {value, span}
      end
    end

    # A terminal can send a pasted new line as CR. Control characters other
    # than tab and new line drop, as in the transcript.
    defp paste(state, content) do
      text = content |> String.replace(["\r\n", "\r"], "\n") |> drop_controls()

      case line_count(text) do
        lines when lines > @paste_lines ->
          marker = "[Pasted text ##{map_size(state.pastes) + 1}, #{lines} lines]" <> @marker_end
          insert(%{state | pastes: Map.put(state.pastes, marker, text)}, marker)

        _lines ->
          insert(state, text)
      end
    end

    # A final new line does not start a line.
    defp line_count(text) do
      newlines = length(:binary.matches(text, "\n"))
      if String.ends_with?(text, "\n"), do: newlines, else: newlines + 1
    end

    # One pass, so a marker inside a paste is not expanded.
    defp expand(value, pastes) when map_size(pastes) == 0, do: value

    defp expand(value, pastes),
      do: String.replace(value, Map.keys(pastes), &Map.fetch!(pastes, &1))

    defp clear_composer(state) do
      ExRatatui.textarea_set_value(state.input, "")
      %{state | pastes: %{}}
    end

    # `/model` is the only command. The rule is on bytes, not on looks; the
    # feature doc's bounds table holds the rule and its limit. A paste keeps
    # tabs and new lines, so `/model<tab>a/b` has a separator. The text is
    # the composer with its paste markers expanded. The ref goes to
    # `Helyx.ModelRef` unsplit, which owns its bounds. The widget holds only
    # valid UTF-8; the `u` flag raises on anything else.
    defp command(text) do
      case Regex.run(~r/\A[\s\p{C}]*\/model([\s\p{C}]*)/u, text, return: :index) do
        nil -> :message
        [{0, head}, {_, 0}] when head < byte_size(text) -> {:model, ""}
        [{0, head}, _] -> {:model, String.trim(binary_part(text, head, byte_size(text) - head))}
      end
    end

    defp send_message(text, key, state) do
      sent =
        if "alt" in key.modifiers do
          Session.follow_up(state.session, text)
        else
          Session.steer(state.session, text)
        end

      # A rejected message stays in the composer, and the status bar says why.
      case sent do
        :ok ->
          %{clear_composer(state) | scroll: nil}

        # `edit/3` lets only valid UTF-8 into the composer, so the session
        # never answers `:invalid_utf8`.
        {:error, :queue_full} ->
          %{state | vm: ViewModel.reject(state.vm, "not sent: the queue is full")}

        # The end signal of the session ends the TUI next.
        {:error, :session_not_found} ->
          %{state | vm: ViewModel.reject(state.vm, "not sent: the session ended")}
      end
    end

    defp switch_model("", state),
      do: %{state | vm: ViewModel.notice(state.vm, "usage: /model provider/model")}

    # The status bar follows the session's `:model_change` event, not this
    # call. A rejected ref stays in the composer, under a notice.
    defp switch_model(ref, state) do
      case Session.set_model(state.session, ref) do
        :ok ->
          clear_composer(state)

        {:error, reason} ->
          %{state | vm: ViewModel.notice(state.vm, switch_error(reason))}
      end
    end

    # A notice shows at most the provider id, which the ref bounds cap.
    defp switch_error({:unknown_provider, id}), do: "unknown provider: #{id}"

    defp switch_error({:invalid_model_ref, _ref}), do: "invalid model ref: use provider/model"
    defp switch_error(:session_not_found), do: "the session ended"

    @impl true
    def render(%{unsupported: true}, frame) do
      text =
        "This client supports only client contract version #{@contract_version}, " <>
          "and the session uses another version. Update the client. Ctrl+C quits."

      area = %Rect{x: 0, y: 0, width: frame.width, height: frame.height}
      [{%Paragraph{text: text, wrap: true}, area}]
    end

    def render(state, frame) do
      area = %Rect{x: 0, y: 0, width: frame.width, height: frame.height}

      [transcript, composer, status] =
        Layout.split(area, :vertical, [
          {:min, 0},
          {:length, composer_rows(state.input, frame.height)},
          {:length, @status_rows}
        ])

      [
        {transcript_widget(state.vm, state.scroll, transcript), transcript},
        {composer_widget(state.input), composer},
        {status_widget(state.vm, state.scroll), status}
      ]
    end

    # Transcript

    # A scrolled view starts at a cell and a row in it. The cells before the
    # open message only grow in number, so new output does not move the view.
    # No line cache: no operation wraps all cells. A frame wraps the cells it
    # shows, and a key or `settle/1` wraps the cells it passes, a small count
    # of screens. The feature doc has the measured costs and the exceptions.
    # With no position the view follows the newest output: the first row is
    # one screen above the end.
    defp transcript_widget(vm, scroll, %Rect{width: width, height: height}) do
      items = items(vm)
      top = scroll || bottom(items, width, height)
      %Paragraph{text: items |> rows_from(top, width) |> Enum.take(height)}
    end

    defp bottom(items, width, height),
      do: back(Enum.reverse(items), {length(items), 0}, height, width)

    # Sets the position from the width and the rows of the transcript. The
    # only reader of the terminal size. With no size there is no screen to
    # check a position against, so the view follows the newest output.
    defp on_screen(state, position) do
      case state.terminal_size_fn.() do
        {width, height} when is_integer(width) and is_integer(height) ->
          rows = max(height - composer_rows(state.input, height) - @status_rows, 1)
          %{state | scroll: position.(width, rows)}

        {:error, _reason} ->
          %{state | scroll: nil}
      end
    end

    # Applies `hold/4` after a change that no scroll key makes: a session
    # event, a client notice, or a new size.
    defp settle(%{scroll: nil} = state), do: state

    defp settle(state),
      do: on_screen(state, &hold(items(state.vm), state.scroll, &1, &2))

    # The one rule for a position: its row is in its cell, and the rows from
    # it to the end are more than one screen. If not, the row moves into the
    # cells that follow, or the result is nil. A new cell can take the index
    # of the open message, and a wider screen makes a cell shorter. Every
    # position in the state comes from here or is nil.
    defp hold(items, {index, row}, width, height) do
      top = items |> Enum.drop(index) |> forward({index, row}, width)
      if length(items |> rows_from(top, width) |> Enum.take(height + 1)) > height, do: top
    end

    # One screen up or down from the first row on the screen.
    defp scroll(%{scroll: nil}, "page_down", _width, _height), do: nil

    defp scroll(%{vm: vm, scroll: {index, row}}, "page_down", width, height),
      do: hold(items(vm), {index, row + height}, width, height)

    defp scroll(%{vm: vm, scroll: scroll}, "page_up", width, height) do
      items = items(vm)
      {index, row} = scroll || bottom(items, width, height)
      top = items |> Enum.take(index) |> Enum.reverse() |> back({index, row}, height, width)
      hold(items, top, width, height)
    end

    # `before` is the cells above the position, nearest first.
    defp back(_before, {index, row}, count, _width) when row >= count, do: {index, row - count}
    defp back([], _position, _count, _width), do: {0, 0}

    defp back([item | before], {index, row}, count, width),
      do: back(before, {index - 1, length(item_lines(item, width))}, count - row, width)

    # Moves a row number that is past its cell into the cells that follow.
    defp forward([], {index, _row}, _width), do: {index, 0}

    defp forward([item | rest], {index, row}, width) do
      case length(item_lines(item, width)) do
        rows when row >= rows -> forward(rest, {index + 1, row - rows}, width)
        _rows -> {index, row}
      end
    end

    # The row skip stays in the first cell: a row past that cell shows its last
    # row. A frame can come before the check of a new width, and a skip over
    # all rows would wrap every cell that the old row number passes.
    defp rows_from(items, {index, row}, width) do
      case Enum.drop(items, index) do
        [] ->
          []

        [first | rest] ->
          lines = item_lines(first, width)

          lines
          |> Enum.drop(min(row, length(lines) - 1))
          |> Stream.concat(Stream.flat_map(rest, &item_lines(&1, width)))
      end
    end

    @doc false
    # Public for tests: the transcript as width-bounded `Line` structs.
    def transcript_lines(%ViewModel{} = vm, width),
      do: Enum.flat_map(items(vm), &item_lines(&1, width))

    # The cells, and the open assistant message as the last one.
    defp items(%ViewModel{streaming: nil, cells: cells}), do: cells

    defp items(%ViewModel{streaming: streaming, cells: cells}),
      do: cells ++ [%Message{role: :assistant, content: Enum.reverse(streaming)}]

    defp item_lines(item, width), do: cell_lines(item, width) ++ [%Line{}]

    defp cell_lines(%Message{role: :user} = message, width) do
      styled_lines("› " <> Message.text(message), width, @bold)
    end

    defp cell_lines(%Message{role: :assistant} = message, width) do
      block_lines(message.content, width)
    end

    defp cell_lines({:tool, _call, line, result}, width) do
      styled_lines(line, width, @tool) ++ result_lines(result, width)
    end

    defp cell_lines({:notice, text}, width), do: styled_lines("✕ #{text}", width, @bad)

    defp block_lines(blocks, width) do
      Enum.flat_map(blocks, fn
        %Message.Text{text: text} -> styled_lines(text, width, %Style{})
        %Message.Thinking{thinking: text} -> styled_lines(text, width, @dim)
        %Message.ToolCall{} -> []
      end)
    end

    defp result_lines(nil, width), do: styled_lines("… running", width, @dim)

    # Long tool output would drown the transcript; four lines tell the story.
    defp result_lines(%Message{} = result, width) do
      style = if result.is_error, do: @bad, else: @dim
      lines = result |> Message.text() |> String.trim_trailing("\n") |> String.split("\n")

      shown = Enum.flat_map(Enum.take(lines, 4), &styled_lines("  " <> &1, width, style))

      case length(lines) - 4 do
        hidden when hidden > 0 ->
          plural = if hidden == 1, do: "line", else: "lines"
          shown ++ styled_lines("  … #{hidden} more #{plural}", width, @dim)

        _ ->
          shown
      end
    end

    # One styled Line per screen row: split on newlines, then wrap to width.
    defp styled_lines(text, width, style) do
      for source_line <- text |> sanitize() |> String.split("\n"),
          chunk <- wrap(source_line, width) do
        %Line{spans: [%Span{content: chunk, style: style}]}
      end
    end

    # Model text and tool output reach the terminal raw through span content,
    # so an ESC, OSC, or CSI sequence in a file could retitle the terminal or
    # move the cursor. Tabs become spaces; other control characters drop.
    # Core makes the text valid UTF-8 at its boundaries, so the /u regex
    # does not raise, and a CSI can only be U+009B, which drops.
    defp sanitize(text), do: text |> String.replace("\t", "  ") |> drop_controls()

    # All C0 and C1 control characters but tab and new line.
    defp drop_controls(text),
      do: String.replace(text, ~r/[\x00-\x08\x0B-\x1F\x7F\x{80}-\x{9F}]/u, "")

    # The wrap is one pure function from a line and a width to its rows. No
    # row is wider than `width` columns, with one exception: a glyph wider than
    # the whole width gets a row of its own, so that the wrap always ends.
    # Fast path: no code point has more columns than bytes, so a line of
    # `width` bytes or less is one row. This also covers the empty line.
    defp wrap(line, width) when byte_size(line) <= width, do: [line]

    defp wrap(line, width) do
      width = max(width, 1)

      {rows, row, _used} =
        line
        |> String.graphemes()
        |> Enum.reduce({[], [], 0}, fn grapheme, {rows, row, used} ->
          needs = columns(grapheme)

          if used + needs > width and row != [],
            do: {[row | rows], [grapheme], needs},
            else: {rows, [grapheme | row], used + needs}
        end)

      Enum.map(Enum.reverse([row | rows]), &(&1 |> Enum.reverse() |> Enum.join()))
    end

    # ponytail: a short width rule, not the Unicode tables (ticket #90).
    # ExRatatui has no width function in Elixir, and OTP has no
    # `:string.width/1`. The rule must never count less than ExRatatui draws,
    # because ExRatatui cuts a row at the edge. So it has no rule for an emoji
    # sequence: ExRatatui draws an emoji with a skin tone, a joiner sequence, or
    # a flag as two columns, and this rule counts each emoji in it. Such a row
    # is shorter than it could be. Replace this with a width function of
    # ExRatatui when it has one.
    #
    # Fast path: the clause below gives the same result for ASCII.
    defp columns(<<byte>>) when byte < 0x80, do: 1
    defp columns(grapheme), do: sum_columns(grapheme, 0)

    # ExRatatui adds the code points of a grapheme: a Devanagari cluster can be
    # four columns. The emoji selector U+FE0F makes the code point before it
    # two columns.
    defp sum_columns(<<code::utf8, 0xFE0F::utf8, rest::binary>>, sum),
      do: sum_columns(rest, sum + max(code_point_columns(code), 2))

    defp sum_columns(<<code::utf8, rest::binary>>, sum),
      do: sum_columns(rest, sum + code_point_columns(code))

    defp sum_columns(<<>>, sum), do: sum

    # Combining marks, zero-width spaces, joiners and direction marks, variation
    # selectors, emoji tags, and the Hangul vowels and finals that join the
    # syllable before them. Marks of other scripts count as one column.
    defp code_point_columns(code)
         when code in 0x0300..0x036F or code in 0x1160..0x11FF or code in 0x200B..0x200F or
                code in 0x20D0..0x20F0 or code in 0xFE00..0xFE0F or code in 0xFE20..0xFE2F or
                code in 0xE0000..0xE0FFF,
         do: 0

    # Two Khmer code points that ExRatatui draws as the letters they stand for.
    defp code_point_columns(0x17A4), do: 2
    defp code_point_columns(0x17D8), do: 3
    defp code_point_columns(code), do: if(wide?(code), do: 2, else: 1)

    # East Asian Wide and Fullwidth, and the emoji that are wide by default.
    # No code point below U+1100 is wide.
    defp wide?(code) when code < 0x1100, do: false

    # One guard clause for each range: `in` on a range that is not a literal
    # goes through a protocol for each code point.
    for first..last//_ <- @wide_ranges do
      defp wide?(code) when code in unquote(first)..unquote(last), do: true
    end

    defp wide?(code), do: code in @wide_symbols

    # Composer and status

    defp composer_rows(input),
      do: min(ExRatatui.textarea_line_count(input), @composer_lines) + 2

    # The composer shrinks, down to one line, before the transcript loses its
    # last row. So the drawn screen is the scroll screen at 5 rows or more.
    defp composer_rows(input, height),
      do: min(composer_rows(input), max(height - @status_rows - 1, 3))

    defp composer_widget(input) do
      %Textarea{
        state: input,
        cursor_style: %Style{modifiers: [:reversed]},
        block: %Block{borders: [:all], title: "prompt"}
      }
    end

    defp status_widget(vm, scroll) do
      state = if vm.running?, do: "working", else: "idle"
      %{steers: steers, follow_ups: follow_ups} = vm.queue
      # The reason is a fixed text of this module, never input. It comes
      # first: the line does not wrap, and a model ref can be 256 bytes.
      reason = if vm.reason, do: [%Span{content: " ✕ #{vm.reason} ", style: @bad}], else: []

      model = %Span{
        content: " #{vm.model} · #{state} · queued #{steers}+#{follow_ups} ",
        style: @bold
      }

      keys =
        if scroll,
          do: %Span{content: " scrolled · PgUp/PgDn · Ctrl+End newest", style: @bold},
          else: %Span{
            content:
              " Enter steer · Alt+Enter follow-up · Ctrl+J newline · Esc abort · Ctrl+C quit · PgUp scroll",
            style: @dim
          }

      %Paragraph{text: %Line{spans: reason ++ [model, keys]}}
    end
  end
end
