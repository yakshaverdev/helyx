defmodule Helyx.Session.ProviderProcess do
  @moduledoc false
  # The Core loop of a provider process (ADR 0007): a long-lived Task of
  # the hands that runs the callbacks of a provider. The callbacks run only
  # here. The loop checks every action at the boundary, sends each event and
  # reply to the session, and ends itself on a bad action, a stop, or an
  # error answer to `{:turn, ...}` or `{:interrupt, ...}`. It never ends
  # with `:normal` (L1 in `docs/features/one-provider-path.md`), so every
  # process linked to it ends with it: it exits with `{:shutdown, reason}`,
  # and the hands report `reason` in `{:provider_down, pid, reason}` after
  # its release. Every session request has an armed kill
  # (`ProviderRequest`). The session owns the turn and its Helyx tool calls
  # (`docs/features/one-provider-path.md`, "Ownership"); the loop keeps no
  # turn state.

  alias Helyx.Message
  alias Helyx.Session.{ProviderRequest, Stream}

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
  # its `from`. The session bounds each kind of request (`Bounds` in
  # `docs/features/long-lived-harness.md`), so the loop does not.
  defp loop(proc) do
    step =
      receive do
        {:provider_request, from, tref, request} ->
          provide(request, from, tref, proc)

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

  defp provide(request, from, tref, proc) do
    kind = ProviderRequest.kind(request)
    proc = %{proc | open: Map.put(proc.open, from, {kind, tref})}

    case proc.provider.request(request, from, proc.state) do
      {:ok, actions, state} -> act(actions, %{proc | state: state})
      other -> {:stop, {:bad_return, other}}
    end
  end

  # An improper list stops at its tail, as a bad return.
  defp act([], proc), do: {:ok, proc}

  defp act([action | rest], proc) do
    case action(action, proc) do
      {:ok, proc} -> act(rest, proc)
      done -> done
    end
  end

  defp act(other, _proc), do: {:stop, {:bad_return, other}}

  # A turn that the program started by itself (#240). Its id is the
  # provider's, with the checks of a resume id; the session opens or drops it.
  defp action({:event, turn_id, :turn_start} = action, proc) do
    if Message.resume_id?(turn_id),
      do: sent(Stream.send_checked(proc.session, {:stream_event, turn_id, :turn_start}), proc),
      else: {:stop, {:bad_action, action}}
  end

  # An event passes the check of a provider event. A tool request goes to
  # the session with this pid and its rejection reason, and the session
  # answers it, also after its turn. A terminal goes as `{:stream_end,
  # turn_id, terminal}`, with the integer cap. A malformed event stops the
  # loop: the program's turn is then in an unknown state.
  defp action({:event, turn_id, event}, proc) when is_binary(turn_id) do
    case Stream.check(event) do
      {:send, {:tool_request, call}, rejection} ->
        message = {:tool_request, self(), turn_id, call, rejection}
        sent(Stream.send_checked(proc.session, message), proc)

      {:send, event, _rejection} ->
        sent(Stream.send_checked(proc.session, {:stream_event, turn_id, event}), proc)

      {:terminal, terminal} ->
        message = {:stream_end, turn_id, Message.cap_integers(terminal)}
        sent(Stream.send_checked(proc.session, message), proc)

      {:bad, {:error, reason}} ->
        {:stop, reason}
    end
  end

  # A fresh context (C2, C3), after the events before it, and a withdrawn
  # tool request: the session checks both against its turn.
  defp action({:need_context, turn_id} = action, proc) when is_binary(turn_id),
    do: sent(Stream.send_checked(proc.session, action), proc)

  defp action({:cancel_tool, turn_id, call_id} = action, proc)
       when is_binary(turn_id) and is_binary(call_id),
       do: sent(Stream.send_checked(proc.session, action), proc)

  defp action({:reply, from, value} = action, %{open: open} = proc)
       when is_map_key(open, from) do
    {{kind, tref}, open} = Map.pop!(open, from)

    if ProviderRequest.reply?(kind, value) do
      ProviderRequest.answer(proc.session, from, tref, kind, value)

      ProviderRequest.stop_after(kind, value) || {:ok, %{proc | open: open}}
    else
      {:stop, {:bad_action, action}}
    end
  end

  defp action(action, _proc), do: {:stop, {:bad_action, action}}

  defp sent(:ok, proc), do: {:ok, proc}
  defp sent({:error, reason}, _proc), do: {:stop, reason}
end
