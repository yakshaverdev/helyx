defmodule Helyx.Hub.Store.SQLite.Records do
  @moduledoc false
  # The record queries of the SQLite store (`docs/features/hub.md`, "Store
  # schema", decisions 7 and 8).

  import Helyx.Hub.Store.SQLite.Query

  alias Helyx.Hub.Store.SQLite.Projects

  @columns "session_id, owner, project_id, title, cwd, model, prompt, active_at, " <>
             "visibility, archived, created_at, updated_at"

  def record(db, session_id) do
    case one(db, "SELECT #{@columns} FROM records WHERE session_id = ?1", [session_id]) do
      {:ok, nil} -> {:error, :not_found}
      {:ok, row} -> {:ok, row(row)}
      {:error, _} = error -> error
    end
  end

  defp row([id, owner, project, title, cwd, model, prompt, active, visibility, archived, at, up]) do
    %{
      session_id: id,
      owner: owner,
      project_id: project,
      title: title,
      cwd: cwd,
      model: model,
      prompt: prompt,
      active_at: active,
      visibility: visibility,
      archived: archived == 1,
      created_at: at,
      updated_at: up
    }
  end

  # The owner and the visibility of the ids that have a row; at most 256
  # ids, bound by the caller (Bounds).
  def records(_db, []), do: {:ok, %{}}

  def records(db, session_ids) do
    sql =
      "SELECT session_id, owner, visibility FROM records WHERE session_id IN (#{marks(session_ids)})"

    with {:ok, rows} <- all(db, sql, session_ids) do
      {:ok, Map.new(rows, fn [id, owner, vis] -> {id, %{owner: owner, visibility: vis}} end)}
    end
  end

  def count_records(db, owner) do
    with {:ok, [n]} <- one(db, "SELECT count(*) FROM records WHERE owner = ?1", [owner]),
         do: {:ok, n}
  end

  def put_record(db, record, max, deadline),
    do: transaction(db, deadline, fn -> put_new(db, record, max) end)

  # A new row, unless its owner holds `max` rows; none for nil.
  defp put_new(_db, nil, _max), do: :ok

  defp put_new(db, record, max) do
    with {:ok, n} <- count_records(db, record.owner), do: insert(db, record, n < max)
  end

  defp insert(_db, _record, false = _room), do: {:error, :too_many_records}
  defp insert(db, record, true), do: insert(db, record)

  defp insert(db, r) do
    run(
      db,
      "INSERT INTO records (session_id, owner, cwd, model, prompt, active_at, " <>
        "created_at, updated_at) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?7)",
      [r.session_id, r.owner, r.cwd, r.model, r.prompt, r.active_at, r.created_at]
    )
  end

  # The time of a start, resume, or user text that Hub authorized, and the
  # first such text when the row has none. A session with no row gets no
  # write.
  def touch_record(db, session_id, at, prompt, deadline) do
    transaction(db, deadline, fn ->
      run(
        db,
        "UPDATE records SET active_at = ?2, prompt = CASE WHEN prompt = '' AND ?3 IS NOT NULL " <>
          "THEN ?3 ELSE prompt END WHERE session_id = ?1",
        [session_id, at, prompt]
      )
    end)
  end

  # The labels of the ids, at most 256 ids, bound by the caller.
  def labels(_db, []), do: {:ok, %{}}

  def labels(db, session_ids) do
    sql =
      "SELECT session_id, label FROM labels WHERE session_id IN (#{marks(session_ids)}) " <>
        "ORDER BY label"

    with {:ok, rows} <- all(db, sql, session_ids) do
      {:ok, Enum.group_by(rows, &hd/1, &List.last/1)}
    end
  end

  # One step: the row of a derived record when `new` is given (within the
  # cap of its owner), then the changes, each checked against the row: a
  # project must be one of the owner of the row.
  def update_record(db, session_id, new, changes, max, deadline) do
    transaction(db, deadline, fn ->
      with :ok <- put_new(db, new, max),
           {:ok, owner} <- owner(db, session_id),
           :ok <- project_of(db, Map.get(changes, :project_id), owner),
           :ok <- set(db, session_id, changes),
           do: set_labels(db, session_id, Map.get(changes, :labels))
    end)
  end

  defp owner(db, session_id) do
    case one(db, "SELECT owner FROM records WHERE session_id = ?1", [session_id]) do
      {:ok, [owner]} -> {:ok, owner}
      {:ok, nil} -> {:error, :not_found}
      error -> error
    end
  end

  defp project_of(_db, nil, _owner), do: :ok

  defp project_of(db, project_id, owner) do
    case Projects.project(db, owner, project_id) do
      {:ok, _project} -> :ok
      {:error, :not_found} -> {:error, :unknown_project}
      error -> error
    end
  end

  # The columns of a change are the keys of `changes`.
  @fields ~w(title visibility archived project_id)a

  defp set(db, session_id, changes) do
    sets = for key <- @fields, Map.has_key?(changes, key), do: {key, value(key, changes[key])}
    columns = Enum.map_join(sets, fn {key, _} -> ", #{key} = ?" end)
    sql = "UPDATE records SET updated_at = ?#{columns} WHERE session_id = ?"
    run(db, sql, [System.os_time(:second) | Enum.map(sets, &elem(&1, 1))] ++ [session_id])
  end

  defp value(:archived, archived), do: if(archived, do: 1, else: 0)
  defp value(_key, value), do: value

  defp set_labels(_db, _session_id, nil), do: :ok

  defp set_labels(db, session_id, labels) do
    with :ok <- run(db, "DELETE FROM labels WHERE session_id = ?", [session_id]),
         do: insert_labels(db, session_id, labels)
  end

  # One insert of the set, at most 16 labels (Params).
  defp insert_labels(_db, _session_id, []), do: :ok

  defp insert_labels(db, session_id, labels) do
    values = Enum.map_join(labels, ", ", fn _ -> "(?, ?)" end)
    args = Enum.flat_map(labels, &[session_id, &1])
    run(db, "INSERT INTO labels (session_id, label) VALUES #{values}", args)
  end

  def delete_record(db, session_id, deadline),
    do: delete(db, deadline, "DELETE FROM records WHERE session_id = ?1", [session_id])

  # The stored records that `user` may read (its own; with `mine` false also
  # the "hub" records of others), newest `updated_at` first, then by session
  # id, after the cursor, at most `limit` + 1 rows. Access is a column of
  # the query, so the page holds only readable rows.
  # Each clause binds its args with `?`, in the order of the clauses.
  def search(db, user, filters) do
    clauses =
      Enum.reject(
        [
          access(user, Map.get(filters, :mine, false)),
          query(filters[:query]),
          archived(filters[:archived]),
          project(filters[:project_id]),
          after_(filters[:after])
          | Enum.map(Map.get(filters, :labels, []), &label/1)
        ],
        &is_nil/1
      )

    sql =
      "SELECT #{@columns} FROM records WHERE #{Enum.map_join(clauses, " AND ", &elem(&1, 0))} " <>
        "ORDER BY updated_at DESC, session_id ASC LIMIT ?"

    args = Enum.flat_map(clauses, &elem(&1, 1)) ++ [filters.limit + 1]
    with {:ok, rows} <- all(db, sql, args), do: {:ok, Enum.map(rows, &row/1)}
  end

  defp access(user, true), do: {"owner = ?", [user]}
  defp access(user, false), do: {"(owner = ? OR visibility = 'hub')", [user]}

  # A substring of the title, ASCII case folded: `lower` of SQLite folds
  # ASCII only, and `instr` has no wildcard.
  defp query(nil), do: nil
  defp query(""), do: nil
  defp query(text), do: {"instr(lower(title), lower(?)) > 0", [text]}

  defp archived(nil), do: nil
  defp archived(archived), do: {"archived = ?", [value(:archived, archived)]}

  defp project(nil), do: nil
  defp project(project_id), do: {"project_id = ?", [project_id]}

  defp after_(nil), do: nil

  defp after_({at, id}),
    do: {"(updated_at < ? OR (updated_at = ? AND session_id > ?))", [at, at, id]}

  defp label(label),
    do:
      {"EXISTS (SELECT 1 FROM labels WHERE labels.session_id = records.session_id AND label = ?)",
       [label]}

  # The placeholders of an `IN` list of ids.
  defp marks(ids), do: Enum.map_join(ids, ", ", fn _ -> "?" end)

  # The stored records that `user` may read for `sessions.saved` (decision
  # 7): its own and the "hub" records of others, of the folder `cwd` when
  # given, newest `active_at` first, then by session id, both descending as
  # the list of Core, after the cursor `{time, id}`, at most `limit` rows.
  def saved(db, user, cwd, cursor, limit) do
    clauses = Enum.reject([access(user, false), cwd(cwd), saved_after(cursor)], &is_nil/1)

    sql =
      "SELECT #{@columns} FROM records WHERE #{Enum.map_join(clauses, " AND ", &elem(&1, 0))} " <>
        "ORDER BY active_at DESC, session_id DESC LIMIT ?"

    args = Enum.flat_map(clauses, &elem(&1, 1)) ++ [limit]
    with {:ok, rows} <- all(db, sql, args), do: {:ok, Enum.map(rows, &row/1)}
  end

  defp cwd(nil), do: nil
  defp cwd(cwd), do: {"cwd = ?", [cwd]}

  # A time past the integers of SQLite, which it cannot bind, is past every
  # row: a later one keeps every row, an earlier one none.
  @max_time 2 ** 63 - 1
  @min_time -(2 ** 63)

  defp saved_after(nil), do: nil
  defp saved_after({time, _id}) when time > @max_time, do: nil
  defp saved_after({time, _id}) when time < @min_time, do: {"0 = 1", []}

  defp saved_after({time, id}),
    do: {"(active_at < ? OR (active_at = ? AND session_id < ?))", [time, time, id]}

  # The newest record that `owner` owns of the folder `cwd`.
  def newest(db, owner, cwd) do
    sql =
      "SELECT #{@columns} FROM records WHERE owner = ?1 AND cwd = ?2 " <>
        "ORDER BY active_at DESC, session_id DESC LIMIT 1"

    case one(db, sql, [owner, cwd]) do
      {:ok, nil} -> {:error, :not_found}
      {:ok, row} -> {:ok, row(row)}
      error -> error
    end
  end
end
