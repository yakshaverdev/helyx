defmodule Helyx.Transport.WebSocket.Records do
  @moduledoc false
  # One records subscription of a connection (`docs/features/live-records.md`).
  # It asks the authority of the connection once, replies with the first list,
  # and writes the change frames and the full lists that the authority sends
  # until its unsubscribe or the end of the connection.

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
      {:ok, result} ->
        Outbound.reply(out, req_id, {:ok, result})
        loop(out)

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

  defp loop(out) do
    receive do
      {:record_change, change} ->
        if Outbound.add(out, %{"type" => "record", "change" => change}) == :ok, do: loop(out)

      {:records_full, records, more} ->
        frame = %{"type" => "records", "records" => records, "more" => more}

        if Outbound.add(out, frame) == :ok, do: loop(out)

      {:unsubscribe, req_id} ->
        Outbound.reply(out, req_id, {:ok, %{}})
    end
  end
end
