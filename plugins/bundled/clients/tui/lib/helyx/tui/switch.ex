defmodule Helyx.TUI.Switch do
  @moduledoc false
  # The session of the TUI: the bind to one session at mount, a switch
  # to another one for `/new` and `/resume`
  # (docs/features/tui-session-switch.md), and the bind again after a lost
  # connection (`reconnect/2`, docs/features/tui-attach.md, decision 11).
  # A Task opens the new session, then aborts the old one, so its turn is
  # saved, and stops it, over the wire (`Helyx.TUI.Link`).
  # The new session opens first, so a failed open leaves the old one as it
  # was. The functions take and give the state of `Helyx.TUI`.

  alias Helyx.Event
  alias Helyx.TUI.{Composer, Link, Question, ViewModel}
  require Link

  @enforce_keys [:task, :target]
  defstruct [:task, :target, down: nil, dropped: []]

  @type target :: :new | {:resume, String.t()}

  # `down` is `{:down, reason}` when the end signal of the old session came
  # during the switch, `reason` that of its `session_end`.
  @type down :: {:down, :stopped | :crashed} | nil
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
  @spec bind(map(), Link.t(), String.t() | nil) :: map()
  def bind(state, session, info) do
    {snapshot, ref} = subscribe!(session, [])
    show(state, session, snapshot, ref, info)
  end

  # `question` is the picker to keep when the snapshot holds its ask
  # (`Question.sync/1`): a reconnect keeps the answers so far, the
  # position, and the text of the Other line. A switch keeps none.
  defp show(state, session, snapshot, ref, info, question \\ nil) do
    # The Ctrl+O toggle belongs to the client, so a switch keeps it.
    vm = ViewModel.from_snapshot(snapshot, session.id)
    vm = %{vm | expanded?: match?(%{expanded?: true}, state.vm)}

    Question.sync(%{
      state
      | session: session,
        # The sub of the subscribe: its `session_end` is the end signal.
        session_ref: ref,
        # An event of another instance is of a session that a switch left.
        instance_id: snapshot.instance_id,
        vm: if(info, do: ViewModel.info(vm, info), else: vm),
        busy: busy(snapshot.turn),
        scroll: nil,
        selection: nil,
        # The cursor of a search is an item of the session it leaves.
        search: nil,
        question: question
    })
  end

  # A session that is not running leaves nothing to render, nor does a
  # subscribe that the wire refused. A subscribe with no `after` gets a
  # snapshot.
  defp subscribe!(session, opts) do
    case Link.subscribe(session, opts) do
      {:ok, snapshot, ref} -> {snapshot, ref}
      {:error, :session_not_found} -> exit({:session_down, :session_not_found})
      {:error, reason} when Link.wire_error?(reason) -> exit({:connection_down, reason})
    end
  end

  # The end of the connection over the wire. A lost one, a close of the
  # server or of TCP, connects again with the `reconnect` function of the
  # TUI, in its process, and subscribes with `after`: the instance and the
  # seq of the last event that the fold applied. A replay gives the events
  # that the TUI missed, which it applies as live ones; a snapshot
  # replaces its state, as at a switch, but for the picker of an ask that
  # is still open. A contract break, a lost connection during a switch,
  # and a failed reconnect end the TUI.
  @spec reconnect(map(), term()) :: map()
  def reconnect(%{switch: nil, reconnect: reconnect} = state, {:shutdown, {:closed, _}})
      when is_function(reconnect, 0) do
    case reconnect.() do
      {:ok, socket} -> resubscribe(state, Link.reopen(state.session, socket))
      {:error, text} -> exit({:connection_down, {:reconnect, text}})
    end
  end

  def reconnect(_state, reason), do: exit({:connection_down, reason})

  defp resubscribe(state, session) do
    case subscribe!(session, after: %{instance_id: state.instance_id, seq: state.vm.seq}) do
      {{:replay, events}, sub} ->
        state = %{state | session: session, session_ref: sub}
        state = Enum.reduce(events, state, &apply_event(&2, &1))

        %{state | vm: ViewModel.info(state.vm, "reconnected")}

      {snapshot, sub} ->
        show(state, session, snapshot, sub, "reconnected", state.question)
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
    opts = %{model: state.vm.model, cwd: state.cwd}
    old = state.session
    task = Task.async(fn -> run(target, old, opts) end)
    %{state | switch: %__MODULE__{task: task, target: target, down: down}}
  end

  # A refused stop of the wire fails the switch: the TUI stays on the old
  # session, whose events it acks, and the new one runs on in the server.
  defp run(target, old, opts) do
    with {:ok, new} <- Link.open(old, target, opts),
         :ok <- Link.stop(old),
         do: {:ok, new}
  end

  # The end signal of the session, the reason of its `session_end`. A dead
  # session leaves nothing to render: the exit surfaces the reason through
  # `Helyx.TUI.run/1`. During a switch, the result of the switch decides.
  @spec down(map(), :stopped | :crashed) :: map()
  def down(%{switch: nil}, reason), do: exit({:session_down, reason})
  def down(state, reason), do: put_in(state.switch.down, {:down, reason})

  # An event of the current session, live or of a replay: the ack, the
  # fold, the question of an ask, and the composer. An event at or below
  # the seq of the fold changes nothing (decision 11).
  @spec apply_event(map(), Event.t()) :: map()
  def apply_event(%{vm: %{seq: last}} = state, %Event{seq: seq}) when seq <= last, do: state

  def apply_event(state, event) do
    :ok = Link.ack(state.session, state.session_ref, event)
    event(Question.sync(%{state | vm: ViewModel.apply(state.vm, event)}), event)
  end

  # An event of the current session for the composer. During a switch the
  # composer takes the texts of a `queue_dropped` only when the switch
  # fails; after a switch they go with the old session.
  defp event(%{switch: nil} = state, event),
    do: update_in(state.composer, &Composer.apply(&1, event))

  defp event(state, %Event{type: :queue_dropped} = event),
    do: update_in(state.switch.dropped, &[event | &1])

  defp event(state, _event), do: state

  # The answer of the Task. A failed open keeps the current session while
  # it runs; when it ended during the switch, a new session takes its
  # place, and when that fails too the TUI ends.
  @spec done(map(), {:ok, Link.t()} | {:error, term()}) :: map()
  def done(%{switch: switch} = state, {:ok, session}) do
    # The old session ended in the Task; the TUI drops the `session_end` of
    # a sub that is not its own.
    info = if switch.target == :new, do: "new session", else: "resumed session"
    state = bind(%{state | switch: nil}, session, info)
    %{state | composer: Composer.end_recall(state.composer)}
  end

  # A crash of the Task is a failed open too. When the old session ends
  # during a switch that fails, the answer can come before its
  # `session_end`, from another process: no call tells a dead session
  # apart, and the `session_end` that comes later ends the TUI
  # (docs/features/tui-attach.md, Accepted holes).
  def done(%{switch: switch} = state, {:error, reason}),
    do: failed(%{state | vm: ViewModel.info(state.vm, text(reason))}, switch.target, switch.down)

  defp failed(state, _target, nil), do: give_back(state)

  defp failed(_state, :new, {:down, reason}), do: exit({:session_down, reason})

  # The old session is gone: its end signal stays with the new switch, and
  # its queue comes back, because the composer stays with the TUI.
  defp failed(state, _target, down), do: start(give_back(state), :new, down)

  # The texts of the kept `queue_dropped` events go to the composer in
  # their order, as outside a switch.
  defp give_back(%{switch: switch} = state),
    do: switch.dropped |> Enum.reverse() |> Enum.reduce(%{state | switch: nil}, &event(&2, &1))

  defp text(reason), do: "could not switch: " <> reason(reason)

  # A fixed text for each known reason of Core or of the wire, and one for
  # any other, so the notice holds no term (the review of #807).
  defp reason(reason) when Link.wire_error?(reason), do: Link.error_text(reason)
  defp reason(:too_many_sessions), do: "too many sessions on the server"
  defp reason(:not_found), do: "no saved session with this id"
  defp reason({:start_failed, _text}), do: "the server could not open the session"
  defp reason({:unknown_provider, _id}), do: "the model has an unknown provider"
  defp reason({:invalid_model_ref, _ref}), do: "the model ref is not valid"
  defp reason(_other), do: "the session did not open"
end
