defmodule Helyx.Session.Harness do
  @moduledoc false
  # The Core loop of a harness process (ADR 0007,
  # `docs/features/long-lived-harness.md`): a long-lived Task of the hands
  # that runs the callbacks of a connected provider. The callbacks run only
  # here. The loop checks every action at the boundary, sends each event and
  # reply to the session, and ends itself on a bad action, a stop, or an
  # error answer to `{:turn, ...}` or `{:interrupt, ...}`. Its return value
  # is the reason the hands report in `{:harness_down, pid, reason}`.
  #
  # Every request comes with a kill of this process armed at the OTP timer
  # server (`request/3`). The loop cancels the kill when the provider
  # replies, and sends the reply after the cancel. A callback that blocks
  # also blocks the cancel, so a blocked loop is always killed at the bound,
  # whatever the session and the hands do. The timer can fire during the
  # cancel, so a reply can still be followed by the kill; the session takes
  # the `:harness_down` as the last word.

  alias Helyx.Message
  alias Helyx.Session.Stream

  # The most requests without a reply (`docs/features/long-lived-harness.md`,
  # "Bounds").
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
  Sends a request to the harness process `pid` with a kill armed at
  `ms`, and returns the `from` ref of its reply, `{:harness_reply, from,
  value}` to the caller.
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
    send(pid, {:harness_request, from, tref, request})
    from
  end

  @doc """
  The body of the harness process. `tref` is the connect kill that the
  hands armed; it is cancelled after `harness_init/3` returns, before
  `{:harness_ready, pid}` goes to the session.
  """
  @spec run(args(), :timer.tref()) :: :closed | {:stop, term()}
  def run(%{provider: provider, session: session} = args, tref) do
    case provider.harness_init(args.model, args.tools, args.opts) do
      {:ok, state} ->
        :timer.cancel(tref)
        send(session, {:harness_ready, self()})
        loop(%__MODULE__{provider: provider, state: state, session: session})

      {:error, reason} ->
        {:stop, {:harness_init, reason}}

      other ->
        {:stop, {:bad_return, other}}
    end
  end

  # `open` holds the kind and the kill of each request without a reply, by
  # its `from`. The session can have a turn, its steers, its interrupt, and
  # a tool result open; over @max_open the loop answers `{:error, :busy}`
  # itself, and the provider never sees the request. A tool result is not
  # limited: it is never open after its callback (see `write_result/4`).
  defp loop(harness) do
    step =
      receive do
        {:harness_request, from, tref, {:tool_result, _, _, _} = request} ->
          harness_request(request, from, tref, harness)

        {:harness_request, from, tref, {:tool_start, _, _} = request} ->
          harness_request(request, from, tref, harness)

        {:harness_request, from, tref, request} when map_size(harness.open) >= @max_open ->
          :timer.cancel(tref)
          send(harness.session, {:harness_reply, from, {:error, :busy}})
          replied(kind(request), {:error, :busy}, harness)

        {:harness_request, from, tref, request} ->
          harness_request(request, from, tref, harness)

        message ->
          case harness.provider.harness_info(message, harness.state) do
            {:ok, actions, state} -> act(actions, %{harness | state: state})
            {:stop, reason, _state} -> {:stop, {:harness_stop, reason}}
            other -> {:stop, {:bad_return, other}}
          end
      end

    case step do
      {:ok, harness} -> loop(harness)
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
  # an ended turn, or of a call that the harness withdrew) is answered `:ok`
  # here and dropped, so it never answers a call of a later turn.
  defp harness_request({:turn, turn_id, _context} = request, from, tref, harness) do
    with {:ok, harness} <- end_tools(harness),
         do: provide(request, from, tref, %{harness | live: turn_id})
  end

  defp harness_request({:interrupt, turn_id} = request, from, tref, %{live: turn_id} = harness) do
    with {:ok, harness} <- end_tools(harness), do: provide(request, from, tref, harness)
  end

  defp harness_request({:tool_result, turn_id, call_id, _result} = request, from, tref, harness) do
    if harness.started == {turn_id, call_id} or open_call?(harness, turn_id, call_id) do
      calls = MapSet.delete(harness.calls, call_id)
      harness = %{harness | calls: calls, started: nil}

      with {:ok, harness} <- write_result(request, from, tref, harness),
           do: run_next(turn_id, call_id, harness)
    else
      :timer.cancel(tref)
      send(harness.session, {:harness_reply, from, :ok})
      run_next(turn_id, call_id, harness)
    end
  end

  # The loop answers the ask itself and never waits for the session.
  defp harness_request({:tool_start, turn_id, call_id}, from, tref, harness) do
    :timer.cancel(tref)

    if open_call?(harness, turn_id, call_id) and harness.running == call_id do
      send(harness.session, {:harness_reply, from, :ok})
      {:ok, %{harness | started: {turn_id, call_id}}}
    else
      send(harness.session, {:harness_reply, from, :dropped})
      run_next(turn_id, call_id, harness)
    end
  end

  defp harness_request(request, from, tref, harness), do: provide(request, from, tref, harness)

  # Gives a request to the provider. An internal request of the loop has no
  # kill (`tref` nil), and its reply does not go to the session.
  defp provide(request, from, tref, harness) do
    harness = %{harness | open: Map.put(harness.open, from, {kind(request), tref})}

    case harness.provider.harness_request(request, from, harness.state) do
      {:ok, actions, state} -> act(actions, %{harness | state: state})
      other -> {:stop, {:bad_return, other}}
    end
  end

  # The terminal of the live turn ends its tools.
  defp end_live_tools(turn_id, %{live: turn_id} = harness), do: end_tools(harness)
  defp end_live_tools(_turn_id, harness), do: {:ok, harness}

  defp open_call?(harness, turn_id, call_id),
    do: harness.live == turn_id and MapSet.member?(harness.calls, call_id)

  # The result of the running call came: the next waiting call runs.
  defp run_next(turn_id, call_id, %{live: turn_id, running: call_id} = harness) do
    case harness.waiting do
      [] -> {:ok, %{harness | running: nil}}
      [{event, rejection} | waiting] -> run(event, rejection, %{harness | waiting: waiting})
    end
  end

  defp run_next(_turn_id, _call_id, harness), do: {:ok, harness}

  defp run({:tool_request, call_id, _, _} = event, rejection, harness) do
    harness = %{harness | running: call_id}
    sent(Stream.send_event(harness.session, harness.live, event, rejection), harness)
  end

  # The live turn ends: each open tool request gets `aborted`, except a
  # started one, which only the result of its run answers.
  defp end_tools(%{live: turn_id, calls: calls} = harness) do
    harness = %{
      harness
      | live: nil,
        running: nil,
        waiting: [],
        calls: MapSet.new(),
        seen: MapSet.new()
    }

    calls = Enum.reject(calls, &(harness.started == {turn_id, &1}))

    Enum.reduce_while(calls, {:ok, harness}, fn call_id, {:ok, harness} ->
      case answer_tool(turn_id, call_id, "aborted", harness) do
        {:ok, harness} -> {:cont, {:ok, harness}}
        done -> {:halt, done}
      end
    end)
  end

  # The loop's own answer has no armed kill (`tref` nil).
  defp answer_tool(turn_id, call_id, text, harness) do
    write_result({:tool_result, turn_id, call_id, {:error, text}}, make_ref(), nil, harness)
  end

  # The provider replies to every tool result inside its callback, so the
  # result is written before the next request (the interrupt, the next
  # turn) reaches the provider. A reply that did not come stops the harness
  # process.
  defp write_result({:tool_result, turn_id, call_id, _result} = request, from, tref, harness) do
    with {:ok, harness} <- provide(request, from, tref, harness) do
      if Map.has_key?(harness.open, from),
        do: {:stop, {:tool_result_not_answered, turn_id, call_id}},
        else: {:ok, harness}
    end
  end

  # A request of the live turn puts its call id in `seen` before any check
  # that answers it, so an id that got any answer never runs later in the
  # turn.
  defp tool_request(
         turn_id,
         {:tool_request, call_id, _, _} = event,
         rejection,
         %{live: turn_id} = harness
       ) do
    seen? = MapSet.member?(harness.seen, call_id)
    harness = %{harness | seen: MapSet.put(harness.seen, call_id)}

    cond do
      MapSet.member?(harness.calls, call_id) ->
        {:stop, {:bad_action, {:event, turn_id, event}}}

      # An earlier answer, or the result of a withdrawn run, could answer it.
      seen? ->
        answer_tool(turn_id, call_id, "the call id was used before in this turn", harness)

      # A withdrawn running call still runs until its result comes.
      length(harness.waiting) + if(harness.running, do: 1, else: 0) >= @max_tools ->
        answer_tool(turn_id, call_id, @too_many, harness)

      true ->
        harness = %{harness | calls: MapSet.put(harness.calls, call_id)}

        if harness.running,
          do: {:ok, %{harness | waiting: harness.waiting ++ [{event, rejection}]}},
          else: run(event, rejection, harness)
    end
  end

  # A turn that is not live never becomes live again.
  defp tool_request(turn_id, {:tool_request, call_id, _, _}, _rejection, harness),
    do: answer_tool(turn_id, call_id, "aborted", harness)

  defp kind({kind, _turn_id, _id, _value}) when kind in [:steer, :tool_result], do: kind
  defp kind({kind, _turn_id, _context}), do: kind
  defp kind({kind, _turn_id}), do: kind
  defp kind(close) when close in [:close, :idle_close], do: close

  # An improper list stops at its tail, as a bad return.
  defp act([], harness), do: {:ok, harness}

  defp act([action | rest], harness) do
    case action(action, harness) do
      {:ok, harness} -> act(rest, harness)
      done -> done
    end
  end

  defp act(other, _harness), do: {:stop, {:bad_return, other}}

  # A turn that the program started by itself (#240) is live, as after a
  # `{:turn, ...}` request. Its id is the provider's, with the checks of a
  # harness session id.
  defp action({:event, turn_id, :program_turn} = action, harness) do
    if Message.harness_id?(turn_id) do
      with {:ok, harness} <- end_tools(harness) do
        message = {:stream_event, turn_id, :program_turn}
        sent(Stream.send_checked(harness.session, message), %{harness | live: turn_id})
      end
    else
      {:stop, {:bad_action, action}}
    end
  end

  # An event passes the check of a stream event of an external turn. A
  # terminal goes to the session as `{:stream_end, turn_id, terminal}`, with
  # the cap that a stream Task applies to its terminal. A malformed event
  # stops the loop: the program's turn is then in an unknown state.
  defp action({:event, turn_id, event}, harness) when is_binary(turn_id) do
    case Stream.check(event, true) do
      {:send, {:tool_request, _, _, _} = event, rejection} ->
        tool_request(turn_id, event, rejection, harness)

      {:send, event, rejection} ->
        sent(Stream.send_event(harness.session, turn_id, event, rejection), harness)

      {:terminal, terminal} ->
        message = {:stream_end, turn_id, Message.cap_integers(terminal)}

        with {:ok, harness} <- sent(Stream.send_checked(harness.session, message), harness),
             do: end_live_tools(turn_id, harness)

      {:bad, {:error, reason}} ->
        {:stop, reason}
    end
  end

  defp action({:reply, from, value} = action, %{open: open} = harness)
       when is_map_key(open, from) do
    {{kind, tref}, open} = Map.pop!(open, from)

    if reply?(kind, value) do
      if tref do
        :timer.cancel(tref)
        send(harness.session, {:harness_reply, from, value})
      end

      replied(kind, value, %{harness | open: open})
    else
      {:stop, {:bad_action, action}}
    end
  end

  # The harness withdrew a tool request: the session stops the running
  # call, and a waiting one leaves the queue. A pair that is not open has
  # nothing to stop.
  defp action({:cancel_tool, turn_id, call_id} = action, harness)
       when is_binary(turn_id) and is_binary(call_id) do
    cond do
      # Also after the turn: the result of its killed run is then dropped.
      harness.started == {turn_id, call_id} ->
        harness = %{harness | calls: MapSet.delete(harness.calls, call_id), started: nil}
        sent(Stream.send_checked(harness.session, action), harness)

      not open_call?(harness, turn_id, call_id) ->
        {:ok, harness}

      # Not started: the ask gets `:dropped`, and the next call runs then.
      harness.running == call_id ->
        {:ok, %{harness | calls: MapSet.delete(harness.calls, call_id)}}

      true ->
        waiting = Enum.reject(harness.waiting, &match?({{_, ^call_id, _, _}, _}, &1))
        {:ok, %{harness | calls: MapSet.delete(harness.calls, call_id), waiting: waiting}}
    end
  end

  defp action(action, _harness), do: {:stop, {:bad_action, action}}

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
  defp replied(kind, :ok, _harness) when kind in [:close, :idle_close], do: :closed

  defp replied(kind, {:error, reason}, _harness) when kind != :steer,
    do: {:stop, {:harness_error, kind, reason}}

  defp replied(_kind, _answer, harness), do: {:ok, harness}

  defp sent(:ok, harness), do: {:ok, harness}
  defp sent({:error, reason}, _harness), do: {:stop, reason}
end
