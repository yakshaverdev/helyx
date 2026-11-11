defmodule Helyx.Hub.Store.SQLite.Subscriptions do
  @moduledoc false
  # The event subscription queries of the SQLite store (`docs/features/hub.md`,
  # decision 17, "Store schema"). A subscription belongs to its owner, but
  # the webhook endpoint finds it by its id alone: the id is the secret path,
  # and the signature of the payload is the check.

  import Helyx.Hub.Store.SQLite.Query

  alias Helyx.Hub.Store.SQLite.Tables

  @select """
  SELECT #{Tables.select(:subscriptions, "s.")},
         EXISTS (
           SELECT 1 FROM schedules d
           WHERE d.subscription_id = s.id AND d.delivery_id IS NOT NULL
         )
  FROM subscriptions s
  """

  defp row(values), do: Tables.row(:subscriptions, values)

  # The subscriptions of `owner`, of one session or all, oldest first, with
  # whether each holds a pending delivery.
  def subscriptions(db, owner, session_id) do
    {where, args} =
      if session_id,
        do: {"WHERE s.owner = ?1 AND s.session_id = ?2", [owner, session_id]},
        else: {"WHERE s.owner = ?1", [owner]}

    sql = @select <> where <> " ORDER BY s.created_at, s.id"

    with {:ok, rows} <- all(db, sql, args), do: {:ok, Enum.map(rows, &pending/1)}
  end

  def subscription(db, id) do
    case one(db, @select <> " WHERE s.id = ?1", [id]) do
      {:ok, nil} -> {:error, :not_found}
      {:ok, values} -> {:ok, pending(values)}
      {:error, _} = error -> error
    end
  end

  defp pending(values) do
    {_row, [pending]} = Enum.split(values, length(Tables.columns(:subscriptions)))
    Map.put(row(values), :pending, pending == 1)
  end

  # A new row, unless its session holds `per_session` rows or its owner
  # `per_user`: the cap check and the insert are one step. The rows of the
  # session are those of every user, as for schedules, so a session that
  # changes owner keeps its cap.
  def put_subscription(db, subscription, per_session, per_user, deadline) do
    sql =
      "SELECT (SELECT count(*) FROM subscriptions WHERE session_id = ?1), " <>
        "(SELECT count(*) FROM subscriptions WHERE owner = ?2)"

    transaction(db, deadline, fn ->
      with {:ok, [session, user]} <- one(db, sql, [subscription.session_id, subscription.owner]),
           do: insert(db, subscription, session < per_session and user < per_user)
    end)
  end

  defp insert(_db, _subscription, false = _room), do: {:error, :too_many_event_subscriptions}

  defp insert(db, subscription, true) do
    run(
      db,
      Tables.insert(:subscriptions),
      Enum.map(Tables.columns(:subscriptions), &Map.fetch!(subscription, &1))
    )
  end

  def delete_subscription(db, owner, id, deadline),
    do:
      delete(db, deadline, "DELETE FROM subscriptions WHERE id = ?1 AND owner = ?2", [id, owner])

  # Only a final outcome moves the delivery state (`Wake.settle/5`); a
  # put-back never calls this. Once `refused` is stored, no later outcome
  # replaces it: the endpoint of the subscription stays gone until a delete
  # (decision 17).
  def subscription_sent(db, id, at, outcome, deadline) do
    transaction(db, deadline, fn ->
      run(
        db,
        "UPDATE subscriptions SET last_at = ?2, last_outcome = ?3 " <>
          "WHERE id = ?1 AND (last_outcome IS NULL OR last_outcome != 'refused')",
        [id, at, outcome]
      )
    end)
  end
end
