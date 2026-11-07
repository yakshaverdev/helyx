defmodule Helyx.TUI.Wire.Writer do
  @moduledoc false
  # The writer of `Helyx.TUI.Wire.Connection` (docs/features/tui-attach.md,
  # decision 15): it sends the frames of the connection in their order on
  # the socket of the connection, which stays its controlling process and
  # reads, so the connection reads while a frame goes out. It encodes each
  # frame with `Mint.WebSocket.encode/2` and sends the bytes with
  # `:gen_tcp.send/2`, so each send has the send timeout of the socket. It
  # answers each batch with its `done` message, and a failed send with
  # `:write_failed`, and then ends; the connection kills it at its own end.

  alias Helyx.Transport.WebSocket.Frame

  # A frame of the wire as a map, or a pong with its payload.
  @type item :: map() | {:pong, binary()}

  # Starts the writer of `socket`, linked to the caller, which gets its
  # answers. The WebSocket state has no negotiated extension, so encoding
  # changes nothing that a later frame reads.
  @spec start_link(:gen_tcp.socket(), term()) :: pid()
  def start_link(socket, ws) do
    conn = self()
    spawn_link(fn -> loop(conn, socket, ws) end)
  end

  # Sends `items` after the batches before them, then `done` to the caller
  # of `start_link/2`.
  @spec write(pid(), [item()], term()) :: :ok
  def write(writer, items, done) do
    send(writer, {:write, items, done})
    :ok
  end

  defp loop(conn, socket, ws) do
    receive do
      {:write, items, done} ->
        case send_all(items, socket, ws) do
          {:ok, ws} ->
            send(conn, done)
            loop(conn, socket, ws)

          {:error, _reason} ->
            send(conn, :write_failed)
        end
    end
  end

  # The texts of a frame, its parts too, go out one after the other, so no
  # pong comes between them.
  defp send_all(items, socket, ws) do
    Enum.reduce_while(items, {:ok, ws}, fn item, {:ok, ws} ->
      case send_item(item, socket, ws) do
        {:ok, ws} -> {:cont, {:ok, ws}}
        error -> {:halt, error}
      end
    end)
  end

  defp send_item({:pong, payload}, socket, ws),
    do: send_frame(socket, ws, {:pong, payload})

  defp send_item(frame, socket, ws) do
    Enum.reduce_while(Frame.encode(frame), {:ok, ws}, fn text, {:ok, ws} ->
      case send_frame(socket, ws, {:text, IO.iodata_to_binary(text)}) do
        {:ok, ws} -> {:cont, {:ok, ws}}
        error -> {:halt, error}
      end
    end)
  end

  defp send_frame(socket, ws, frame) do
    case Mint.WebSocket.encode(ws, frame) do
      {:ok, ws, bytes} ->
        case :gen_tcp.send(socket, bytes) do
          :ok -> {:ok, ws}
          {:error, _reason} = error -> error
        end

      {:error, _ws, reason} ->
        {:error, reason}
    end
  end
end
