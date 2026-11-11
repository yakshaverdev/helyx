defmodule Helyx.Hub.Store.SQLite.Schedules do
  @moduledoc false
  # The schedule queries of the SQLite store (`docs/features/hub.md`, "Store
  # schema", decisions 11, 12, and 17). A schedule belongs to its owner: an
  # id of another user answers as a missing one. A one-run delivery of a
  # webhook is a row with a `subscription_id` (decision 17); the schedule
  # caps and listings leave those rows out, and the poll of decision 12
  # reads them with the schedules.

  import Helyx.Hub.Store.SQLite.Query

  @columns ~w(id owner session_id prompt at every run delivery_id due_at next_try_at last_at
              last_outcome created_at subscription_id)a
  @select "SELECT #{Enum.join(@columns, ", ")} FROM schedules"

  # The columns that a conditional write may compare and set.
  @state ~w(at run delivery_id due_at next_try_at last_at last_outcome)a

  # The ended deliveries of a subscription that a new acceptance prunes,
  # as a multiple of the rate window.
  @prune_windows 2

  defp row(values), do: @columns |> Enum.zip(values) |> Map.new()

  # The schedules of `owner`, of one session or all, oldest first; at most
  # 256, the cap of a user. A webhook delivery is not a schedule.
  def schedules(db, owner, session_id) do
    {where, args} =
      if session_id,
        do: {"owner = ?1 AND session_id = ?2 AND subscription_id IS NULL", [owner, session_id]},
        else: {"owner = ?1 AND subscription_id IS NULL", [owner]}

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
        "count(*) FILTER (WHERE owner = ?2) FROM schedules " <>
        "WHERE subscription_id IS NULL AND (session_id = ?1 OR owner = ?2)"

    transaction(db, deadline, fn ->
      with {:ok, [session, user]} <- one(db, sql, [schedule.session_id, schedule.owner]),
           do: insert(db, schedule, session < per_session and user < per_user)
    end)
  end

  # The one-run delivery of a webhook (decision 17): the pending cap and the
  # rolling window of accepted deliveries, with the insert, in one step.
  def put_delivery(db, row, per_pending, per_hour, window_s, now, deadline) do
    prune =
      "DELETE FROM schedules WHERE subscription_id = ?1 AND delivery_id IS NULL " <>
        "AND created_at <= ?2"

    count =
      "SELECT count(*) FILTER (WHERE last_outcome IS NULL OR last_outcome = 'unconfirmed'), " <>
        "count(*) FILTER (WHERE created_at > ?2) FROM schedules WHERE subscription_id = ?1"

    transaction(db, deadline, fn ->
      with :ok <- run(db, prune, [row.subscription_id, now - @prune_windows * window_s]),
           {:ok, [pending, recent]} <-
             one(db, count, [row.subscription_id, now - window_s]),
           do: delivery(db, row, pending < per_pending, recent < per_hour)
    end)
  end

  defp delivery(_db, _row, false = _pending?, _recent?), do: {:error, :too_many_pending}
  defp delivery(_db, _row, true, false = _recent?), do: {:error, :rate_limited}
  defp delivery(db, row, true, true), do: insert(db, row, true)

  defp insert(_db, _schedule, false = _room), do: {:error, :too_many_schedules}

  defp insert(db, schedule, true) do
    marks = Enum.map_join(1..length(@columns), ", ", &"?#{&1}")

    run(
      db,
      "INSERT INTO schedules (#{Enum.join(@columns, ", ")}) VALUES (#{marks})",
      Enum.map(@columns, &Map.fetch!(schedule, &1))
    )
  end

  # A delete of a schedule; a webhook delivery row has its own delete (the
  # cascade of its subscription).
  def delete_schedule(db, owner, id, deadline) do
    sql = "DELETE FROM schedules WHERE id = ?1 AND owner = ?2 AND subscription_id IS NULL"
    delete(db, deadline, sql, [id, owner])
  end

  # The rows whose `next_try_at` has come, oldest `next_try_at` first, at
  # most `limit`: schedules and the deliveries of webhooks.
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
