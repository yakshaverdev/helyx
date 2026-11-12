defmodule Helyx.Transport.WebSocket.TLS.Transport do
  @moduledoc false
  # The TLS transport of the public listener (`docs/features/remote-hands.md`,
  # "Public listener"). It is the transport of Thousand Island, except that
  # the handshake ends at `Helyx.Transport.WebSocket.TLS.handshake_ms/0`, so a
  # TCP connection that sends no ClientHello does not hold a place until the
  # default of `:ssl` ends it.

  @behaviour ThousandIsland.Transport

  alias Helyx.Transport.WebSocket.TLS
  alias ThousandIsland.Transports.SSL

  @impl true
  defdelegate listen(port, options), to: SSL

  @impl true
  defdelegate accept(listener), to: SSL

  @impl true
  def handshake(socket) do
    case :ssl.handshake(socket, TLS.handshake_ms()) do
      {:ok, socket, _extensions} -> {:ok, socket}
      other -> other
    end
  end

  @impl true
  defdelegate upgrade(socket, options), to: SSL

  @impl true
  defdelegate controlling_process(socket, pid), to: SSL

  @impl true
  defdelegate recv(socket, length, timeout), to: SSL

  @impl true
  defdelegate send(socket, data), to: SSL

  @impl true
  defdelegate sendfile(socket, filename, offset, length), to: SSL

  @impl true
  defdelegate getopts(socket, options), to: SSL

  @impl true
  defdelegate setopts(socket, options), to: SSL

  @impl true
  defdelegate shutdown(socket, way), to: SSL

  @impl true
  defdelegate close(socket), to: SSL

  @impl true
  defdelegate sockname(socket), to: SSL

  @impl true
  defdelegate peername(socket), to: SSL

  @impl true
  defdelegate peercert(socket), to: SSL

  @impl true
  defdelegate secure?(), to: SSL

  @impl true
  defdelegate getstat(socket), to: SSL

  @impl true
  defdelegate negotiated_protocol(socket), to: SSL

  @impl true
  defdelegate connection_information(socket), to: SSL
end
