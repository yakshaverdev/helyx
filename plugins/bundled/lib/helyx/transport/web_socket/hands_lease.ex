defmodule Helyx.Transport.WebSocket.HandsLease do
  @moduledoc false
  # The registration of a hands connection and its lease
  # (`docs/features/remote-hands.md`, "Registration and lease"). One
  # connection holds one registration: its lease timer chain starts once.

  alias Helyx.Transport.WebSocket.{Frame, Outbound, Pairing}

  # The id of the liveness request that the server sends a hands connection
  # (`docs/features/remote-hands.md`, "Registration and lease"). The request
  # id carries its sequence, so an answer of an older request does not renew
  # the lease.
  @live_prefix "hands.live:"

  # The folder of a session on a runner is the folder of the runner
  # (`docs/features/remote-hands.md`, decision 5). One connection holds one
  # registration: its lease timer chain starts once.
  def register(id, _params, %{lease_ms: lease_ms} = state) when is_integer(lease_ms),
    do: error(id, "bad_params", state)

  def register(id, %{"runner" => runner, "folder" => folder} = params, state)
      when map_size(params) == 2 and is_binary(folder) do
    if runner == state.runner and byte_size(folder) <= Pairing.max_folder_bytes() do
      case Pairing.register_hands(state.pairing, self(), runner) do
        {:ok, lease_ms} ->
          state = lease(state, lease_ms)
          {:push, texts(Outbound.res(id, {:ok, %{"lease_ms" => lease_ms}})), state}

        {:error, _unauthorized} ->
          close(4401, state)
      end
    else
      close(4401, state)
    end
  end

  def register(id, _params, state), do: error(id, "bad_params", state)

  # The lease runs on the server's clock: one liveness request each third,
  # and a close when its answer came no later than one lease before.
  def live(%{lease_ms: lease_ms} = state) when is_integer(lease_ms) do
    Process.send_after(self(), :hands_live, div(lease_ms, 3))

    if state.live_id == nil do
      id = @live_prefix <> Integer.to_string(state.live_seq)

      request = %{
        "type" => "req",
        "id" => id,
        "op" => "hands.live",
        "params" => %{"seq" => state.live_seq, "ack" => state.live_ack}
      }

      {:push, texts(request), %{state | live_id: id, live_seq: state.live_seq + 1}}
    else
      {:ok, state}
    end
  end

  def live(state), do: {:ok, state}

  def expiry(%{lease_ms: lease_ms, lease_at: at} = state) when is_integer(lease_ms) do
    idle = now() - at

    if idle >= lease_ms do
      close(4408, state)
    else
      Process.send_after(self(), :hands_lease, lease_ms - idle)
      {:ok, state}
    end
  end

  def expiry(state), do: {:ok, state}

  defp lease(state, lease_ms) do
    Process.send_after(self(), :hands_live, div(lease_ms, 3))
    Process.send_after(self(), :hands_lease, lease_ms)
    %{state | lease_ms: lease_ms, lease_at: now()}
  end

  defp error(id, code, state), do: {:push, texts(Outbound.res(id, Outbound.error(code))), state}

  defp texts(frame), do: Enum.map(Frame.encode(frame), &{:text, &1})

  defp close(code, state), do: {:stop, {:shutdown, :closed}, code, state}

  defp now, do: System.monotonic_time(:millisecond)
end
