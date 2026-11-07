defmodule Helyx.Hub.Rules do
  @moduledoc false
  # The rules of access that the Hub process decides for its authority
  # (`Helyx.Hub.Access`; `docs/features/hub.md`, decisions 3, 4, 7, 8). Each
  # request is one Hub call; each first checks that the credential of the
  # connection still holds, and answers `:revoked` when it does not.

  # The caps of decision 14 and Bounds.
  @max_records 10_000
  @max_cwd_bytes 4_096

  # The key of the token of a `hello`, or the closure of the server token
  # for a `hello` with no token id, which the caller runs and checks;
  # `:error` when there is none. The caller computes the proof. A store that
  # fails answers `:busy`: the client connects again later.
  def handle({:hello, nil}, _deadline, state) do
    case state.server_token do
      nil -> :error
      token -> {:ok, %{user: state.default_owner_id, token: nil, server_token: token}}
    end
  end

  def handle({:hello, token_id}, _deadline, %{store: mod, db: db}) do
    case mod.token(db, token_id) do
      {:ok, token} -> {:ok, %{user: token.user_id, token: token.id, key: token.key}}
      {:error, :not_found} -> :error
      {:error, :failed} -> {:error, :busy}
    end
  end

  def handle({:credential, auth}, _deadline, state), do: credential(auth, state)

  def handle({:me, auth}, _deadline, state) do
    with {:ok, user} <- holder(auth, state), do: {:ok, Map.take(user, [:id, :name])}
  end

  def handle({:tokens, auth}, _deadline, %{store: mod, db: db} = state) do
    with :ok <- credential(auth, state), do: mod.tokens(db, auth.user)
  end

  def handle({:revoke, auth, token_id}, deadline, %{store: mod, db: db} = state) do
    with :ok <- credential(auth, state) do
      case mod.revoke_token(db, auth.user, token_id, deadline) do
        {:error, :not_found} -> {:error, :unknown_token}
        other -> other
      end
    end
  end

  # A start of a user who is not the default owner writes a record at its
  # result, so it needs a place among the records of its user and a `cwd`
  # that a record holds.
  def handle({:start, auth, cwd_bytes}, _deadline, %{store: mod, db: db} = state) do
    with :ok <- credential(auth, state) do
      cond do
        auth.user == state.default_owner_id -> :ok
        cwd_bytes not in 1..@max_cwd_bytes -> {:error, :bad_params}
        true -> places(mod.count_records(db, auth.user))
      end
    end
  end

  def handle({:session, auth, kind, session_id, touch}, deadline, state) do
    with :ok <- credential(auth, state),
         {:ok, access} <- access(session_id, state),
         :ok <- allowed(kind, access, auth.user) do
      touch(session_id, touch, deadline, state)
    end
  end

  def handle({:readable, auth, session_ids}, _deadline, %{store: mod, db: db} = state) do
    with :ok <- credential(auth, state),
         {:ok, rows} <- mod.records(db, session_ids) do
      derived = derived(state)
      {:ok, Enum.filter(session_ids, &readable?(Map.get(rows, &1, derived), auth.user))}
    end
  end

  def handle({:started, auth, start}, deadline, state) do
    with :ok <- credential(auth, state) do
      if auth.user == state.default_owner_id,
        do: :ok,
        else: record(auth.user, start, deadline, state)
    end
  end

  defp record(owner, start, deadline, %{store: mod, db: db} = state) do
    with {:ok, model} <- model(start.model, state.core) do
      now = System.os_time(:second)
      fields = %{owner: owner, model: model, prompt: "", active_at: now, created_at: now}
      mod.put_record(db, Map.merge(start, fields), @max_records, deadline)
    end
  end

  # A start with no model has the default model of the Core; a Core that
  # stopped since the start has none to read.
  defp model(nil, core) do
    {:ok, Helyx.Core.config(core, :model)}
  rescue
    ArgumentError -> {:error, :failed}
  end

  defp model(model, _core), do: {:ok, model}

  defp credential(auth, state) do
    with {:ok, _user} <- holder(auth, state), do: :ok
  end

  # The user of a credential that still holds: the user exists, and its
  # token, when it has one, is not revoked (decision 5, `check`). The server
  # token has no row.
  defp holder(%{user: user, token: token}, %{store: mod, db: db}) do
    with {:ok, found} <- mod.user(db, user),
         :ok <- token_holds(mod, db, user, token) do
      {:ok, found}
    else
      {:error, :failed} -> {:error, :failed}
      _ -> :revoked
    end
  end

  defp token_holds(_mod, _db, _user, nil), do: :ok

  defp token_holds(mod, db, user, token) do
    case mod.token(db, token) do
      {:ok, %{user_id: ^user}} -> :ok
      {:ok, _} -> :error
      error -> error
    end
  end

  defp places({:ok, n}) when n < @max_records, do: :ok
  defp places({:ok, _n}), do: {:error, :too_many_records}
  defp places(error), do: error

  # The record of a session: its row, or the derived record of the default
  # owner (decision 8).
  defp access(session_id, %{store: mod, db: db} = state) do
    case mod.record(db, session_id) do
      {:ok, row} -> {:ok, Map.take(row, [:owner, :visibility])}
      {:error, :not_found} -> {:ok, derived(state)}
      error -> error
    end
  end

  defp derived(state), do: %{owner: state.default_owner_id, visibility: "private"}

  defp readable?(%{owner: user}, user), do: true
  defp readable?(%{visibility: visibility}, _user), do: visibility == "hub"

  # Decisions 4 and 7: a reader reads, only the owner writes or resumes.
  defp allowed(:read, access, user),
    do: if(readable?(access, user), do: :ok, else: {:error, :session_not_found})

  defp allowed(:resume, %{owner: owner}, user),
    do: if(owner == user, do: :ok, else: {:error, :not_found})

  defp allowed(:write, %{owner: user}, user), do: :ok

  defp allowed(:write, access, user),
    do: if(readable?(access, user), do: {:error, :forbidden}, else: {:error, :session_not_found})

  # A resume or a user text that Hub authorized moves `active_at`, and the
  # first text sets `prompt` (Store schema).
  defp touch(_session_id, nil, _deadline, _state), do: :ok

  defp touch(session_id, {:touch, prompt}, deadline, %{store: mod, db: db}),
    do: mod.touch_record(db, session_id, System.os_time(:second), prompt, deadline)
end
