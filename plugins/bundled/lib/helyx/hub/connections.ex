defmodule Helyx.Hub.Connections do
  @moduledoc false
  # The connections of each user of a Hub (`docs/features/hub.md`, decision
  # 13), in the state of the Hub process: monitor ref => `%{pid, user,
  # token}`, one entry for each `hello` whose token the Hub found, until the
  # `:DOWN` of its connection: at most the 64 connections of each transport,
  # and those whose `:DOWN` is still in the mailbox. A connection whose proof
  # then fails closes at once, so its entry goes at that `:DOWN`. A change of
  # access closes the connections that it concerns with 4403, through the
  # transport (`Helyx.Transport.WebSocket.close/2`): the close comes after
  # the frames that the connection took before it.

  alias Helyx.Transport.WebSocket

  def init(state), do: Map.put(state, :connections, %{})

  # `token` is nil for the server token.
  def add(state, pid, user, token) do
    ref = Process.monitor(pid)
    %{state | connections: Map.put(state.connections, ref, %{pid: pid, user: user, token: token})}
  end

  # The `:DOWN` of a connection; another ref changes nothing.
  def down(state, ref), do: %{state | connections: Map.delete(state.connections, ref)}

  def close_token(state, token_id), do: close(state, &(&1.token == token_id))

  def close_user(state, user_id), do: close(state, &(&1.user == user_id))

  # The connections of every user but those in `keep`.
  def close_others(state, keep), do: close(state, &(&1.user not in keep))

  defp close(state, which?) do
    for {_ref, connection} <- state.connections,
        which?.(connection),
        do: WebSocket.close(connection.pid, 4403)

    state
  end
end
