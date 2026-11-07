defmodule Helyx.Hub.Server do
  @moduledoc false
  # The process of a Hub (`docs/features/hub.md`): the only caller of the
  # store, so a cap check and its insert are one step. Each request is a Hub
  # call of `Helyx.Hub.call/2` with its deadline; a call taken at or past
  # its deadline is dropped before it reads or writes.

  use GenServer

  alias Helyx.Hub.Rules

  # The caps of the operator API (Bounds).
  @max_users 64
  @max_tokens 16

  @impl true
  def init(config) do
    # The stop closes the store (decision 16).
    Process.flag(:trap_exit, true)

    # {:error, reason} ends the start with no exit signal to the caller.
    with {:ok, store} <- config.store.open(path: config.path) do
      case default_owner(config.store, store, config.default_owner) do
        {:ok, owner_id} ->
          {:ok, Map.merge(config, %{db: store, default_owner_id: owner_id})}

        {:error, _} = error ->
          config.store.close(store)
          error
      end
    end
  end

  defp default_owner(mod, store, name) do
    with {:ok, users} <- mod.users(store) do
      case Enum.find(users, &(&1.name == name)) do
        %{id: id} -> {:ok, id}
        nil -> insert_user(mod, store, name, :infinity)
      end
    end
  end

  defp insert_user(mod, store, name, deadline) do
    user = %{id: new_id(), name: name, created_at: System.os_time(:second)}

    case mod.add_user(store, user, @max_users, deadline) do
      :ok -> {:ok, user.id}
      {:error, :name_taken} -> {:error, :invalid_name}
      {:error, _} = error -> error
    end
  end

  @impl true
  def handle_call({:hub, deadline, request}, _from, state) do
    # A call taken at or past its deadline is dropped before it reads or
    # writes: its caller already exited on its timeout.
    if System.monotonic_time(:millisecond) >= deadline,
      do: {:noreply, state},
      else: {:reply, handle(request, deadline, state), state}
  end

  @impl true
  def terminate(_reason, state), do: state.store.close(state.db)

  defp handle({:add_user, name}, deadline, %{store: mod, db: db}) do
    with {:ok, id} <- insert_user(mod, db, name, deadline) do
      {:ok, %{id: id, name: name}}
    end
  end

  defp handle({:remove_user, id}, _deadline, %{default_owner_id: id}),
    do: {:error, :default_owner}

  defp handle({:remove_user, id}, deadline, %{store: mod, db: db}) do
    case mod.remove_user(db, id, deadline) do
      {:error, :not_found} -> {:error, :unknown_user}
      other -> other
    end
  end

  defp handle(:users, _deadline, %{store: mod, db: db}) do
    with {:ok, users} <- mod.users(db) do
      {:ok, Enum.map(users, &Map.take(&1, [:id, :name]))}
    end
  end

  defp handle({:create_token, user_id, name}, deadline, %{store: mod, db: db}) do
    id = new_id()
    text = id <> "." <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

    token = %{
      id: id,
      user_id: user_id,
      name: name,
      key: :crypto.hash(:sha256, text),
      created_at: System.os_time(:second)
    }

    with :ok <- mod.add_token(db, token, @max_tokens, deadline), do: {:ok, text}
  end

  defp handle({:revoke_token, token_id}, deadline, %{store: mod, db: db}) do
    case mod.revoke_token(db, :any, token_id, deadline) do
      {:error, :not_found} -> {:error, :unknown_token}
      other -> other
    end
  end

  # The calls of the authority (`Helyx.Hub.Access`).
  defp handle(request, deadline, state), do: Rules.handle(request, deadline, state)

  # The shape of a session id, the base64url of 9 random bytes (decisions 1
  # and 2). Helyx.Session.Id is internal to Core, which Hub does not call.
  defp new_id, do: Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)
end
