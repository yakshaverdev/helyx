defmodule Helyx.Session.Server do
  @moduledoc false
  # The session process: the GenServer callbacks. The turn lifecycle is in
  # `Helyx.Session.Server.TurnLoop`; the client API is in `Helyx.Session`.

  alias Helyx.Reason
  alias Helyx.Session.{ApprovalChains, Turn}
  alias Helyx.Session.Server.{Approvals, Asks, Calls, Events, Flow, Open, Records}
  alias Helyx.Session.Server.Flow.Up
  alias Helyx.Session.Server.{Settle, Sources, State, Steering}
  alias Helyx.Session.Server.{Stop, Summary, ToolRuns, TurnLoop, UIBlocks, Wait}

  use GenServer, restart: :temporary, shutdown: Stop.shutdown_ms()

  defdelegate start(state, tools, open), to: Open
  defdelegate create(state, tools, open), to: Open

  def start_link({%State{id: id, core: core}, _start} = args) do
    GenServer.start_link(__MODULE__, args, name: via(core, id))
  end

  # Each callback runs in `Reason.no_args/1`, so a crash report shows no
  # state and no message (docs/features/session-lifecycle.md).
  @impl true
  def init(args), do: Reason.no_args(fn -> Open.init(args) end)

  @impl true
  def handle_continue(continue, state),
    do: Reason.no_args(fn -> Open.handle_continue(continue, state) end)

  # The calls of the client API, with their deadline (`Calls`).
  @impl true
  def handle_call(request, from, state),
    do: Reason.no_args(fn -> Calls.handle(request, from, state) end)

  @impl true
  def handle_info(message, state), do: Reason.no_args(fn -> info(message, state) end)

  @impl true
  def format_status(status), do: Reason.crash_status(status)

  # The summary call's messages come before every other clause, because its
  # turn is no longer the current one (`Summary.handle/2`).
  defp info(
         {:provider_ready, pid} = message,
         %State{summary_call: %Summary{pid: pid}} = state
       ),
       do: {:noreply, Summary.handle(message, state)}

  defp info({tag, id, _} = message, %State{summary_call: %Summary{id: id}} = state)
       when tag in [:stream_event, :stream_end, :need_context],
       do: {:noreply, Summary.handle(message, state)}

  defp info({:need_context, id} = message, %State{summary_call: %Summary{id: id}} = state),
    do: {:noreply, Summary.handle(message, state)}

  defp info(
         {:provider_down, pid, _} = message,
         %State{summary_call: %Summary{pid: pid}} = state
       ),
       do: {:noreply, Summary.handle(message, state)}

  defp info(
         {:tool_request, pid, _, _, _, _} = message,
         %State{summary_call: %Summary{pid: pid}} = state
       ),
       do: {:noreply, Summary.handle(message, state)}

  # A turn that the provider started by itself (#240) comes before the
  # events of the current turn.
  defp info({:stream_event, _turn_id, :turn_start} = message, state),
    do: {:noreply, TurnLoop.handle(message, state)}

  defp info({:stream_event, turn_id, event}, %State{phase: %{turn: %Turn{id: turn_id}}} = state),
    do: {:noreply, event(state, event)}

  # A Helyx tool request (`ToolRuns`). The call and its result join the
  # transcript from the provider's own events, not from here. A request of a
  # turn that is not current gets `aborted`.
  defp info(
         {:tool_request, _pid, turn_id, call, bytes, rejection},
         %State{phase: %{turn: %Turn{id: turn_id}}} = state
       ) do
    case ToolRuns.request(state, call, bytes, rejection) do
      {:ok, state} -> {:noreply, state}
      {:stop, reason} -> {:noreply, TurnLoop.stop_provider(state, reason)}
    end
  end

  defp info({:tool_request, pid, turn_id, call, _bytes, _rejection}, state),
    do: {:noreply, ToolRuns.late(state, pid, turn_id, call.id)}

  # An approval request for a call of the provider's own tools
  # (`Approvals`). One of a turn that is not current is denied.
  defp info(
         {:approval, _pid, turn_id, approval_id, call_id},
         %State{phase: %{turn: %Turn{id: turn_id}}} = state
       ) do
    case Approvals.request(state, approval_id, call_id) do
      {:ok, state} -> {:noreply, state}
      {:stop, reason} -> {:noreply, TurnLoop.stop_provider(state, reason)}
    end
  end

  defp info({:approval, pid, turn_id, approval_id, _call_id}, state),
    do: {:noreply, Approvals.late(state, pid, turn_id, approval_id)}

  # The decision of a running approval chain; one of a turn that ended is
  # dropped, because the turn's end denied its request.
  defp info(
         {:approval_result, turn_id, call_id, decision},
         %State{phase: %{turn: %Turn{id: turn_id, approval_chains: chains}}} = state
       ) do
    if ApprovalChains.running?(chains, call_id),
      do: {:noreply, Approvals.result(state, call_id, decision)},
      else: {:noreply, state}
  end

  defp info({:approval_result, _turn_id, _call_id, _decision}, state), do: {:noreply, state}

  # The live provider's resume id, for its turn or for the turn that the
  # wait ended (#518). Other pids and other turns record nothing.
  defp info(
         {:resume_id, pid, turn_id, id, cut},
         %State{phase: %{turn: %Turn{id: turn_id}, provider: %Up{pid: pid}}} = state
       ),
       do: {:noreply, Records.resume_id(state, turn_id, id, cut)}

  defp info(
         {:resume_id, pid, turn_id, id, cut},
         %State{phase: %Flow.Waiting{wait: %Wait{turn: turn_id}, provider: %Up{pid: pid}}} =
           state
       ),
       do: {:noreply, Records.resume_id(state, turn_id, id, cut)}

  defp info({:resume_id, _pid, _turn_id, _id, _cut}, state), do: {:noreply, state}

  # The hands' start answer of a background run: the run counts from here,
  # also when its call is no longer current. Its call Task leaves the turn,
  # then the run goes on (`Asks.started/3`).
  defp info({:tool_result, turn_id, call_id, {:started, result, pid}}, state),
    do:
      info(
        {:tool_result, turn_id, call_id, result},
        Asks.started(Steering.started(state), call_id, pid)
      )

  # The hands' result of a running Helyx tool.
  defp info(
         {:tool_result, turn_id, call_id, result},
         %State{phase: %{turn: %Turn{id: turn_id, tool_queue: %{running: running}}}} = state
       )
       when is_map_key(running, call_id),
       do: {:noreply, ToolRuns.result(state, call_id, result)}

  # The end of a background run (docs/features/background-bash.md): a steer
  # in a submitted turn, else it waits; an idle session starts a turn for it.
  defp info({:background_end, message}, state),
    do: {:noreply, state |> Steering.push_end(message) |> TurnLoop.settle()}

  # A message for a turn or a call that is no longer current.
  defp info({:tool_result, _turn_id, _call_id, _result}, state), do: {:noreply, state}
  defp info({:stream_event, _turn_id, _event}, state), do: {:noreply, state}

  # A call or hook Task that the hands started: the session stores its
  # record, then lets it run (`Asks.asker/4`).
  defp info({:asker, turn_id, pid, kind}, state),
    do: {:noreply, Asks.asker(state, turn_id, pid, kind)}

  # An answer of a hook (`Records.hook/3`). Its Task ended, so an ask that it
  # left open ends before the next hook of the chain can ask.
  defp info({:hook_answer, turn_id, record}, state),
    do: {:noreply, state |> Records.hook(turn_id, record) |> Asks.ended(record.pid)}

  # The answer of the `before_settle` chain of a wait (`Settle.answer/3`).
  defp info({:settle_answer, ref, answer}, state),
    do: {:noreply, Settle.answer(state, ref, answer)}

  # A source process that the hands started, and its end.
  defp info({:source, pid, plugin}, state), do: {:noreply, Sources.started(state, pid, plugin)}
  defp info({:source_down, pid}, state), do: {:noreply, Sources.down(state, pid)}

  # The timer of a caller of `Helyx.Tool.deferred/2` (`Sources.deferred/4`).
  defp info({:timeout, _timer, {:deferred, ref}}, state),
    do: {:noreply, Sources.timeout(state, ref)}

  # A notice of the sync worker of this instance.
  defp info({:memory_notice, pid, text}, %State{sync: pid} = state),
    do: {:noreply, Events.emit(state, nil, :notice, %{text: text})}

  # A failed subscribe, an ack, and the end of a subscriber: only the monitor
  # of its entry removes the entry.
  defp info({:unsubscribe, pid}, %State{} = state),
    do: {:noreply, Events.unsubscribe(state, pid)}

  defp info({:ack, pid, seq}, state), do: {:noreply, Events.ack(state, pid, seq)}

  defp info({:DOWN, ref, :process, pid, _reason}, %State{subscribers: subscribers} = state)
       when elem(:erlang.map_get(pid, subscribers), 0) == ref,
       do: {:noreply, Events.subscriber_down(state, pid)}

  # The end of a call or hook Task; any other `:DOWN` is a lifecycle input.
  defp info({:DOWN, ref, :process, pid, _reason} = message, state) do
    case Asks.down(state, ref, pid) do
      {:ok, state} -> {:noreply, state}
      :error -> {:noreply, TurnLoop.handle(message, state)}
    end
  end

  # An exit from a linked process is vital. A session that outlived its entry
  # in the sessions Registry would keep working where no client can reach it.
  defp info({:EXIT, _pid, reason}, state), do: {:stop, reason, state}

  # The lifecycle inputs (`TurnLoop.handle/2`). If the hands die, their
  # request's `:DOWN` is dropped and their `:EXIT` stops the session. Any
  # other message is a bug and crashes the session.
  defp info(message, state), do: {:noreply, TurnLoop.handle(message, state)}

  # The session stops only for a trapped reason; an untrappable kill takes
  # the hands with it. The hands end before the session (#219): their release
  # Tasks run under the task supervisor, which Core stops after the session.
  @impl true
  def terminate(_reason, state), do: Reason.no_args(fn -> stop(state) end)

  # A session with no hands ended in its open: it holds nothing.
  defp stop(%State{hands: nil}), do: :ok

  defp stop(state) do
    report = Stop.run(state)
    if state.stopper, do: GenServer.reply(state.stopper, report)
  end

  def via(core, id), do: {:via, Registry, {Helyx.Core.sessions_registry(core), id}}

  defp event(state, {:message_end, stop_reason, usage}),
    do: Records.end_assistant(state, stop_reason, usage)

  defp event(state, {:compaction, before, after_}), do: Records.compaction(state, before, after_)

  # A tool result event of the provider: it closes the open message and
  # joins its open call (`Records.tool_result/3`).
  defp event(state, {:tool_result, call_id, result}),
    do: Records.tool_result(state, call_id, result)

  # A UI block of the provider: a new key past the count stops the provider
  # process (`UIBlocks.provider_block/4`).
  defp event(state, {:ui_block, call_id, key, block}) do
    case UIBlocks.provider_block(state, call_id, key, block) do
      {:ok, state} -> state
      {:error, reason} -> TurnLoop.stop_provider(state, reason)
    end
  end

  # The provider took a steer of this turn: its text, checked at the client
  # call, joins the transcript here (`Queue.take/2`).
  defp event(state, {:user_message, steer_id}), do: Steering.take(state, steer_id)

  # An event that breaks the bound of the open message stops the provider
  # process (`Records.delta/2`).
  defp event(state, event) do
    case Records.delta(state, event) do
      {:ok, state} -> state
      {:error, reason, state} -> TurnLoop.stop_provider(state, reason)
    end
  end
end
