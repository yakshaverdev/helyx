defmodule Helyx.Hub.Store.SQLiteSchedulesTest do
  use ExUnit.Case, async: true

  alias Helyx.Hub.Store.SQLite

  defp user(name),
    do: %{id: name <> String.duplicate("x", 12 - byte_size(name)), name: name, created_at: 1}

  defp schedule(id, owner, session, next_try_at \\ 100) do
    %{
      id: id,
      owner: user(owner).id,
      session_id: session,
      prompt: "p",
      at: next_try_at,
      every: nil,
      run: 0,
      delivery_id: "d" <> id,
      due_at: next_try_at,
      next_try_at: next_try_at,
      last_at: nil,
      last_outcome: nil,
      created_at: 1,
      subscription_id: nil
    }
  end

  defp subscription(id, owner, session \\ "S") do
    %{
      id: id,
      owner: user(owner).id,
      session_id: session,
      template: "{{payload}}",
      label: "",
      secret: "secret",
      created_at: 1,
      last_at: nil,
      last_outcome: nil
    }
  end

  defp delivery(id, subscription_id, owner, created_at) do
    %{
      id: id,
      subscription_id: subscription_id,
      owner: user(owner).id,
      session_id: "S",
      prompt: "p",
      at: created_at,
      every: nil,
      run: 0,
      delivery_id: "x" <> id,
      due_at: created_at,
      next_try_at: created_at,
      last_at: nil,
      last_outcome: nil,
      created_at: created_at
    }
  end

  defp end_delivery(db, id) do
    :ok =
      SQLite.update_schedule(
        db,
        id,
        %{run: 0},
        %{delivery_id: nil, due_at: nil, next_try_at: nil, last_outcome: "delivered"},
        :infinity
      )
  end

  # The rows of a query, on the connection inside the handle of the store.
  defp count(%{db: db}, sql, args) do
    {:ok, stmt} = Exqlite.Sqlite3.prepare(db, sql)
    :ok = Exqlite.Sqlite3.bind(stmt, args)
    {:ok, [[n]]} = Exqlite.Sqlite3.fetch_all(db, stmt)
    :ok = Exqlite.Sqlite3.release(db, stmt)
    n
  end

  setup do
    {:ok, db} = SQLite.open(path: nil)
    :ok = SQLite.add_user(db, user("a"), 64, :infinity)
    :ok = SQLite.add_user(db, user("b"), 64, :infinity)
    %{db: db}
  end

  test "the caps of a session and of a user hold in one step", %{db: db} do
    :ok = SQLite.put_schedule(db, schedule("s1", "a", "S1"), 2, 3, :infinity)
    :ok = SQLite.put_schedule(db, schedule("s2", "a", "S1"), 2, 3, :infinity)
    # At the cap of the session, one under the cap of the user.
    assert SQLite.put_schedule(db, schedule("s3", "a", "S1"), 2, 3, :infinity) ==
             {:error, :too_many_schedules}

    :ok = SQLite.put_schedule(db, schedule("s3", "a", "S2"), 2, 3, :infinity)
    # At the cap of the user.
    assert SQLite.put_schedule(db, schedule("s4", "a", "S3"), 2, 3, :infinity) ==
             {:error, :too_many_schedules}

    # The rows of another user count toward the cap of the session, not the user.
    assert SQLite.put_schedule(db, schedule("s4", "b", "S1"), 2, 3, :infinity) ==
             {:error, :too_many_schedules}

    :ok = SQLite.put_schedule(db, schedule("s4", "b", "S3"), 2, 3, :infinity)

    assert {:ok, [%{id: "s1"}, %{id: "s2"}, %{id: "s3"}]} =
             SQLite.schedules(db, user("a").id, nil)

    assert {:ok, [%{id: "s3"}]} = SQLite.schedules(db, user("a").id, "S2")
    assert {:ok, []} = SQLite.schedules(db, user("b").id, "S1")
  end

  test "an ended row of another user does not count toward the cap of the session", %{db: db} do
    :ok = SQLite.put_schedule(db, schedule("s1", "a", "S1"), 1, 3, :infinity)
    # A pending row of the user who owned the session before counts.
    assert SQLite.put_schedule(db, schedule("s2", "b", "S1"), 1, 3, :infinity) ==
             {:error, :too_many_schedules}

    ended = %{delivery_id: nil, due_at: nil, next_try_at: nil, last_outcome: "refused"}
    :ok = SQLite.update_schedule(db, "s1", %{run: 0}, ended, :infinity)
    :ok = SQLite.put_schedule(db, schedule("s2", "b", "S1"), 1, 3, :infinity)
    # The ended row still counts for its own user.
    assert SQLite.put_schedule(db, schedule("s3", "a", "S1"), 1, 3, :infinity) ==
             {:error, :too_many_schedules}
  end

  test "a delete is scoped to its owner; a user removed takes its schedules", %{db: db} do
    :ok = SQLite.put_schedule(db, schedule("s1", "a", "S1"), 16, 256, :infinity)
    assert SQLite.delete_schedule(db, user("b").id, "s1", :infinity) == {:error, :not_found}
    assert {:ok, %{id: "s1"}} = SQLite.schedule(db, "s1")
    assert SQLite.delete_schedule(db, user("a").id, "s1", :infinity) == :ok
    assert SQLite.schedule(db, "s1") == {:error, :not_found}

    :ok = SQLite.put_schedule(db, schedule("s2", "a", "S1"), 16, 256, :infinity)
    :ok = SQLite.remove_user(db, user("a").id, :infinity)
    assert SQLite.schedule(db, "s2") == {:error, :not_found}
  end

  test "due: the rows whose next try has come, oldest first, at most the limit", %{db: db} do
    for {id, at} <- [{"s1", 30}, {"s2", 10}, {"s3", 20}, {"s4", 41}] do
      :ok = SQLite.put_schedule(db, schedule(id, "a", "S" <> id, at), 16, 256, :infinity)
    end

    :ok =
      SQLite.put_schedule(db, %{schedule("s5", "a", "S5") | next_try_at: nil}, 16, 256, :infinity)

    assert {:ok, [%{id: "s2"}, %{id: "s3"}, %{id: "s1"}]} = SQLite.due(db, 40, 64)
    assert {:ok, [%{id: "s2"}, %{id: "s3"}]} = SQLite.due(db, 40, 2)
    assert {:ok, []} = SQLite.due(db, 9, 64)
  end

  test "a conditional write applies only while the row holds every expected value", %{db: db} do
    :ok = SQLite.put_schedule(db, schedule("s1", "a", "S1"), 16, 256, :infinity)

    assert SQLite.update_schedule(db, "s1", %{run: 1}, %{next_try_at: 7}, :infinity) ==
             {:error, :stale}

    # A null compares as a value.
    assert SQLite.update_schedule(db, "s1", %{run: 0, last_at: nil}, %{next_try_at: 7}, :infinity) ==
             :ok

    assert {:ok, %{next_try_at: 7}} = SQLite.schedule(db, "s1")

    changes = %{run: 1, last_outcome: "unconfirmed", delivery_id: nil, due_at: nil}
    assert SQLite.update_schedule(db, "s1", %{run: 0, next_try_at: 7}, changes, :infinity) == :ok

    assert {:ok, %{run: 1, last_outcome: "unconfirmed", delivery_id: nil, due_at: nil}} =
             SQLite.schedule(db, "s1")

    assert SQLite.update_schedule(db, "gone", %{run: 0}, %{next_try_at: 1}, :infinity) ==
             {:error, :stale}

    past = System.monotonic_time(:millisecond)
    assert SQLite.update_schedule(db, "s1", %{run: 1}, %{run: 2}, past) == {:error, :timeout}
    assert {:ok, %{run: 1}} = SQLite.schedule(db, "s1")
  end

  test "put_delivery counts a delivery in flight toward the pending cap", %{db: db} do
    :ok = SQLite.put_subscription(db, subscription("sub", "a"), 16, 256, :infinity)

    for n <- 1..15 do
      :ok =
        SQLite.put_delivery(
          db,
          delivery("d#{n}", "sub", "a", 1000),
          16,
          60,
          3_600,
          1000,
          :infinity
        )
    end

    :ok =
      SQLite.put_delivery(db, delivery("d16", "sub", "a", 1000), 16, 60, 3_600, 1000, :infinity)

    # The decide step of decision 12: no delivery id, unconfirmed.
    :ok =
      SQLite.update_schedule(
        db,
        "d16",
        %{run: 0},
        %{run: 1, last_outcome: "unconfirmed", delivery_id: nil, due_at: nil, next_try_at: nil},
        :infinity
      )

    assert SQLite.put_delivery(
             db,
             delivery("d17", "sub", "a", 1000),
             16,
             60,
             3_600,
             1000,
             :infinity
           ) ==
             {:error, :too_many_pending}

    sql =
      "SELECT count(*) FROM schedules WHERE subscription_id = 'sub' " <>
        "AND (last_outcome IS NULL OR last_outcome = 'unconfirmed')"

    assert count(db, sql, []) == 16
  end

  test "put_delivery prunes an ended delivery older than two windows", %{db: db} do
    :ok = SQLite.put_subscription(db, subscription("sub", "a"), 16, 256, :infinity)

    :ok =
      SQLite.put_delivery(db, delivery("d0", "sub", "a", 1000), 16, 60, 3_600, 1000, :infinity)

    :ok = end_delivery(db, "d0")

    :ok =
      SQLite.put_delivery(db, delivery("d1", "sub", "a", 8201), 16, 60, 3_600, 8201, :infinity)

    assert SQLite.schedule(db, "d0") == {:error, :not_found}
    assert count(db, "SELECT count(*) FROM schedules WHERE subscription_id = 'sub'", []) == 1
  end

  test "put_delivery expires an acceptance from the rolling hour", %{db: db} do
    :ok = SQLite.put_subscription(db, subscription("sub", "a"), 16, 256, :infinity)

    for id <- ["d1", "d2"] do
      :ok = SQLite.put_delivery(db, delivery(id, "sub", "a", 1000), 16, 2, 3_600, 1000, :infinity)
      :ok = end_delivery(db, id)
    end

    assert SQLite.put_delivery(
             db,
             delivery("d3", "sub", "a", 1000),
             16,
             2,
             3_600,
             1000,
             :infinity
           ) ==
             {:error, :rate_limited}

    :ok = SQLite.put_delivery(db, delivery("d4", "sub", "a", 4601), 16, 2, 3_600, 4601, :infinity)
    :ok = SQLite.put_delivery(db, delivery("d5", "sub", "a", 4601), 16, 2, 3_600, 4601, :infinity)

    assert SQLite.put_delivery(
             db,
             delivery("d6", "sub", "a", 4601),
             16,
             2,
             3_600,
             4601,
             :infinity
           ) ==
             {:error, :rate_limited}
  end
end
