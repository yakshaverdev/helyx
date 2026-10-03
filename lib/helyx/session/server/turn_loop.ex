defmodule Helyx.Session.Server.TurnLoop do
  @moduledoc false
  # The turn lifecycle of a session: the transitions of `activity` and
  # `conn` in `Helyx.Session.Server.State` (docs/features/long-lived-harness.md,
  # "Turn states" and "Turn cleanup"). The turn starts, connects its
  # provider process, prepares its context, is submitted, and ends; the wait
  # after it lasts until the hands, the open reply, and the provider process
  # that ends are done. `Helyx.Session.Server` matches each message to the
  # current turn or provider process and calls one function here.

  require Logger

  import Helyx.Session.Server.State, only: [ask: 4, provider_pid: 1]
  import Helyx.Session.Server.Record, only: [emit: 3, emit: 4]

  alias Helyx.{Context, Message}
  alias Helyx.Session.{Hands, Id, ProviderProcess, ProviderRequest, Transcript, Turn}
  alias Helyx.Session.Server.{Messages, ProviderConn, State, Steering, Tools, Wait}

  # Starts a turn with one user message per text, in order.
  def begin_turn(%State{} = state, texts) do
    turn = %Turn{id: Id.new(), model: state.model, provider: state.provider}
    state = open_turn(state, turn, %{})
    call_provider(Enum.reduce(texts, state, &Messages.append_user(&2, &1)))
  end

  # A turn that the provider started by itself (#240): a submitted turn
  # with no user message.
  def program_turn(%State{conn: %ProviderConn{model: model}} = state, turn_id) do
    turn = %Turn{id: turn_id, model: model, provider: state.provider, phase: :submitted}
    open_turn(state, turn, %{origin: :provider})
  end

  defp open_turn(state, turn, data),
    do: %{state | activity: turn} |> emit(:agent_start, %{}) |> emit(:turn_start, data)

  # The provider process (started at the first turn) and the prepare Task,
  # which builds the context; a turn that connects again keeps its prepare.
  defp call_provider(%State{activity: %Turn{phase: phase}} = state) do
    case connect(state) do
      {:ok, state} -> if phase, do: state, else: prepare(put_in(state.activity.phase, :preparing))
      {:error, text} -> fail_turn(text, state)
    end
  end

  # Starts the provider process of the turn under the hands, with the
  # resume id of the transcript, and monitors it: its `:DOWN` outside a
  # turn drops it at once. A provider process of another model was closed
  # before the turn (`close_switched/1`).
  defp connect(%State{conn: %ProviderConn{model: model}, activity: %Turn{model: model}} = state),
    do: {:ok, state}

  defp connect(%State{conn: nil, activity: turn} = state) do
    resumed = Transcript.resumable(state.transcript, state.resume_ids, turn.model.provider)

    args = %{
      provider: turn.provider,
      model: turn.model.model,
      tools: state.tools,
      opts: [resume_id: resumed] ++ base_opts(state),
      session: self()
    }

    with {:ok, pid} <-
           Hands.start_provider(state.hands, turn.provider, ProviderProcess.run(args)) do
      Process.monitor(pid)
      conn = %ProviderConn{pid: pid, model: turn.model, turn: turn.id}
      {:ok, %{state | conn: conn, activity: %{turn | resumed: resumed}}}
    end
  end

  defp base_opts(state), do: [core: state.core, session_id: state.id, cwd: state.cwd]

  # The prepare Task builds the context, at the turn start and at each
  # context request. The session owns it: a child of the task supervisor,
  # monitored, its pid in `Turn.prepare`, killed at the turn end. Its kill
  # at `prepare_ms` is armed as its first act, before any plugin code.
  defp prepare(%State{activity: %Turn{id: turn_id}} = state) do
    session = self()
    %State{model_context: model_context, compaction: compaction, prepare_ms: ms} = state
    context = %Context{messages: state.transcript, tools: state.tools}
    opts = [turn_id: turn_id] ++ base_opts(state)

    {:ok, pid} =
      Task.Supervisor.start_child(Helyx.Core.task_supervisor(state.core), fn ->
        {:ok, tref} = :timer.kill_after(ms)
        result = Helyx.Session.Stream.prepare(model_context, compaction, context, opts)
        :timer.cancel(tref)
        send(session, {:prepared, turn_id, result})
      end)

    Process.monitor(pid)
    put_in(state.activity.prepare, pid)
  end

  # The checked context (`Stream.prepare/4`), or the error of the prepare
  # Task: a plugin that returned anything else, or a Task that died. In
  # `preparing` an error fails the turn; a context request gets it as the
  # answer.
  def prepared(%State{activity: %Turn{phase: :preparing} = turn} = state, result) do
    state = %{state | activity: %{turn | prepare: nil}}

    case result do
      {:ok, context} -> submit(put_in(state.activity.context, context))
      {:error, reason} -> fail_turn(reason, state)
    end
  end

  def prepared(%State{activity: %Turn{phase: :context} = turn, conn: conn} = state, result) do
    ask(state, conn.pid, {:context, turn.id, result}, :context)
    %{state | activity: %{turn | phase: :submitted, prepare: nil}}
  end

  # The prepare Task ended before its context: it raised, exited, or was
  # killed at its bound.
  def prepare_down(state, reason),
    do: prepared(state, {:error, {:task_exit, Message.cap_integers(reason)}})

  # A context request (C1-C4, `one-provider-path.md`): only for the
  # submitted turn with no context request open; at any other time it is a
  # bad action.
  def need_context(%State{activity: %Turn{phase: :submitted}} = state),
    do: prepare(put_in(state.activity.phase, :context))

  def need_context(%State{activity: turn} = state),
    do: stop_provider(state, {:bad_action, {:need_context, turn.id}})

  def provider_ready(state), do: arm_idle(submit(put_in(state.conn.ready, true)))

  # Sends `{:turn, ...}` when the provider process is ready and the context
  # is prepared. The steers queued in `preparing` join the transcript and
  # the end of the context: they are part of the prompt, not steers.
  defp submit(
         %State{
           activity: %Turn{phase: :preparing, context: context},
           conn: %ProviderConn{pid: pid, ready: true}
         } = state
       )
       when context != nil do
    {steers, %State{activity: turn} = state} = Steering.append_steers(state)
    context = %{context | messages: context.messages ++ Enum.map(steers, &Message.user/1)}
    from = ask(state, pid, {:turn, turn.id, context}, :turn)
    %{state | activity: %{turn | phase: :submitting, pending: from, context: nil}}
  end

  defp submit(state), do: state

  # An answer other than `:ok` ends the provider process, and its
  # `:provider_down` fails the turn.
  def turn_reply(%State{activity: turn} = state, reply) do
    phase = if reply == :ok, do: :submitted, else: :submitting
    state = %{state | activity: %{turn | pending: nil, phase: phase}}
    if reply == :ok, do: Steering.send_local_steers(state), else: state
  end

  # The answer to the interrupt or the idle close of the wait. The loop
  # ends itself after an answer that stops it (`ProviderRequest.stop_after/2`),
  # and the wait then lasts until its `:provider_down`.
  def wait_reply(%State{activity: wait} = state, kind, reply) do
    provider = if ProviderRequest.stop_after(kind, reply), do: wait.provider
    progress(%{state | activity: %{wait | reply: nil, provider: provider}})
  end

  # The idle timer fired: the wait holds every message until the answer.
  def idle_close(%State{conn: %ProviderConn{pid: pid}} = state) do
    from = ask(state, pid, :idle_close, :close)
    %{state | idle: nil, activity: %Wait{reply: from, provider: pid}}
  end

  # From the hands, after the release of the provider process's handles: the
  # end of the provider process that the wait is for, or of the current one.
  # In a turn it fails the turn, whose cleanup the hands then run after the
  # release. Only a process of an earlier turn that ends while this turn
  # prepares got nothing of it: the turn connects a new one, once.
  def provider_down(%State{activity: %Wait{}} = state, pid, _reason),
    do: wait_provider_down(state, pid)

  def provider_down(%State{activity: %Turn{} = turn, conn: conn} = state, _pid, reason) do
    if turn.phase == :preparing and conn.turn != turn.id,
      do: call_provider(Steering.provider_down(%{state | conn: nil})),
      else: fail_turn(reason, %{state | conn: nil})
  end

  # Idle, when it comes before the session's `:DOWN` (no order between them).
  def provider_down(%State{activity: :idle} = state, _pid, _reason),
    do: Steering.provider_down(%{state | conn: nil})

  # The session's monitor of the current provider process (#361). Outside a
  # turn the process is dropped at once, and the next turn waits for its
  # `:provider_down`. In a preparing turn it holds back `{:turn, ...}`
  # until then. In a sent turn its `:provider_down` fails the turn.
  def monitor_down(%State{activity: %Turn{phase: :preparing}} = state, _pid),
    do: put_in(state.conn.ready, false)

  def monitor_down(%State{activity: %Turn{}} = state, _pid), do: state

  def monitor_down(%State{activity: activity} = state, pid) do
    wait = if activity == :idle, do: %Wait{}, else: activity
    %{state | conn: nil, activity: %{wait | provider: pid}}
  end

  # A provider process ended in the wait, after its release: no request to
  # it is open any more. When the wait was for it, its reply ends too.
  defp wait_provider_down(%State{activity: wait} = state, pid) do
    conn = if provider_pid(state) == pid, do: nil, else: state.conn
    wait = if wait.provider == pid, do: %{wait | provider: nil, reply: nil}, else: wait
    progress(Steering.provider_down(%{state | conn: conn, activity: wait}))
  end

  # The answer of the hands to the cleanup request.
  def cleanup_done(%State{activity: wait} = state, result),
    do: progress(%{cleanup_notice(result, state) | activity: %{wait | hands: nil}})

  # The abort still replies `:ok` (ADR 0006 §5); a failed cleanup is a
  # notice with a fixed text; the log has the reason, whose handle list
  # has no bound. The turn has ended, so the notice has no turn id.
  defp cleanup_notice(:ok, state), do: state

  defp cleanup_notice({:error, reason}, state) do
    Logger.warning("abort cleanup failed: " <> reason)
    text = "abort cleanup failed: a process or resource of the turn may still be held"
    emit(state, nil, :notice, %{text: text})
  end

  # An abort in a wait drops the queues, like the abort that started the
  # wait, and its caller gets the reply at the end of the wait. A steer
  # that still waits for its answer gets its notice now: a late
  # `:rejected` must not queue it again after the abort.
  def abort(%State{activity: %Wait{} = wait} = state, from) do
    state = Steering.drop_queues(%{state | activity: %{wait | callers: [from | wait.callers]}})
    progress(Steering.abort(state))
  end

  def abort(%State{activity: %Turn{}} = state, from),
    do: close_turn(state, :aborted, :aborted, [from])

  # At the end of the wait the abort callers get their reply. An idle
  # session settles too: a late `:rejected` can queue a steer.
  def progress(%State{activity: %Wait{hands: nil, reply: nil, provider: nil} = wait} = state) do
    Enum.each(wait.callers, &GenServer.reply(&1, :ok))
    settle(%{state | activity: :idle})
  end

  def progress(%State{activity: :idle} = state), do: settle(state)
  def progress(state), do: state

  # With no turn and no wait, a provider process of another model than the
  # session's closes before the next turn starts (a provider or a model
  # switch); otherwise the queues start the next turn.
  def settle(%State{activity: :idle} = state) do
    with %State{activity: :idle} = state <- close_switched(state) do
      arm_idle(start_queued(state))
    end
  end

  def settle(state), do: state

  # A provider process of another model than the session's closes, and the
  # session waits for its end.
  defp close_switched(%State{model: model, conn: %ProviderConn{pid: pid, model: other}} = state)
       when other != model do
    ask(state, pid, :close, :close)
    %{state | conn: nil, activity: %Wait{provider: pid}}
  end

  defp close_switched(state), do: state

  # A normal turn end starts a new turn with everything still queued, steers
  # first. The drain event goes out between the turns, with a nil turn id.
  defp start_queued(%State{} = state) do
    case Steering.drain(state) do
      {[], state} -> state
      {texts, state} -> begin_turn(state, texts)
    end
  end

  # Arms the idle timer when the session holds a ready provider process
  # with no turn and no wait. It cancels the earlier timer; a message of
  # it that is already in the mailbox has an old ref.
  defp arm_idle(%State{activity: :idle, conn: %ProviderConn{ready: true}} = state) do
    if state.idle, do: :erlang.cancel_timer(state.idle)
    %{state | idle: :erlang.start_timer(state.provider_ms.idle, self(), :idle_close)}
  end

  defp arm_idle(state), do: state

  # The terminal of the turn, from the provider process.
  def end_turn({:done, %{stop_reason: stop_reason, usage: usage}}, state) do
    {%State{activity: turn} = state, assistant, _calls} =
      Messages.close_assistant(state, stop_reason, usage)

    kill_prepare(turn)

    # A call in the last message gets no result. A steer with no answer yet
    # can still be rejected after the turn (`Queue.answer/3`).
    state =
      state
      |> Messages.abort_open_calls()
      |> Steering.end_turn(turn.id, true)
      |> Tools.end_turn(turn)
      |> emit(:turn_end, %{message: assistant})
      |> emit(:agent_end, %{stop_reason: stop_reason})

    # A Helyx tool that still runs: the turn cleanup of the hands runs
    # before the next turn.
    hands = if turn.tools.running, do: Hands.request_cancel(state.hands, turn.id)
    progress(%{state | activity: %Wait{hands: hands}})
  end

  def end_turn({:error, reason}, state), do: fail_turn(reason, state)
  def end_turn(:stream_ended, state), do: fail_turn(:stream_ended, state)

  # A provider output outside the contract: the turn fails, and the
  # provider process stops with `{:shutdown, reason}`; the hands release it
  # and the wait lasts until its `:provider_down`.
  def stop_provider(%State{conn: %ProviderConn{pid: pid}} = state, reason) do
    Process.exit(pid, {:shutdown, reason})
    state = fail_turn(reason, %{state | conn: nil})
    put_in(state.activity.provider, pid)
  end

  def fail_turn(reason, state), do: close_turn(state, :error, reason, [])

  # An abort or a failure ends the turn at once: its prepare Task is
  # killed, and the hands release its Tasks before the next turn; the
  # `callers` get their reply when the wait ends. A partial assistant
  # message with a tool call joins the transcript
  # (`Messages.close_with_calls/1`), and its calls get `aborted`; one with
  # text only is closed with the stop reason so clients do not keep it
  # open, and is not added to the transcript. Only an abort of a turn that
  # sent `{:turn, ...}` gets an interrupt, after the `aborted` answers of
  # its open tool requests.
  defp close_turn(%State{activity: turn} = state, stop, reason, callers) do
    kill_prepare(turn)
    request = Hands.request_cancel(state.hands, turn.id)

    data =
      if stop == :aborted,
        do: %{stop_reason: :aborted},
        else: %{stop_reason: :error, error: reason}

    state =
      state
      |> Steering.end_turn(turn.id, false)
      |> Messages.close_with_calls()
      |> Messages.abort_open_calls()
      |> Messages.close_partial_message(stop, reason)
      |> Steering.drop_queues()
      |> Tools.end_turn(turn)
      |> emit(:agent_end, data)

    wait = if stop == :aborted, do: interrupt(state, turn), else: %Wait{}
    %{state | activity: %{wait | hands: request, callers: callers}}
  end

  # The wait holds the answer to the interrupt, and the provider process
  # until that answer keeps it.
  defp interrupt(%State{conn: %ProviderConn{pid: pid}} = state, %Turn{phase: phase, id: id})
       when phase in [:submitting, :submitted, :context],
       do: %Wait{reply: ask(state, pid, {:interrupt, id}, :interrupt), provider: pid}

  defp interrupt(_state, _turn), do: %Wait{}

  # Kills the prepare Task of the turn, if one runs. Its late
  # `{:prepared, ...}` and `:DOWN` match no turn and are dropped.
  def kill_prepare(%Turn{prepare: nil}), do: :ok
  def kill_prepare(%Turn{prepare: pid}), do: Process.exit(pid, :kill)
end
