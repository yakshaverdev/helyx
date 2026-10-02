defmodule Helyx.Session.ProviderProcess do
  @moduledoc false
  # The Core loop of a provider process (ADR 0007,
  # `docs/features/long-lived-harness.md`): a long-lived Task of the hands
  # that runs the callbacks of a connected provider. The callbacks run only
  # here. The loop checks every action at the boundary, sends each event and
  # reply to the session, and ends itself on a bad action, a stop, or an
  # error answer to `{:turn, ...}` or `{:interrupt, ...}`. Its return value
  # is the reason the hands report in `{:provider_down, pid, reason}`.
  #
  # Every request comes with a kill of this process armed at the OTP timer
  # server (`request/3`). The loop cancels the kill when the provider
  # replies, and sends the reply after the cancel. A callback that blocks
  # also blocks the cancel, so a blocked loop is always killed at the bound,
  # whatever the session and the hands do. The timer can fire during the
  # cancel, so a reply can still be followed by the kill; the session takes
  # the `:provider_down` as the last word.

  alias Helyx.Message
  alias Helyx.Session.Stream

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
  Sends a request to the provider process `pid` with a kill armed at
  `ms`, and returns the `from` ref of its reply, `{:provider_reply, from,
  kind, value}` to the caller. `kind` is the first element of the request
  (`:turn`, `:steer`, `:tool_start`, ...), or the request itself for
  `:close` and `:idle_close`.
  """
  @spec request(
          pid(),
          Helyx.Provider.request() | {:tool_start, String.t(), String.t()},
          pos_integer()
        ) ::
          reference()
  def request(pid, request, ms) do
    {:ok, tref} = :timer.kill_after(ms, pid)
    from = make_ref()
    send(pid, {:provider_request, from, tref, request})
    from
  end

  @doc """
  The body of the provider process. `tref` is the connect kill that the
  hands armed; it is cancelled after `init/3` returns, before
  `{:provider_ready, pid}` goes to the session.
  """
  @spec run(args(), :timer.tref()) :: :closed | {:stop, term()}
  def run(%{provider: provider, session: session} = args, tref) do
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
  # itself, and the provider never sees the request. A tool result is not
  # limited: it is never open after its callback (see `write_result/4`).
  defp loop(proc) do
    step =
      receive do
        {:provider_request, from, tref, {:tool_result, _, _, _} = request} ->
          serve(request, from, tref, proc)

        {:provider_request, from, tref, {:tool_start, _, _} = request} ->
          serve(request, from, tref, proc)

        {:provider_request, from, tref, request} when map_size(proc.open) >= @max_open ->
          :timer.cancel(tref)
          kind = kind(request)
          send(proc.session, {:provider_reply, from, kind, {:error, :busy}})
          replied(kind, {:error, :busy}, proc)

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

  # Helyx tool calls (`docs/features/long-lived-harness.md`, "Helyx tool
  # calls"). The loop owns the rules, so each connected provider only maps
  # its program's requests to `{:tool_request, ...}` events and writes the
  # `{:tool_result, ...}` requests. A turn is `live` from its `{:turn, ...}`
  # request until its terminal or its interrupt; `calls` holds the call ids
  # of the live turn's tool requests with no result, and `seen` every call
  # id the live turn used, so an id that got any answer (a result, a
  # withdraw, an error of the loop) never runs later in the turn. A pair
  # `{turn_id, call_id}` is open when the turn is live and the id is in
  # `calls`.
  #
  # The loop owns the queue: the session gets only the call that runs,
  # `running`, and the next of `waiting` (its events, in order) goes to
  # the session only when the running call's result came. The session asks
  # `{:tool_start, ...}` before it runs the call, and the loop answers `:ok`
  # only for the open running call, and keeps its pair in `started`. So a
  # call that got any answer never starts. After the `:ok`, only the result
  # of the run answers the call: `end_tools` skips it, and the session sends
  # the result of its killed run after the hands' cleanup, also after the
  # turn. The skip acts at the terminal; at the interrupt and the next turn
  # that result came first, so `started` is nil there, and the one
  # `end_tools` serves all three ends. A call withdrawn before the ask
  # gets `:dropped` at the ask; a started one stays `running` until the
  # result of its killed run comes, which is dropped.
  #
  # The loop answers a tool request itself, with an error result through the
  # provider, when its turn is not live, when its id was used, and when
  # @max_tools are open. At the terminal, the interrupt, and the next turn, every open
  # request of the turn gets the error result `aborted` before the provider
  # sees the interrupt. A result whose pair is not open (a late result of
  # an ended turn, or of a call that the provider withdrew) is answered `:ok`
  # here and dropped, so it never answers a call of a later turn.
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
      :timer.cancel(tref)
      send(proc.session, {:provider_reply, from, :tool_result, :ok})
      run_next(turn_id, call_id, proc)
    end
  end

  # The loop answers the ask itself and never waits for the session.
  defp serve({:tool_start, turn_id, call_id}, from, tref, proc) do
    :timer.cancel(tref)

    if open_call?(proc, turn_id, call_id) and proc.running == call_id do
      send(proc.session, {:provider_reply, from, :tool_start, :ok})
      {:ok, %{proc | started: {turn_id, call_id}}}
    else
      send(proc.session, {:provider_reply, from, :tool_start, :dropped})
      run_next(turn_id, call_id, proc)
    end
  end

  defp serve(request, from, tref, proc), do: provide(request, from, tref, proc)

  # Gives a request to the provider. An internal request of the loop has no
  # kill (`tref` nil), and its reply does not go to the session.
  defp provide(request, from, tref, proc) do
    proc = %{proc | open: Map.put(proc.open, from, {kind(request), tref})}

    case proc.provider.request(request, from, proc.state) do
      {:ok, actions, state} -> act(actions, %{proc | state: state})
      other -> {:stop, {:bad_return, other}}
    end
  end

  # The terminal of the live turn ends its tools.
  defp end_live_tools(turn_id, %{live: turn_id} = proc), do: end_tools(proc)
  defp end_live_tools(_turn_id, proc), do: {:ok, proc}

  defp open_call?(proc, turn_id, call_id),
    do: proc.live == turn_id and MapSet.member?(proc.calls, call_id)

  # The result of the running call came: the next waiting call runs.
  defp run_next(turn_id, call_id, %{live: turn_id, running: call_id} = proc) do
    case proc.waiting do
      [] -> {:ok, %{proc | running: nil}}
      [{event, rejection} | waiting] -> run(event, rejection, %{proc | waiting: waiting})
    end
  end

  defp run_next(_turn_id, _call_id, proc), do: {:ok, proc}

  defp run({:tool_request, call_id, _, _} = event, rejection, proc) do
    proc = %{proc | running: call_id}
    sent(Stream.send_event(proc.session, proc.live, event, rejection), proc)
  end

  # The live turn ends: each open tool request gets `aborted`, except a
  # started one, which only the result of its run answers.
  defp end_tools(%{live: turn_id, calls: calls} = proc) do
    proc = %{
      proc
      | live: nil,
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

  # The provider replies to every tool result inside its callback, so the
  # result is written before the next request (the interrupt, the next
  # turn) reaches the provider. A reply that did not come stops the provider
  # process.
  defp write_result({:tool_result, turn_id, call_id, _result} = request, from, tref, proc) do
    with {:ok, proc} <- provide(request, from, tref, proc) do
      if Map.has_key?(proc.open, from),
        do: {:stop, {:tool_result_not_answered, turn_id, call_id}},
        else: {:ok, proc}
    end
  end

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

      # A withdrawn running call still runs until its result comes.
      length(proc.waiting) + if(proc.running, do: 1, else: 0) >= @max_tools ->
        answer_tool(turn_id, call_id, @too_many, proc)

      true ->
        proc = %{proc | calls: MapSet.put(proc.calls, call_id)}

        if proc.running,
          do: {:ok, %{proc | waiting: proc.waiting ++ [{event, rejection}]}},
          else: run(event, rejection, proc)
    end
  end

  # A turn that is not live never becomes live again.
  defp tool_request(turn_id, {:tool_request, call_id, _, _}, _rejection, proc),
    do: answer_tool(turn_id, call_id, "aborted", proc)

  defp kind({kind, _turn_id, _id, _value}) when kind in [:steer, :tool_result], do: kind
  defp kind({kind, _turn_id, _context}), do: kind
  defp kind({kind, _turn_id}), do: kind
  defp kind(close) when close in [:close, :idle_close], do: close

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
  # resume id.
  defp action({:event, turn_id, :turn_start} = action, proc) do
    if Message.resume_id?(turn_id) do
      with {:ok, proc} <- end_tools(proc) do
        message = {:stream_event, turn_id, :turn_start}
        sent(Stream.send_checked(proc.session, message), %{proc | live: turn_id})
      end
    else
      {:stop, {:bad_action, action}}
    end
  end

  # An event passes the check of a stream event of a connected turn. A
  # terminal goes to the session as `{:stream_end, turn_id, terminal}`, with
  # the cap that a stream Task applies to its terminal. A malformed event
  # stops the loop: the program's turn is then in an unknown state.
  defp action({:event, turn_id, event}, proc) when is_binary(turn_id) do
    case Stream.check(event, true) do
      {:send, {:tool_request, _, _, _} = event, rejection} ->
        tool_request(turn_id, event, rejection, proc)

      {:send, event, rejection} ->
        sent(Stream.send_event(proc.session, turn_id, event, rejection), proc)

      {:terminal, terminal} ->
        message = {:stream_end, turn_id, Message.cap_integers(terminal)}

        with {:ok, proc} <- sent(Stream.send_checked(proc.session, message), proc),
             do: end_live_tools(turn_id, proc)

      {:bad, {:error, reason}} ->
        {:stop, reason}
    end
  end

  defp action({:reply, from, value} = action, %{open: open} = proc)
       when is_map_key(open, from) do
    {{kind, tref}, open} = Map.pop!(open, from)

    if reply?(kind, value) do
      if tref do
        :timer.cancel(tref)
        send(proc.session, {:provider_reply, from, kind, value})
      end

      replied(kind, value, %{proc | open: open})
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
        waiting = Enum.reject(proc.waiting, &match?({{_, ^call_id, _, _}, _}, &1))
        {:ok, %{proc | calls: MapSet.delete(proc.calls, call_id), waiting: waiting}}
    end
  end

  defp action(action, _proc), do: {:stop, {:bad_action, action}}

  defp reply?(_kind, :ok), do: true
  defp reply?(:idle_close, :busy), do: true
  defp reply?(:steer, :rejected), do: true
  defp reply?(kind, {:error, _reason}) when kind in [:turn, :interrupt, :steer], do: true
  defp reply?(_kind, _value), do: false

  # After an error answer to a turn or an interrupt Helyx does not know the
  # state of the program, so the loop ends: the port closes, and the
  # watchdog stops the program with no end of input. An error answer to a
  # steer leaves only that steer unknown, so the loop goes on. An idle
  # close with `:ok` exited as a close; with `:busy` the program stays.
  defp replied(kind, :ok, _proc) when kind in [:close, :idle_close], do: :closed

  defp replied(kind, {:error, reason}, _proc) when kind != :steer,
    do: {:stop, {:provider_error, kind, reason}}

  defp replied(_kind, _answer, proc), do: {:ok, proc}

  defp sent(:ok, proc), do: {:ok, proc}
  defp sent({:error, reason}, _proc), do: {:stop, reason}
end
