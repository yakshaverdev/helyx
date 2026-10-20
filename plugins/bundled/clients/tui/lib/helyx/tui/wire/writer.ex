defmodule Helyx.TUI.Wire.Writer do
  @moduledoc false
  # The writer of `Helyx.TUI.Wire.Connection` (docs/features/tui-attach.md,
  # decision 15): it sends the frames of the connection in their order on
  # the socket of the connection, which stays its controlling process and
  # reads, so the connection reads while a frame goes out. Each send has
  # the send timeout of the socket. It answers each batch with its `done`
  # message, and a failed send with `:write_failed`, and then ends; the
  # connection kills it at its own end.

  alias Helyx.Transport.WebSocket.Frame
  alias Helyx.TUI.Wire

  # A frame of the wire as a map, or a pong with its payload.
  @type item :: map() | {:pong, binary()}

  # Starts the writer of `socket`, linked to the caller, which gets its
  # answers.
  @spec start_link(:gen_tcp.socket()) :: pid()
  def start_link(socket) do
    conn = self()
    spawn_link(fn -> loop(conn, socket) end)
  end

  # Sends `items` after the batches before them, then `done` to the caller
  # of `start_link/1`.
  @spec write(pid(), [item()], term()) :: :ok
  def write(writer, items, done) do
    send(writer, {:write, items, done})
    :ok
  end

  defp loop(conn, socket) do
    receive do
      {:write, items, done} ->
        case send_all(items, socket) do
          :ok ->
            send(conn, done)
            loop(conn, socket)

          {:error, _reason} ->
            send(conn, :write_failed)
        end
    end
  end

  # The texts of a frame, its parts too, go out one after the other, so no
  # pong comes between them.
  defp send_all(items, socket) do
    items
    |> Stream.flat_map(&frames/1)
    |> Enum.reduce_while(:ok, fn frame, :ok ->
      case :gen_tcp.send(socket, frame) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp frames({:pong, payload}), do: [Wire.masked(10, payload)]

  defp frames(frame),
    do: Stream.map(Frame.encode(frame), &Wire.masked(1, IO.iodata_to_binary(&1)))
end
