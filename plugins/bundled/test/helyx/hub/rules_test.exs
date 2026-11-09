defmodule Helyx.Hub.RulesTest do
  use ExUnit.Case, async: true

  alias Helyx.Hub.{Live, Rules}
  alias Helyx.Hub.Store.SQLite

  # A Hub state on a store in memory with three users: the default owner,
  # ann, and bob. The rows of the tests are written with SQL: the record
  # operations of the wire are the next slice.
  setup do
    {:ok, db} = SQLite.open(path: nil)

    for id <- ~w(owner ann bob),
        do: :ok = SQLite.add_user(db, %{id: id, name: id, created_at: 1}, 64, :infinity)

    state = %{store: SQLite, db: db, default_owner_id: "owner", server_token: nil, core: nil}
    on_exit(fn -> SQLite.close(db) end)
    %{state: state, db: db}
  end

  defp row(db, session, owner, visibility) do
    :ok =
      Exqlite.Sqlite3.execute(
        db,
        "INSERT INTO records (session_id, owner, cwd, model, active_at, visibility, created_at, " <>
          "updated_at) VALUES ('#{session}', '#{owner}', '/w', 'fake/echo', 1, '#{visibility}', 1, 1)"
      )
  end

  # The session exists unless `exists?` says no (the existence check of the
  # caller, decision 8).
  defp ask(state, user, kind, session, touch \\ nil, exists? \\ true),
    do:
      Rules.handle(
        {:session, %{user: user, token: nil}, kind, session, exists?, touch},
        :infinity,
        state
      )

  test "a hub record: a reader reads, gets forbidden on a write and not_found on a resume",
       %{state: state, db: db} do
    row(db, "SHAREDxxxxxx", "ann", "hub")
    row(db, "PRIVATExxxxx", "ann", "private")

    assert ask(state, "bob", :read, "SHAREDxxxxxx") == :ok
    assert ask(state, "bob", :write, "SHAREDxxxxxx") == {:error, :forbidden}
    assert ask(state, "bob", :resume, "SHAREDxxxxxx") == {:error, :not_found}
    assert ask(state, "ann", :write, "SHAREDxxxxxx") == :ok

    # A private record of another user is a missing session, the default owner too.
    for user <- ~w(bob owner) do
      assert ask(state, user, :read, "PRIVATExxxxx") == {:error, :session_not_found}
      assert ask(state, user, :write, "PRIVATExxxxx") == {:error, :session_not_found}
      assert ask(state, user, :resume, "PRIVATExxxxx") == {:error, :not_found}
    end

    # A session with no row is the default owner's (decision 8).
    assert ask(state, "owner", :write, "NOROWxxxxxxx") == :ok
    assert ask(state, "bob", :write, "NOROWxxxxxxx") == {:error, :session_not_found}

    # An id with no row that the existence check did not confirm is missing
    # for every user, the default owner too.
    for user <- ~w(owner bob), kind <- [:read, :write] do
      assert ask(state, user, kind, "NOROWxxxxxxx", nil, false) == {:error, :session_not_found}
    end

    assert ask(state, "owner", :resume, "NOROWxxxxxxx", nil, false) == {:error, :not_found}

    auth = %{user: "bob", token: nil}
    ids = ~w(SHAREDxxxxxx PRIVATExxxxx NOROWxxxxxxx)
    assert Rules.handle({:readable, auth, ids}, :infinity, state) == {:ok, ["SHAREDxxxxxx"]}

    assert Rules.handle({:readable, %{auth | user: "owner"}, ids}, :infinity, state) ==
             {:ok, ["SHAREDxxxxxx", "NOROWxxxxxxx"]}
  end

  test "a user holds at most 10,000 records: the place of a start at 9,999 and at 10,000",
       %{state: state, db: db} do
    :ok = Exqlite.Sqlite3.execute(db, "BEGIN")

    for n <- 1..9_999,
        do: row(db, "s" <> String.pad_leading(Integer.to_string(n), 11, "0"), "ann", "private")

    :ok = Exqlite.Sqlite3.execute(db, "COMMIT")
    auth = %{user: "ann", token: nil}

    # The place of a start holds the cap (decision 14): at 9,999 rows a
    # start of ann gets a place, which counts until its result; a second
    # start finds the cap.
    state = state |> Map.put(:max_live, 64) |> Live.init()
    first = spawn_link(fn -> Process.sleep(:infinity) end)
    second = spawn_link(fn -> Process.sleep(:infinity) end)
    assert {:ok, state} = Live.reserve(state, "ann", first, true)
    assert Live.reserve(state, "ann", second, true) == {:error, :too_many_records}
    # The default owner writes no record at a start.
    assert {:ok, _} = Live.reserve(state, "owner", second, false)
    state = Live.release(state, first)
    row(db, "s10000xxxxxx", "ann", "private")
    assert Live.reserve(state, "ann", first, true) == {:error, :too_many_records}

    # The write of the result holds the same cap.
    start = %{session_id: "s10001xxxxxx", cwd: "/w", model: "fake/echo"}
    assert Rules.handle({:started, auth, start}, :infinity, state) == {:error, :too_many_records}
    :ok = Exqlite.Sqlite3.execute(db, "DELETE FROM records WHERE session_id = 's10000xxxxxx'")
    assert Rules.handle({:started, auth, start}, :infinity, state) == :ok
    assert {:ok, %{owner: "ann", prompt: ""}} = SQLite.record(db, "s10001xxxxxx")
  end

  test "the first update of a derived record holds the cap of 10,000 records",
       %{state: state, db: db} do
    :ok = Exqlite.Sqlite3.execute(db, "BEGIN")

    for n <- 1..9_999,
        do: row(db, "o" <> String.pad_leading(Integer.to_string(n), 11, "0"), "owner", "private")

    :ok = Exqlite.Sqlite3.execute(db, "COMMIT")
    auth = %{user: "owner", token: nil}
    found = %{cwd: "/w", model: "fake/echo"}
    update = &Rules.handle({:record_update, auth, &1, found, %{title: "t"}}, :infinity, state)

    assert {:ok, %{stored: true}} = update.("DERIVED1xxxx")
    assert update.("DERIVED2xxxx") == {:error, :too_many_records}
    assert SQLite.record(db, "DERIVED2xxxx") == {:error, :not_found}
  end

  test "the cwd of a start of a user: 1 to 4,096 bytes", %{state: state} do
    auth = %{user: "ann", token: nil}
    assert Rules.handle({:start, auth, 4_096}, :infinity, state) == :ok
    assert Rules.handle({:start, auth, 1}, :infinity, state) == :ok
    assert Rules.handle({:start, auth, 0}, :infinity, state) == {:error, :bad_params}
    assert Rules.handle({:start, auth, 4_097}, :infinity, state) == {:error, :bad_params}
    assert Rules.handle({:start, %{auth | user: "owner"}, 4_097}, :infinity, state) == :ok
  end

  test "the first text sets the prompt; later ones and sessions with no row do not",
       %{state: state, db: db} do
    row(db, "MINExxxxxxxx", "ann", "private")
    assert ask(state, "ann", :write, "MINExxxxxxxx", {:touch, "first"}) == :ok
    assert ask(state, "ann", :write, "MINExxxxxxxx", {:touch, "second"}) == :ok
    assert {:ok, %{prompt: "first", active_at: at}} = SQLite.record(db, "MINExxxxxxxx")
    assert at > 1
    assert ask(state, "owner", :write, "NOROWxxxxxxx", {:touch, "x"}) == :ok
    assert SQLite.record(db, "NOROWxxxxxxx") == {:error, :not_found}

    # A resume moves `active_at` and leaves the prompt.
    :ok = Exqlite.Sqlite3.execute(db, "UPDATE records SET active_at = 1")
    assert ask(state, "ann", :resume, "MINExxxxxxxx", {:touch, nil}) == :ok
    assert {:ok, %{prompt: "first", active_at: moved}} = SQLite.record(db, "MINExxxxxxxx")
    assert moved > 1
  end

  test "a start with no model, after its Core stopped, answers :failed", %{state: state} do
    start = %{session_id: "NOMODELxxxxx", cwd: "/w", model: nil}
    state = %{state | core: :core_that_does_not_run}
    auth = %{user: "ann", token: nil}
    assert Rules.handle({:started, auth, start}, :infinity, state) == {:error, :failed}
  end

  test "a credential that no longer holds is :revoked", %{state: state, db: db} do
    token = %{id: "TOKENxxxxxxx", user_id: "ann", name: "t", key: "k", created_at: 1}
    :ok = SQLite.add_token(db, token, 16, :infinity)
    auth = %{user: "ann", token: "TOKENxxxxxxx"}
    assert Rules.handle({:credential, auth}, :infinity, state) == :ok
    # A token of another user does not hold for this one.
    assert Rules.handle({:credential, %{auth | user: "bob"}}, :infinity, state) == :revoked
    :ok = SQLite.revoke_token(db, :any, "TOKENxxxxxxx", :infinity)
    assert Rules.handle({:credential, auth}, :infinity, state) == :revoked

    assert Rules.handle({:credential, %{user: "nobody", token: nil}}, :infinity, state) ==
             :revoked
  end
end
