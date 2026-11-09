defmodule Helyx.Hub.Store.SQLite.Query do
  @moduledoc false
  # How the SQLite store runs a query and a transaction: a failed query is
  # `{:error, :failed}`, a held lock `{:error, :busy}`, and a transaction
  # that reaches its commit at or past the deadline of its Hub call rolls
  # back with `{:error, :timeout}` (`docs/features/hub.md`, decision 5).

  alias Exqlite.Sqlite3

  # A delete and its count of rows in one step; no row is :not_found.
  def delete(db, deadline, sql, args) do
    transaction(db, deadline, fn ->
      with :ok <- run(db, sql, args), do: changed(db)
    end)
  end

  def changed(db) do
    case Sqlite3.changes(db) do
      {:ok, 0} -> {:error, :not_found}
      {:ok, _} -> :ok
      {:error, _} -> {:error, :failed}
    end
  end

  # One step: the body and its writes commit together or not at all. Any
  # answer but :ok or {:ok, _} rolls back, and so does a body that ends at or
  # past the deadline of its Hub call, so its caller, which waits the
  # deadline and a margin, gets the answer of every write that committed.
  def transaction(db, deadline, body) do
    case exec(db, "BEGIN IMMEDIATE") do
      :ok -> finish(db, deadline, body.())
      {:error, _} -> {:error, :failed}
    end
  end

  defp finish(db, deadline, :ok), do: commit(db, deadline, :ok)
  defp finish(db, deadline, {:ok, _} = result), do: commit(db, deadline, result)
  defp finish(db, _deadline, result), do: rollback(db, result)

  defp commit(db, deadline, result) do
    if deadline != :infinity and System.monotonic_time(:millisecond) >= deadline do
      rollback(db, {:error, :timeout})
    else
      case exec(db, "COMMIT") do
        :ok -> result
        {:error, _} -> rollback(db, {:error, :failed})
      end
    end
  end

  defp rollback(db, result) do
    _ = exec(db, "ROLLBACK")
    result
  end

  def exec(db, sql) do
    case Sqlite3.execute(db, sql) do
      :ok -> :ok
      {:error, reason} -> {:error, error(reason)}
    end
  end

  def run(db, sql, args) do
    with {:ok, _} <- all(db, sql, args), do: :ok
  end

  def one(db, sql, args) do
    with {:ok, rows} <- all(db, sql, args), do: {:ok, List.first(rows)}
  end

  def all(db, sql, args) do
    case Sqlite3.prepare(db, sql) do
      {:ok, stmt} ->
        try do
          with :ok <- Sqlite3.bind(stmt, args),
               {:ok, _rows} = ok <- Sqlite3.fetch_all(db, stmt) do
            ok
          else
            {:error, reason} -> {:error, error(reason)}
          end
        after
          Sqlite3.release(db, stmt)
        end

      {:error, reason} ->
        {:error, error(reason)}
    end
  end

  # SQLite names a held lock "database is locked"; the rest is a failed query.
  defp error("database is locked" <> _), do: :busy
  defp error(_), do: :failed
end
