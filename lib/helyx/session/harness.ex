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

  # The loop state: the provider and its state, the session, and `open`
  # (see `loop/1`).
  @enforce_keys [:provider, :state, :session]
  defstruct [:provider, :state, :session, open: %{}]

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
  @spec request(pid(), Helyx.Provider.request(), pos_integer()) :: reference()
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
  # its `from`. The session can have a turn, its steers, and its interrupt
  # open; over @max_open the loop answers `{:error, :busy}` itself, and the
  # provider never sees the request.
  defp loop(harness) do
    receive do
      {:harness_request, from, tref, request} when map_size(harness.open) >= @max_open ->
        :timer.cancel(tref)
        send(harness.session, {:harness_reply, from, {:error, :busy}})

        case replied(kind(request), {:error, :busy}, harness) do
          {:ok, harness} -> loop(harness)
          done -> done
        end

      {:harness_request, from, tref, request} ->
        harness = %{harness | open: Map.put(harness.open, from, {kind(request), tref})}

        case harness.provider.harness_request(request, from, harness.state) do
          {:ok, actions, state} -> act(actions, %{harness | state: state})
          other -> {:stop, {:bad_return, other}}
        end

      message ->
        case harness.provider.harness_info(message, harness.state) do
          {:ok, actions, state} -> act(actions, %{harness | state: state})
          {:stop, reason, _state} -> {:stop, {:harness_stop, reason}}
          other -> {:stop, {:bad_return, other}}
        end
    end
  end

  defp kind({:steer, _turn_id, _steer_id, _text}), do: :steer
  defp kind({kind, _turn_id, _context}), do: kind
  defp kind({kind, _turn_id}), do: kind
  defp kind(close) when close in [:close, :idle_close], do: close

  # An improper list stops at its tail, as a bad return.
  defp act([], harness), do: loop(harness)

  defp act([action | rest], harness) do
    case action(action, harness) do
      {:ok, harness} -> act(rest, harness)
      done -> done
    end
  end

  defp act(other, _harness), do: {:stop, {:bad_return, other}}

  # An event passes the check of a stream event of an external turn. A
  # terminal goes to the session as `{:stream_end, turn_id, terminal}`, with
  # the cap that a stream Task applies to its terminal. A malformed event
  # stops the loop: the program's turn is then in an unknown state.
  defp action({:event, turn_id, event}, harness) when is_binary(turn_id) do
    case Stream.check(event, true) do
      {:send, event, rejection} ->
        sent(Stream.send_event(harness.session, turn_id, event, rejection), harness)

      {:terminal, terminal} ->
        message = {:stream_end, turn_id, Message.cap_integers(terminal)}
        sent(Stream.send_checked(harness.session, message), harness)

      {:bad, {:error, reason}} ->
        {:stop, reason}
    end
  end

  defp action({:reply, from, value} = action, %{open: open} = harness)
       when is_map_key(open, from) do
    {{kind, tref}, open} = Map.pop!(open, from)

    if reply?(kind, value) do
      :timer.cancel(tref)
      send(harness.session, {:harness_reply, from, value})
      replied(kind, value, %{harness | open: open})
    else
      {:stop, {:bad_action, action}}
    end
  end

  # Helyx tool requests arrive with #203; until then no tool request is
  # open, so there is nothing to cancel.
  defp action({:cancel_tool, turn_id, call_id}, harness)
       when is_binary(turn_id) and is_binary(call_id),
       do: {:ok, harness}

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
