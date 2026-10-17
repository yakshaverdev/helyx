defmodule Helyx.Transport.WebSocket.Subscription do
  @moduledoc false
  # One subscription of a connection (`docs/features/wire-protocol.md`,
  # "Subscriptions"). It owns the Core subscription and its end monitor,
  # encodes the events, and hands them to the connection in order: the
  # `subscribe` reply, the live events, then `session_end` or the
  # `unsubscribe` reply. It writes the `subscribe` reply itself, a `timeout`
  # too.

  alias Helyx.Transport.WebSocket.{Outbound, Wire}

  def start_link(out, sub, req_id, session, opts),
    do: spawn_link(fn -> init(out, sub, req_id, session, opts) end)

  defp init(out, sub, req_id, session, opts) do
    Outbound.slot(out)

    case Helyx.Session.subscribe(session, opts) do
      {:ok, %Helyx.Session.Snapshot{} = snapshot, ref} ->
        Outbound.reply(out, req_id, {:ok, %{"sub" => sub, "snapshot" => Wire.snapshot(snapshot)}})
        loop(%{out: out, sub: sub, session: session, ref: ref, seq: snapshot.seq, acked: 0})

      {:ok, {:replay, events}, ref} ->
        Outbound.reply(
          out,
          req_id,
          {:ok, %{"sub" => sub, "replay" => Enum.map(events, &Wire.event/1)}}
        )

        seq =
          case List.last(events) do
            nil -> elem(opts[:after], 1)
            event -> event.seq
          end

        loop(%{out: out, sub: sub, session: session, ref: ref, seq: seq, acked: 0})

      {:error, :session_not_found} ->
        Outbound.reply(out, req_id, Outbound.error("session_not_found"))

      {:error, _limit_or_after} ->
        Outbound.reply(out, req_id, Outbound.error("bad_params"))
    end
  catch
    :exit, {:timeout, _call} -> Outbound.reply(out, req_id, Outbound.error("timeout"))
  end

  defp loop(%{ref: ref} = state) do
    receive do
      {:helyx_event, %Helyx.Event{} = event} ->
        frame = %{"type" => "event", "sub" => state.sub, "event" => Wire.event(event)}
        if Outbound.add(state.out, frame) == :ok, do: loop(%{state | seq: event.seq})

      {:ack, seq} when seq > state.seq ->
        Outbound.close(state.out, 4400)

      # Only a higher ack goes to the session, so the acks that reach it
      # are at most the events sent.
      {:ack, seq} when seq > state.acked ->
        Helyx.Session.ack(state.session, seq)
        loop(%{state | acked: seq})

      {:ack, _seq} ->
        loop(state)

      {:unsubscribe, req_id} ->
        Outbound.reply(state.out, req_id, {:ok, %{}})

      {:helyx_end, ^ref, :slow} ->
        Outbound.close(state.out, 4408)

      {:DOWN, ^ref, :process, _pid, reason} ->
        reason = Atom.to_string(Helyx.Session.end_reason(reason))

        Outbound.add(state.out, %{"type" => "session_end", "sub" => state.sub, "reason" => reason})
    end
  end
end
