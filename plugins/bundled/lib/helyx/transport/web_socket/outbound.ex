defmodule Helyx.Transport.WebSocket.Outbound do
  @moduledoc false
  # The outbound queue of a connection: the frames that its writers (the
  # request workers and the subscription processes) encoded and the
  # connection process did not take yet. A writer adds with no wait; an add
  # to a queue over 64 MiB closes the connection with 4408
  # (`docs/features/wire-protocol.md`, "Bounds").

  alias Helyx.Transport.WebSocket.Frame

  @max_bytes 67_108_864

  @enforce_keys [:conn, :bytes]
  defstruct @enforce_keys

  def new(conn), do: %__MODULE__{conn: conn, bytes: :atomics.new(1, signed: true)}

  # `:ok`, or `:full` when the connection closes.
  def add(out, frame), do: put(out, frame, &{:out, &1, &2})

  # The reply of request `id`; the connection drops it when the request
  # already has one.
  def reply(out, id, result) do
    writer = self()
    put(out, res(id, result), &{:reply, writer, id, &1, &2})
  end

  @texts %{
    "bad_params" => "a param is missing, of the wrong type, or unknown",
    "busy" => "too many requests in flight",
    "unknown_op" => "unknown operation",
    "unknown_sub" => "no such subscription",
    "too_many_subscriptions" => "too many subscriptions",
    "session_not_found" => "no such session runs",
    "timeout" => "the operation passed its deadline",
    "failed" => "the operation failed"
  }

  # The error of a code of the transport, with its fixed text.
  def error(code), do: {:error, code, Map.fetch!(@texts, code)}

  def res(id, {:ok, result}), do: %{"type" => "res", "id" => id, "ok" => true, "result" => result}

  def res(id, {:error, code, text}),
    do: %{
      "type" => "res",
      "id" => id,
      "ok" => false,
      "error" => %{"code" => code, "text" => text}
    }

  # Waits for the one encoder slot of the connection; the reply of the
  # writer, or its end, frees it.
  def slot(out) do
    send(out.conn, {:slot, self()})

    receive do
      :slot -> :ok
    end
  end

  def close(out, code), do: send(out.conn, {:close, code})

  # The connection takes `size` bytes off the queue.
  def taken(out, size), do: :atomics.sub(out.bytes, 1, size)

  defp put(out, frame, message) do
    # A binary goes to the connection by reference; an iolist would be copied.
    texts = frame |> Frame.encode() |> Enum.map(&IO.iodata_to_binary/1)
    size = Enum.sum_by(texts, &byte_size/1)

    if :atomics.add_get(out.bytes, 1, size) - size > @max_bytes do
      close(out, 4408)
      :full
    else
      send(out.conn, message.(texts, size))
      :ok
    end
  end
end
