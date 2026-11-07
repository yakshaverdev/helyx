defmodule Helyx.Hub.Store.SQLite.Records do
  @moduledoc false
  # The record queries of the SQLite store (`docs/features/hub.md`, "Store
  # schema", decisions 7 and 8).

  import Helyx.Hub.Store.SQLite.Query

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
    marks = Enum.map_join(1..length(session_ids), ", ", &"?#{&1}")
    sql = "SELECT session_id, owner, visibility FROM records WHERE session_id IN (#{marks})"

    with {:ok, rows} <- all(db, sql, session_ids) do
      {:ok, Map.new(rows, fn [id, owner, vis] -> {id, %{owner: owner, visibility: vis}} end)}
    end
  end

  def count_records(db, owner) do
    with {:ok, [n]} <- one(db, "SELECT count(*) FROM records WHERE owner = ?1", [owner]),
         do: {:ok, n}
  end

  # A new row, unless its owner holds `max` rows.
  def put_record(db, record, max, deadline) do
    transaction(db, deadline, fn ->
      with {:ok, n} <- count_records(db, record.owner), do: insert(db, record, n < max)
    end)
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
end
