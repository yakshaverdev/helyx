defmodule Helyx.Session.ProviderProcess do
  @moduledoc false
  # The Core loop of a provider process (ADR 0007): a long-lived Task of
  # the hands that runs the callbacks of a provider. The callbacks run only
  # here. The loop checks every action at the boundary, sends each event and
  # reply to the session, and ends itself on a bad action, a stop, or an
  # error answer to `{:turn, ...}` or `{:interrupt, ...}`. It never ends
  # with `:normal` (L1 in `docs/features/one-provider-path.md`), so every
  # process linked to it ends with it: it exits with `{:shutdown, reason}`,
  # and the hands report `reason` in `{:provider_down, pid, reason}`. Each
  # session request but `{:turn_dropped, ...}` has an armed kill (`ProviderRequest`).

  alias Helyx.Message
  alias Helyx.Session.{ProviderRequest, Stream}

  # The most requests without a reply (`docs/features/long-lived-harness.md`,
  # "Bounds"). One pool, no reserved slots: a turn waits for its `:ok`, an
  # interrupt, a close (only with no turn), and the open steers share it.
  # The steer queue holds 32 (`Helyx.Session.Queues`), so steers can fill
  # all 8; a request over the pool gets `{:error, :busy}`.
  @max_open 8
  # The Helyx tool requests of one turn: one runs, and at most 16 wait.
  @max_tools 17
  @too_many "too many Helyx tool calls: one runs and #{@max_tools - 1} wait"

  # The loop state: the provider and its state, the session, `open` (see
  # `loop/1`), and the Helyx tool requests (see "Helyx tool calls" below).
  @enforce_keys [:provider, :state, :session]
  defstruct [
    :provider,
    :state,
    :session,
    :live,
    :running,
    :started,
    # The live turn has a context request with no result (C3).
    context?: false,
    open: %{},
    calls: MapSet.new(),
    seen: MapSet.new(),
    waiting: []
  ]

  @type args :: %{
          provider: module(),
          model: String.t(),
          tools: [Helyx.Tool.spec()],
          opts: keyword(),
          session: pid()
        }

  @doc """
  The body of the provider process, as a fun of `tref`, the connect kill
  that the hands armed; it is cancelled after `init/3` returns, before
  `{:provider_ready, pid}` goes to the session. The fun never returns.
  """
  @spec run(args()) :: (:timer.tref() -> no_return())
  @dialyzer {:nowarn_function, run: 1}
  def run(args) do
    fn tref ->
      {:stop, reason} =
        try do
          start(args, tref)
        catch
          # A callback's `exit(:normal)` must not end the process normally (L1).
          :exit, :normal -> {:stop, {:exit, :normal}}
        end

      exit({:shutdown, reason})
    end
  end

  defp start(%{provider: provider, session: session} = args, tref) do
    case provider.init(args.model, args.tools, args.opts) do
      {:ok, state} ->
        :timer.cancel(tref)
        send(session, {:provider_ready, self()})
        loop(%__MODULE__{provider: provider, state: state, session: session})

      {:error, reason} ->
        {:stop, {:provider_init, reason}}

      other ->
        {:stop, {:bad_return, other}}
    end
  end

  # `open` holds the kind and the kill of each request without a reply, by
  # its `from`. The session can have a turn, its steers, its interrupt, and
  # a tool result open; over @max_open the loop answers `{:error, :busy}`
  # itself, and the provider never sees the request. A tool result or a
  # context is not limited: it is never open after its callback (see
  # `write_result/4`).
  defp loop(proc) do
    step =
      receive do
        # A guard with `elem/2` fails for `:close` and `:idle_close`.
        {:provider_request, from, tref, request}
        when elem(request, 0) in [:tool_result, :tool_start, :context, :turn_dropped] ->
          serve(request, from, tref, proc)

        {:provider_request, from, tref, request} when map_size(proc.open) >= @max_open ->
          kind = ProviderRequest.kind(request)
          ProviderRequest.answer(proc.session, from, tref, kind, {:error, :busy})
          ProviderRequest.stop_after(kind, {:error, :busy}) || {:ok, proc}

        {:provider_request, from, tref, request} ->
          serve(request, from, tref, proc)

        message ->
          case proc.provider.info(message, proc.state) do
            {:ok, actions, state} -> act(actions, %{proc | state: state})
            {:stop, reason, _state} -> {:stop, {:provider_stop, reason}}
            other -> {:stop, {:bad_return, other}}
          end
      end

    case step do
      {:ok, proc} -> loop(proc)
      done -> done
    end
  end

  # Helyx tool calls: the loop owns the rules, so a provider only maps its
  # program's requests to `{:tool_request, ...}` events and writes the
  # `{:tool_result, ...}` requests. The session gets one call at a time, and
  # an id that got any answer never runs later in the turn.
  # See `docs/features/long-lived-harness.md`, "Built in #203".
  defp serve({:turn, turn_id, _context} = request, from, tref, proc) do
    with {:ok, proc} <- end_tools(proc),
         do: provide(request, from, tref, %{proc | live: turn_id})
  end

  defp serve({:interrupt, turn_id} = request, from, tref, %{live: turn_id} = proc) do
    with {:ok, proc} <- end_tools(proc), do: provide(request, from, tref, proc)
  end

  defp serve({:tool_result, turn_id, call_id, _result} = request, from, tref, proc) do
    if proc.started == {turn_id, call_id} or open_call?(proc, turn_id, call_id) do
      calls = MapSet.delete(proc.calls, call_id)
      proc = %{proc | calls: calls, started: nil}

      with {:ok, proc} <- write_result(request, from, tref, proc),
           do: run_next(turn_id, call_id, proc)
    else
      ProviderRequest.answer(proc.session, from, tref, :tool_result, :ok)
      run_next(turn_id, call_id, proc)
    end
  end

  # The loop answers the ask itself and never waits for the session.
  defp serve({:tool_start, turn_id, call_id}, from, tref, proc) do
    if open_call?(proc, turn_id, call_id) and proc.running == call_id do
      ProviderRequest.answer(proc.session, from, tref, :tool_start, :ok)
      {:ok, %{proc | started: {turn_id, call_id}}}
    else
      ProviderRequest.answer(proc.session, from, tref, :tool_start, :dropped)
      run_next(turn_id, call_id, proc)
    end
  end

  # The context of the open request (C3); after its turn's interrupt or
  # terminal cleared the request, it is answered `:ok` here and dropped (C4).
  defp serve(
         {:context, turn_id, _} = request,
         from,
         tref,
         %{live: turn_id, context?: true} = proc
       ),
       do: write_result(request, from, tref, %{proc | context?: false})

  defp serve({:context, _, _}, from, tref, proc) do
    ProviderRequest.answer(proc.session, from, tref, :context, :ok)
    {:ok, proc}
  end

  # The session dropped this program turn (#339), with no reply: it ends as
  # at every end of a live turn, and an open context request gets an error.
  defp serve({:turn_dropped, turn_id}, _, _, %{live: turn_id, context?: true} = proc) do
    with {:ok, proc} <- end_tools(proc),
         do: write_result({:context, turn_id, {:error, :turn_dropped}}, make_ref(), nil, proc)
  end

  defp serve({:turn_dropped, turn_id}, _, _, proc), do: end_live_tools(turn_id, proc)

  defp serve(request, from, tref, proc), do: provide(request, from, tref, proc)

  # Gives a request to the provider. An internal request of the loop has no
  # kill (`tref` nil), and its reply does not go to the session.
  defp provide(request, from, tref, proc) do
    proc = %{proc | open: Map.put(proc.open, from, {ProviderRequest.kind(request), tref})}

    case proc.provider.request(request, from, proc.state) do
      {:ok, actions, state} -> act(actions, %{proc | state: state})
      other -> {:stop, {:bad_return, other}}
    end
  end

  defp end_live_tools(turn_id, %{live: turn_id} = proc), do: end_tools(proc)
  defp end_live_tools(_turn_id, proc), do: {:ok, proc}

  defp open_call?(proc, turn_id, call_id),
    do: proc.live == turn_id and MapSet.member?(proc.calls, call_id)

  # The result of the running call came: the next waiting call runs.
  defp run_next(turn_id, call_id, %{live: turn_id, running: call_id} = proc) do
    case proc.waiting do
      [] -> {:ok, %{proc | running: nil}}
      [event | waiting] -> run(event, %{proc | waiting: waiting})
    end
  end

  defp run_next(_turn_id, _call_id, proc), do: {:ok, proc}

  defp run({:tool_request, call_id, _, _} = event, proc) do
    proc = %{proc | running: call_id}
    sent(Stream.send_checked(proc.session, {:stream_event, proc.live, event}), proc)
  end

  # The live turn ends: each open tool request gets `aborted`, except a
  # started one, which only the result of its run answers.
  defp end_tools(%{live: turn_id, calls: calls} = proc) do
    proc = %{
      proc
      | live: nil,
        context?: false,
        running: nil,
        waiting: [],
        calls: MapSet.new(),
        seen: MapSet.new()
    }

    calls = Enum.reject(calls, &(proc.started == {turn_id, &1}))

    Enum.reduce_while(calls, {:ok, proc}, fn call_id, {:ok, proc} ->
      case answer_tool(turn_id, call_id, "aborted", proc) do
        {:ok, proc} -> {:cont, {:ok, proc}}
        done -> {:halt, done}
      end
    end)
  end

  # The loop's own answer has no armed kill (`tref` nil).
  defp answer_tool(turn_id, call_id, text, proc) do
    write_result({:tool_result, turn_id, call_id, {:error, text}}, make_ref(), nil, proc)
  end

  # The provider replies to every tool result and context inside its
  # callback, so it is written before the next request (the interrupt, the
  # next turn) reaches the provider. A reply that did not come stops the
  # provider process.
  defp write_result(request, from, tref, proc) do
    with {:ok, proc} <- provide(request, from, tref, proc) do
      if Map.has_key?(proc.open, from), do: {:stop, not_answered(request)}, else: {:ok, proc}
    end
  end

  defp not_answered({:tool_result, turn_id, call_id, _}),
    do: {:tool_result_not_answered, turn_id, call_id}

  defp not_answered({:context, turn_id, _}), do: {:context_not_answered, turn_id}

  # A request of the live turn puts its call id in `seen` before any check
  # that answers it, so an id that got any answer never runs later in the
  # turn.
  defp tool_request(
         turn_id,
         {:tool_request, call_id, _, _} = event,
         rejection,
         %{live: turn_id} = proc
       ) do
    seen? = MapSet.member?(proc.seen, call_id)
    proc = %{proc | seen: MapSet.put(proc.seen, call_id)}

    cond do
      MapSet.member?(proc.calls, call_id) ->
        {:stop, {:bad_action, {:event, turn_id, event}}}

      # An earlier answer, or the result of a withdrawn run, could answer it.
      seen? ->
        answer_tool(turn_id, call_id, "the call id was used before in this turn", proc)

      # An integer over the digit limit.
      rejection ->
        answer_tool(turn_id, call_id, Stream.not_run(rejection), proc)

      # A withdrawn running call still runs until its result comes.
      length(proc.waiting) + if(proc.running, do: 1, else: 0) >= @max_tools ->
        answer_tool(turn_id, call_id, @too_many, proc)

      true ->
        proc = %{proc | calls: MapSet.put(proc.calls, call_id)}

        if proc.running,
          do: {:ok, %{proc | waiting: proc.waiting ++ [event]}},
          else: run(event, proc)
    end
  end

  # A turn that is not live never becomes live again.
  defp tool_request(turn_id, {:tool_request, call_id, _, _}, _rejection, proc),
    do: answer_tool(turn_id, call_id, "aborted", proc)

  # An improper list stops at its tail, as a bad return.
  defp act([], proc), do: {:ok, proc}

  defp act([action | rest], proc) do
    case action(action, proc) do
      {:ok, proc} -> act(rest, proc)
      done -> done
    end
  end

  defp act(other, _proc), do: {:stop, {:bad_return, other}}

  # A turn that the program started by itself (#240) is live, as after a
  # `{:turn, ...}` request. Its id is the provider's, with the checks of a
  # resume id. During a live turn the loop drops it, as the session does (#319);
  # a session that drops it at another time ends it with `{:turn_dropped, id}` (#339).
  defp action({:event, turn_id, :turn_start} = action, proc) do
    message = {:stream_event, turn_id, :turn_start}

    cond do
      not Message.resume_id?(turn_id) -> {:stop, {:bad_action, action}}
      proc.live -> {:ok, proc}
      true -> sent(Stream.send_checked(proc.session, message), %{proc | live: turn_id})
    end
  end

  # An event passes the check of a provider event. A terminal goes to the
  # session as `{:stream_end, turn_id, terminal}`, with the integer cap. A malformed event
  # stops the loop: the program's turn is then in an unknown state.
  defp action({:event, turn_id, event}, proc) when is_binary(turn_id) do
    case Stream.check(event) do
      {:send, {:tool_request, _, _, _} = event, rejection} ->
        tool_request(turn_id, event, rejection, proc)

      {:send, event, _rejection} ->
        sent(Stream.send_checked(proc.session, {:stream_event, turn_id, event}), proc)

      {:terminal, terminal} ->
        message = {:stream_end, turn_id, Message.cap_integers(terminal)}

        with {:ok, proc} <- sent(Stream.send_checked(proc.session, message), proc),
             do: end_live_tools(turn_id, proc)

      {:bad, {:error, reason}} ->
        {:stop, reason}
    end
  end

  # A fresh context for the live turn (C2, C3), after the events before it.
  defp action({:need_context, turn_id} = action, %{live: turn_id, context?: false} = proc)
       when is_binary(turn_id),
       do: sent(Stream.send_checked(proc.session, action), %{proc | context?: true})

  defp action({:reply, from, value} = action, %{open: open} = proc)
       when is_map_key(open, from) do
    {{kind, tref}, open} = Map.pop!(open, from)

    if ProviderRequest.reply?(kind, value) do
      if tref, do: ProviderRequest.answer(proc.session, from, tref, kind, value)

      ProviderRequest.stop_after(kind, value) || {:ok, %{proc | open: open}}
    else
      {:stop, {:bad_action, action}}
    end
  end

  # The provider withdrew a tool request: the session stops the running
  # call, and a waiting one leaves the queue. A pair that is not open has
  # nothing to stop.
  defp action({:cancel_tool, turn_id, call_id} = action, proc)
       when is_binary(turn_id) and is_binary(call_id) do
    cond do
      # Also after the turn: the result of its killed run is then dropped.
      proc.started == {turn_id, call_id} ->
        proc = %{proc | calls: MapSet.delete(proc.calls, call_id), started: nil}
        sent(Stream.send_checked(proc.session, action), proc)

      not open_call?(proc, turn_id, call_id) ->
        {:ok, proc}

      # Not started: the ask gets `:dropped`, and the next call runs then.
      proc.running == call_id ->
        {:ok, %{proc | calls: MapSet.delete(proc.calls, call_id)}}

      true ->
        waiting = Enum.reject(proc.waiting, &match?({_, ^call_id, _, _}, &1))
        {:ok, %{proc | calls: MapSet.delete(proc.calls, call_id), waiting: waiting}}
    end
  end

  defp action(action, _proc), do: {:stop, {:bad_action, action}}

  defp sent(:ok, proc), do: {:ok, proc}
  defp sent({:error, reason}, _proc), do: {:stop, reason}
end
