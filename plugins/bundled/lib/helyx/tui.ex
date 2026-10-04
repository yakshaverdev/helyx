# ex_ratatui is an optional dependency (ADR 0005): without it Helyx.TUI does
# not exist, and a product that wants the TUI adds ex_ratatui itself.
defmodule Helyx.TUI.Available do
  @moduledoc false
  use Helyx.TUI.Guard
end

if Helyx.TUI.Available.available?() do
  defmodule Helyx.TUI do
    @moduledoc """
    The terminal interface, an `ExRatatui.App` in the alternate screen.

    The TUI subscribes to one session and renders from `Helyx.TUI.ViewModel`,
    a pure fold over the session's events. It holds no session state of its
    own. It runs in the node of its Core, so it has the Helyx version of that
    Core and needs no version check (ADR 0006). Keys, with the full rules in
    `docs/features/coding-agent.md`, "TUI":

      * typing fills the composer (`Helyx.TUI.Composer`), at most 8 lines high
      * Ctrl+J adds a new line; so does Shift+Enter where the terminal reports it
      * a paste of more than 5 lines shows as one marker and is sent in full
      * Enter sends the composer as a steer (a prompt when no turn runs)
      * Alt+Enter sends it as a follow-up; a rejected send stays in the composer
      * `/model provider/model` in the composer switches the model
      * Escape aborts the running turn
      * PgUp and PgDn scroll the transcript (`Helyx.TUI.Transcript`) by one screen
      * Ctrl+End returns to the newest output
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
    alias ExRatatui.Widgets.Paragraph
    alias Helyx.Session
    alias Helyx.TUI.{Composer, Transcript, ViewModel}

    @dim %Style{modifiers: [:dim]}
    @bold %Style{modifiers: [:bold]}
    @bad %Style{fg: :red}

    # The status row under the composer. One screen of scroll is the rows
    # above both.
    @status_rows 1

    @doc """
    Starts the TUI for a session and blocks until the user quits.

    The options are `:session`, `:resumed` (true when the session was
    resumed: an information cell "resumed session" follows the history),
    and those of `ExRatatui.App`. The scroll keys read the terminal size through
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
      # session, and the turn a late client joins. The end signal of the
      # subscription ends the TUI (see handle_info/2).
      {snapshot, ref} = subscribe!(session)
      vm = ViewModel.from_snapshot(snapshot)
      vm = if opts[:resumed], do: ViewModel.info(vm, "resumed session"), else: vm

      {:ok,
       %{
         session: session,
         # The monitor of the session from the subscribe: its `:DOWN` is
         # the end signal.
         session_ref: ref,
         vm: vm,
         composer: Composer.new(),
         # A `Transcript.position()`; nil follows the newest output.
         scroll: nil,
         # The size seam of `ExRatatui.Server`, so a test sets the size.
         terminal_size_fn: Keyword.get(opts, :terminal_size_fn, &ExRatatui.terminal_size/0)
       }}
    end

    # A dead session leaves nothing to render; exiting surfaces the reason
    # through run/1 instead of an idle screen that rejects every key. The
    # events before the signal are already applied.
    @impl true
    def handle_info({:DOWN, ref, :process, _pid, reason}, %{session_ref: ref}),
      do: exit({:session_down, Session.end_reason(reason)})

    def handle_info({:helyx_event, event}, state) do
      {:noreply, settle(%{state | vm: ViewModel.apply(state.vm, event)})}
    end

    def handle_info(_msg, state), do: {:noreply, state}

    # A session that is not running leaves nothing to render.
    defp subscribe!(session) do
      case Session.subscribe(session) do
        {:ok, snapshot, ref} -> {snapshot, ref}
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

    def handle_event(%Key{code: "esc", kind: "press"}, state) do
      # Abort waits for the hands to kill every OS process; a Task keeps that
      # wait off the render loop.
      session = state.session
      Task.start(fn -> Session.abort(session) end)
      {:noreply, state}
    end

    def handle_event(%Key{code: code, kind: kind, modifiers: []}, state)
        when code in ["page_up", "page_down"] and kind in ["press", "repeat"] do
      {:noreply, on_screen(state, &Transcript.page(state.vm, state.scroll, code, &1, &2))}
    end

    def handle_event(%Resize{}, state), do: {:noreply, settle(state)}

    def handle_event(%Key{code: "end", kind: "press", modifiers: ["ctrl"]}, state),
      do: {:noreply, %{state | scroll: nil}}

    # Ctrl+J is a new line in every terminal. Shift+Enter reaches here only
    # where the terminal reports Shift on Enter; elsewhere it is Enter.
    def handle_event(%Key{code: code, kind: kind, modifiers: modifiers}, state)
        when {code, modifiers} in [{"j", ["ctrl"]}, {"enter", ["shift"]}] and
               kind in ["press", "repeat"] do
      {:noreply, edit(state, :insert, "\n")}
    end

    def handle_event(%Key{code: "enter", kind: "press"} = key, state) do
      case Composer.submit(state.composer) do
        :empty -> {:noreply, state}
        # A notice is a new cell, so the position gets its check.
        {:model, ref} -> {:noreply, settle(switch_model(ref, state))}
        {:message, text} -> {:noreply, send_message(text, key, state)}
      end
    end

    # Only Ctrl+J and Shift+Enter add a line: the repeat and the release of
    # Enter do nothing.
    def handle_event(%Key{code: "enter"}, state), do: {:noreply, state}

    # Everything else goes to the composer, which inserts printable
    # characters and handles its own editing keys.
    def handle_event(%Key{} = key, state) do
      if key.kind in ["press", "repeat"] and key.modifiers -- ["shift"] == [] do
        {:noreply, edit(state, :key, key.code)}
      else
        {:noreply, state}
      end
    end

    def handle_event(%Paste{content: content}, state),
      do: {:noreply, edit(state, :paste, content)}

    def handle_event(_event, state), do: {:noreply, state}

    # An edit that changes the composer height changes the screen of the
    # transcript, so the position gets its check.
    defp edit(state, op, text) do
      rows = Composer.rows(state.composer)
      composer = Composer.edit(state.composer, op, text)
      state = %{state | composer: composer}
      if Composer.rows(composer) == rows, do: state, else: settle(state)
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
          %{state | composer: Composer.clear(state.composer), scroll: nil}

        # ExRatatui gives event text as a Rust `String`, so the composer
        # holds only valid UTF-8 and the session never answers `:invalid_utf8`.
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
          %{state | composer: Composer.clear(state.composer)}

        {:error, reason} ->
          %{state | vm: ViewModel.notice(state.vm, switch_error(reason))}
      end
    end

    # A notice shows at most the provider id, which the ref bounds cap.
    defp switch_error({:unknown_provider, id}), do: "unknown provider: #{id}"

    defp switch_error({:invalid_model_ref, _ref}), do: "invalid model ref: use provider/model"
    defp switch_error(:session_not_found), do: "the session ended"

    @impl true
    def render(state, frame) do
      area = %Rect{x: 0, y: 0, width: frame.width, height: frame.height}

      [transcript, composer, status] =
        Layout.split(area, :vertical, [
          {:min, 0},
          {:length, Composer.rows(state.composer, frame.height - @status_rows)},
          {:length, @status_rows}
        ])

      [
        {Transcript.widget(state.vm, state.scroll, transcript), transcript},
        {Composer.widget(state.composer), composer},
        {status_widget(state.vm, state.scroll), status}
      ]
    end

    # Scroll position

    # Sets the position from the width and the rows of the transcript. The
    # only reader of the terminal size. With no size there is no screen to
    # check a position against, so the view follows the newest output.
    defp on_screen(state, position) do
      case state.terminal_size_fn.() do
        {width, height} when is_integer(width) and is_integer(height) ->
          rows =
            max(height - Composer.rows(state.composer, height - @status_rows) - @status_rows, 1)

          %{state | scroll: position.(width, rows)}

        {:error, _reason} ->
          %{state | scroll: nil}
      end
    end

    # Applies `Transcript.hold/4` after a change that no scroll key makes: a
    # session event, a client notice, or a new size.
    defp settle(%{scroll: nil} = state), do: state

    defp settle(state),
      do: on_screen(state, &Transcript.hold(state.vm, state.scroll, &1, &2))

    # Status

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
