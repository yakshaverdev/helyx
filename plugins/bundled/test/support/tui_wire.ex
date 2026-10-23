defmodule Helyx.Test.TUIWire do
  @moduledoc false
  # The TUI uses only the wire (docs/features/tui-attach.md, decision 12):
  # a test of the TUI on a session of its Core mounts it on a link over a
  # transport of that Core, as `CodingAgent.attach/2` does. Call it from the
  # test process: the transport is a child of its test supervisor, one for
  # each Core, and the connection ends with the process that opened it or
  # took it.

  import ExUnit.Callbacks, only: [start_supervised!: 2]

  alias Helyx.Transport.WebSocket
  alias Helyx.TUI.{Link, Wire}
  alias Helyx.TUI.Wire.Connection

  # `session` of Core over a new connection of the caller, which the TUI
  # takes at its mount.
  def link(%Helyx.Session{core: core, id: id}), do: %Link{conn: conn(core), id: id}

  # A new connection of the caller to the transport of `core`. The
  # handshake is a wait that must happen: the cap of the tests (#805).
  defp conn(core) do
    {:ok, socket} = Wire.connect({127, 0, 0, 1}, port(core), fn -> "token" end, wait_ms())
    {:ok, conn, _ref} = Connection.open(socket)
    conn
  end

  defp port(core) do
    case Process.get({__MODULE__, core}) do
      nil ->
        transport = start_supervised!({WebSocket, core: core, port: 0}, id: {__MODULE__, core})
        port = WebSocket.port(transport)
        Process.put({__MODULE__, core}, port)
        port

      port ->
        port
    end
  end

  defp wait_ms, do: Helyx.Test.Events.wait_ms()
end
