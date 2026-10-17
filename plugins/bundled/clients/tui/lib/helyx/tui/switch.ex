defmodule Helyx.TUI.Switch do
  @moduledoc false
  # The session of the TUI: the bind to one session at mount, and a switch
  # to another one for `/new` and `/resume`
  # (docs/features/tui-session-switch.md). A Task opens the new session,
  # then aborts the old one, so its turn is saved, and stops it. The new
  # session opens first, so a failed open leaves the old one as it was.
  # The functions take and give the state of `Helyx.TUI`.

  alias Helyx.{Event, Session}
  alias Helyx.TUI.{Composer, ViewModel}

  @enforce_keys [:task, :target]
  defstruct [:task, :target, down: nil, dropped: []]

  @type target :: :new | {:resume, String.t()}

  # `down` is `{:down, reason}` when the end signal of the old session came
  # during the switch. The tag keeps a `nil` or `false` reason apart from
  # no signal.
  @type down :: {:down, term()} | nil
  # `dropped` is the `queue_dropped` events of the switch, newest first.
  @type t :: %__MODULE__{
          task: Task.t(),
          target: target(),
          down: down(),
          dropped: [Event.t()]
        }

  # Subscribes to `session` and shows it from its snapshot: the history of
  # a resumed session, and the turn a late client joins, then the
  # information cell `info` when it is not nil. The end signal of the
  # subscription ends the TUI (`down/2`).
  @spec bind(map(), Session.t(), String.t() | nil) :: map()
  def bind(state, session, info) do
    {snapshot, ref} = subscribe!(session)
    vm = ViewModel.from_snapshot(snapshot)

    %{
      state
      | session: session,
        # The monitor of the session from the subscribe: its `:DOWN` is
        # the end signal.
        session_ref: ref,
        # An event of another instance is of a session that a switch left.
        instance_id: snapshot.instance_id,
        vm: if(info, do: ViewModel.info(vm, info), else: vm),
        busy: busy(snapshot.turn),
        scroll: nil,
        selection: nil
    }
  end

  # A session that is not running leaves nothing to render.
  defp subscribe!(session) do
    case Session.subscribe(session) do
      {:ok, snapshot, ref} -> {snapshot, ref}
      {:error, :session_not_found} -> exit({:session_down, :session_not_found})
    end
  end

  # A client that joins a running turn takes its start from the snapshot,
  # which the session makes, so every client shows the same time.
  defp busy(nil), do: nil

  defp busy(%{elapsed_ms: elapsed}),
    do: %{started: System.monotonic_time(:millisecond) - elapsed, elapsed: elapsed}

  # Starts a switch: the Task opens `target` in the folder of the TUI, with
  # the current model for `/new`.
  @spec start(map(), target(), down()) :: map()
  def start(state, target, down \\ nil) do
    opts = %{model: state.vm.model, cwd: state.cwd, sessions_dir: state.sessions_dir}
    old = state.session
    task = Task.async(fn -> run(target, old, opts) end)
    %{state | switch: %__MODULE__{task: task, target: target, down: down}}
  end

  defp run(target, old, opts) do
    with {:ok, new} <- open(target, old.core, opts) do
      _ = Session.abort(old)
      stop(old)
      {:ok, new}
    end
  end

  defp open(:new, core, opts),
    do: Session.start(core, model: opts.model, cwd: opts.cwd, sessions_dir: opts.sessions_dir)

  defp open({:resume, id}, core, opts),
    do: Session.resume(core, sessions_dir: opts.sessions_dir, cwd: opts.cwd, id: id)

  # Core has no stop function: the session's `terminate/2` runs its stop,
  # whose waits `Helyx.Session.Server.Stop` bounds. A session that ends
  # first exits the call; it is stopped either way.
  defp stop(session) do
    case Session.pid(session) do
      nil -> :ok
      pid -> GenServer.stop(pid, :shutdown, :infinity)
    end
  catch
    :exit, _reason -> :ok
  end

  # The end signal of the session. A dead session leaves nothing to
  # render: the exit surfaces the reason through `Helyx.TUI.run/1`. During
  # a switch, the result of the switch decides.
  @spec down(map(), term()) :: map()
  def down(%{switch: nil}, reason), do: exit({:session_down, Session.end_reason(reason)})
  def down(state, reason), do: put_in(state.switch.down, {:down, reason})

  # An event of the current session for the composer. During a switch the
  # composer takes the texts of a `queue_dropped` only when the switch
  # fails; after a switch they go with the old session.
  @spec event(map(), Event.t()) :: map()
  def event(%{switch: nil} = state, event),
    do: update_in(state.composer, &Composer.apply(&1, event))

  def event(state, %Event{type: :queue_dropped} = event),
    do: update_in(state.switch.dropped, &[event | &1])

  def event(state, _event), do: state

  # The answer of the Task. A failed open keeps the current session while
  # it runs; when it ended during the switch, a new session takes its
  # place, and when that fails too the TUI ends.
  @spec done(map(), {:ok, Session.t()} | {:error, term()}) :: map()
  def done(%{switch: switch} = state, {:ok, session}) do
    # The old session ended in the Task, so its end signal goes.
    Process.demonitor(state.session_ref, [:flush])
    info = if switch.target == :new, do: "new session", else: "resumed session"
    state = bind(%{state | switch: nil}, session, info)
    %{state | composer: Composer.end_recall(state.composer)}
  end

  # A crash of the Task is a failed open too. The end signal of a session
  # that died can come after the answer: the monitor makes it certain, so
  # the TUI waits for it.
  def done(%{switch: switch} = state, {:error, reason}) do
    down = switch.down || ended(state)
    failed(%{state | vm: ViewModel.info(state.vm, text(reason))}, switch.target, down)
  end

  defp failed(state, _target, nil), do: give_back(state)

  defp failed(_state, :new, {:down, reason}),
    do: exit({:session_down, Session.end_reason(reason)})

  # The old session is gone: its end signal stays with the new switch, and
  # its queue comes back, because the composer stays with the TUI.
  defp failed(state, _target, down), do: start(give_back(state), :new, down)

  # The texts of the kept `queue_dropped` events go to the composer in
  # their order, as outside a switch.
  defp give_back(%{switch: switch} = state),
    do: switch.dropped |> Enum.reverse() |> Enum.reduce(%{state | switch: nil}, &event(&2, &1))

  # `Session.pid/1` gives nil only for a dead session (the Registry checks
  # the pid), and the `:DOWN` of a dead monitored process is on its way.
  defp ended(%{session: session, session_ref: ref}) do
    if Session.pid(session) do
      nil
    else
      receive do
        {:DOWN, ^ref, :process, _pid, reason} -> {:down, reason}
      end
    end
  end

  defp text({:session_locked, id}),
    do: "could not switch: session #{id} is open in another process"

  defp text(reason), do: "could not switch: " <> Helyx.Reason.text(reason)
end
