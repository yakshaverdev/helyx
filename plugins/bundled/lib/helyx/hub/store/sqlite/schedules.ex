defmodule Helyx.Hub.Store.SQLite.Schedules do
  @moduledoc false
  # The schedule queries of the SQLite store (`docs/features/hub.md`, "Store
  # schema", decisions 11 and 12). A schedule belongs to its owner: an id of
  # another user answers as a missing one.

  import Helyx.Hub.Store.SQLite.Query

  @columns ~w(id owner session_id prompt at every run delivery_id due_at next_try_at last_at
              last_outcome created_at)a
  @select "SELECT #{Enum.join(@columns, ", ")} FROM schedules"

  # The columns that a conditional write may compare and set.
  @state ~w(at run delivery_id due_at next_try_at last_at last_outcome)a

  defp row(values), do: @columns |> Enum.zip(values) |> Map.new()

  # The schedules of `owner`, of one session or all, oldest first; at most
  # 256, the cap of a user.
  def schedules(db, owner, session_id) do
    {where, args} =
      if session_id,
        do: {"owner = ?1 AND session_id = ?2", [owner, session_id]},
        else: {"owner = ?1", [owner]}

    with {:ok, rows} <- all(db, "#{@select} WHERE #{where} ORDER BY created_at, id", args),
         do: {:ok, Enum.map(rows, &row/1)}
  end

  def schedule(db, id) do
    case one(db, "#{@select} WHERE id = ?1", [id]) do
      {:ok, nil} -> {:error, :not_found}
      {:ok, values} -> {:ok, row(values)}
      {:error, _} = error -> error
    end
  end

  # A new row, unless its session holds `per_session` rows or its owner
  # `per_user`: the cap check and the insert are one step. The rows of the
  # session are those of the owner and the pending ones of a user who owned
  # it before a record delete; an ended row of that user counts only for it.
  def put_schedule(db, schedule, per_session, per_user, deadline) do
    sql =
      "SELECT count(*) FILTER (WHERE session_id = ?1 AND (owner = ?2 OR delivery_id IS NOT NULL)), " <>
        "count(*) FILTER (WHERE owner = ?2) FROM schedules WHERE session_id = ?1 OR owner = ?2"

    transaction(db, deadline, fn ->
      with {:ok, [session, user]} <- one(db, sql, [schedule.session_id, schedule.owner]),
           do: insert(db, schedule, session < per_session and user < per_user)
    end)
  end

  defp insert(_db, _schedule, false = _room), do: {:error, :too_many_schedules}

  defp insert(db, schedule, true) do
    marks = Enum.map_join(1..length(@columns), ", ", &"?#{&1}")

    run(
      db,
      "INSERT INTO schedules (#{Enum.join(@columns, ", ")}) VALUES (#{marks})",
      Enum.map(@columns, &Map.fetch!(schedule, &1))
    )
  end

  def delete_schedule(db, owner, id, deadline),
    do: delete(db, deadline, "DELETE FROM schedules WHERE id = ?1 AND owner = ?2", [id, owner])

  # The rows whose `next_try_at` has come, oldest `next_try_at` first, at
  # most `limit`.
  def due(db, now, limit) do
    sql = "#{@select} WHERE next_try_at <= ?1 ORDER BY next_try_at, id LIMIT ?2"
    with {:ok, rows} <- all(db, sql, [now, limit]), do: {:ok, Enum.map(rows, &row/1)}
  end

  # Sets `changes` on the row `id` only while the row holds every value of
  # `expect`; else `{:error, :stale}`, a row that is gone too. `IS` compares
  # a null as a value.
  def update_schedule(db, id, expect, changes, deadline) do
    sets = for {key, value} <- changes, key in @state, do: {"#{key} = ?", value}
    checks = for {key, value} <- expect, key in @state, do: {"#{key} IS ?", value}
    true = map_size(changes) == length(sets) and map_size(expect) == length(checks)

    sql =
      "UPDATE schedules SET #{Enum.map_join(sets, ", ", &elem(&1, 0))} WHERE id = ?" <>
        Enum.map_join(checks, &" AND #{elem(&1, 0)}")

    args = Enum.map(sets, &elem(&1, 1)) ++ [id] ++ Enum.map(checks, &elem(&1, 1))

    transaction(db, deadline, fn ->
      with :ok <- run(db, sql, args), do: stale(changed(db))
    end)
  end

  defp stale({:error, :not_found}), do: {:error, :stale}
  defp stale(other), do: other
end
