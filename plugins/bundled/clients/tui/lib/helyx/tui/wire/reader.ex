defmodule Helyx.TUI.Wire.Reader do
  @moduledoc false
  # The messages of the server in the bytes that arrive on the socket,
  # decoded by `Mint.WebSocket.decode/2`: complete texts, oldest first, and
  # pings, pongs, and closes. Mint joins the WebSocket fragments of a text
  # and keeps a partial frame in its state, so the caller keeps the
  # `Mint.WebSocket.t/0` that each call returns.
  #
  # A text over the frame bound of the wire, a control frame over 125 bytes
  # (RFC 6455, section 5.5), a binary frame, or a frame that Mint cannot
  # decode ends the messages: the call gives the messages before it as
  # `{:partial, ...}`, and the next call gives `:broken`. Mint allocates a
  # whole frame before it returns it, so the bounds are checked after the
  # decode; `@max_buffer` bounds the bytes before it.

  alias Helyx.Transport.WebSocket.Frame

  @max_frame Frame.max_frame()

  # The most bytes of one message that Mint has not decoded yet, four times
  # the message bound: the bound alone leaves no room for a frame header, a
  # chunk boundary, or the JSON around a text at the bound. It stops the read
  # before a frame over the bound can be allocated.
  @max_buffer 4 * @max_frame

  @type message ::
          {:text, binary()} | {:ping, binary()} | {:close, non_neg_integer() | nil, binary()}

  # `{:ok, messages, websocket}`: the whole messages, oldest first, and the
  # WebSocket state to pass to the next call. `{:partial, messages, socket}`
  # is the messages before a frame that the contract does not allow, which
  # the next call reports as `:broken`; only such a frame gives `:broken`.
  def read(ws, bytes) do
    case read(ws, bytes, 0) do
      {:ok, messages, ws, _pending} -> {:ok, messages, ws}
      other -> other
    end
  end

  # As `read/2`, with the bytes that the last undecoded frame already holds:
  # `{:ok, messages, ws, pending}` keeps the count while no message is whole,
  # and resets it when one is.
  def read(ws, bytes, pending) do
    pending = pending + byte_size(bytes)
    if pending > @max_buffer, do: :broken, else: decode(ws, bytes, pending)
  end

  defp decode(ws, bytes, pending) do
    case Mint.WebSocket.decode(ws, bytes) do
      {:ok, ws, []} -> {:ok, [], ws, pending}
      {:ok, ws, frames} -> decode_frames(frames, ws)
      {:error, _ws, _reason} -> :broken
    end
  end

  defp decode_frames(frames, ws) do
    case frames(frames, ws, []) do
      {:ok, messages, ws} -> {:ok, messages, ws, 0}
      other -> other
    end
  end

  defp frames([], ws, acc), do: {:ok, Enum.reverse(acc), ws}

  defp frames([frame | rest], ws, acc) do
    case message(frame) do
      :skip -> frames(rest, ws, acc)
      :broken -> partial(acc, ws)
      message -> frames(rest, ws, [message | acc])
    end
  end

  defp partial([], _ws), do: :broken
  defp partial(acc, ws), do: {:partial, Enum.reverse(acc), ws}

  defp message({:text, text}) when byte_size(text) <= @max_frame, do: {:text, text}
  defp message({:ping, data}) when byte_size(data) <= 125, do: {:ping, data}
  defp message({:pong, data}) when byte_size(data) <= 125, do: :skip
  defp message({:close, code, reason}), do: {:close, code, reason}
  # A binary frame, a text or control frame over its bound, and an error of
  # Mint, such as a reserved bit or an insular continuation.
  defp message(_frame), do: :broken
end
