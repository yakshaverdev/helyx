defmodule Helyx.Test.BusyAuthority do
  @moduledoc false
  # An authority for the pairing tests whose `paired/4` answers `busy`, as a
  # Hub at its admission bound does (`docs/features/hub.md`, decision 5).

  @behaviour Helyx.Transport.WebSocket.Authority

  @impl true
  def hello(_arg, _hello), do: :error

  @impl true
  def paired(_arg, _kind, _name, _connection), do: {:error, :busy}

  @impl true
  def check(_arg, _auth, _op, _params), do: {:error, "failed"}

  @impl true
  def run(_arg, _auth, _op, _params), do: {:error, "failed", "failed"}

  @impl true
  def result(_arg, _auth, _op, _params, result), do: {:ok, result}

  @impl true
  def release(_arg, _auth, _op, _params), do: :ok
end
