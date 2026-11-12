defmodule Helyx.Transport.WebSocket.Records do
  @moduledoc false
  # One records subscription of a connection (`docs/features/live-records.md`).
  # It asks the authority of the connection once, replies with the first list,
  # and writes the change frames and the full lists that the authority sends
  # until its unsubscribe, the end of its Hub, or the end of the connection.
  #
  # It monitors the Hub process of the authority: a Hub that restarts leaves a
  # subscription that no Hub holds, so the process sends `records_end` and
  # ends, and the client subscribes again (`wire-protocol.md`, O7).

  alias Helyx.Transport.WebSocket.{Ops, Outbound}

  # `authority` is the `{module, arg}` of the connection and `auth` its
  # credential.
  def start_link(out, req_id, authority, auth),
    do: spawn_link(fn -> start(out, req_id, authority, auth) end)

  defp start(out, req_id, {mod, arg}, auth) do
    # The reply can be as large as the first list, so it takes the encoder
    # slot of the connection.
    Outbound.slot(out)

    case subscribe(mod, arg, auth) do
      {:ok, result, hub} ->
        ref = if is_pid(hub), do: Process.monitor(hub)
        Outbound.reply(out, req_id, {:ok, result})
        loop(out, ref)

      answer ->
        reply(out, req_id, answer)
    end
  end

  # A trust boundary: the authority may not export the callback, and its call
  # may exit.
  defp subscribe(mod, arg, auth) do
    if function_exported?(mod, :records, 3) do
      mod.records(arg, auth, self())
    else
      {:error, "unknown_op", "unknown operation"}
    end
  catch
    :exit, _reason -> :timeout
  end

  defp reply(out, req_id, answer) do
    case answer do
      {:error, _code, _text} -> Outbound.reply(out, req_id, answer)
      {:error, code} -> Outbound.reply(out, req_id, Ops.error("records.subscribe", code))
      {:close, 4403} -> Outbound.close(out, 4403)
      :timeout -> Outbound.reply(out, req_id, Outbound.error("timeout"))
    end
  end

  defp loop(out, ref) do
    receive do
      {:record_change, change} ->
        if Outbound.add(out, %{"type" => "record", "change" => change}) == :ok,
          do: loop(out, ref)

      {:records_full, records, more} ->
        frame = %{"type" => "records", "records" => records, "more" => more}

        if Outbound.add(out, frame) == :ok, do: loop(out, ref)

      {:unsubscribe, req_id} ->
        Outbound.reply(out, req_id, {:ok, %{}})

      {:DOWN, ^ref, :process, _pid, _reason} ->
        # The connection frees the writer before the frame goes, so a
        # subscribe that follows the records_end finds no subscription.
        send(out.conn, {:records_ended, self()})
        Outbound.add(out, %{"type" => "records_end"})
    end
  end
end
