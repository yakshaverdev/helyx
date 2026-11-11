defmodule Helyx.Hub.Store.SQLite.Projects do
  @moduledoc false
  # The project queries of the SQLite store (`docs/features/hub.md`, "Store
  # schema", `hub.projects.*`). A project belongs to its owner: a project id
  # of another user answers as a missing one.

  import Helyx.Hub.Store.SQLite.Query

  alias Helyx.Hub.Store.SQLite.Tables

  @select Tables.select_sql(:projects)

  def projects(db, owner) do
    with {:ok, rows} <- all(db, @select <> " WHERE owner = ?1 ORDER BY name", [owner]),
         do: {:ok, Enum.map(rows, &row/1)}
  end

  defp row(values), do: Tables.row(:projects, values)

  # A new project, unless its owner holds `max` or has one of that name.
  def put_project(db, project, max, deadline) do
    transaction(db, deadline, fn ->
      with {:ok, [count, taken]} <- counts(db, project.owner, project.name),
           do: insert(db, project, count < max, taken == 0)
    end)
  end

  defp counts(db, owner, name) do
    one(
      db,
      "SELECT count(*), count(*) FILTER (WHERE name = ?2) FROM projects WHERE owner = ?1",
      [owner, name]
    )
  end

  defp insert(_db, _project, false = _room, _free), do: {:error, :too_many_projects}
  defp insert(_db, _project, true, false = _free), do: {:error, :name_taken}

  defp insert(db, p, true, true),
    do: run(db, Tables.insert(:projects), [p.id, p.owner, p.name, p.created_at])

  # A new name, unless another project of the owner has it.
  def rename_project(db, owner, project_id, name, deadline) do
    args = [owner, project_id, name]
    taken = "SELECT count(*) FROM projects WHERE owner = ?1 AND id != ?2 AND name = ?3"

    transaction(db, deadline, fn ->
      with {:ok, [n]} <- one(db, taken, args),
           :ok <- free(n),
           :ok <- run(db, "UPDATE projects SET name = ?3 WHERE owner = ?1 AND id = ?2", args),
           do: changed(db)
    end)
  end

  defp free(0), do: :ok
  defp free(_taken), do: {:error, :name_taken}

  # The records of the project lose it (`ON DELETE SET NULL`).
  def delete_project(db, owner, project_id, deadline) do
    sql = "DELETE FROM projects WHERE owner = ?1 AND id = ?2"
    delete(db, deadline, sql, [owner, project_id])
  end

  # The project row of `project_id` when `owner` owns it.
  def project(db, owner, project_id) do
    case one(db, @select <> " WHERE owner = ?1 AND id = ?2", [owner, project_id]) do
      {:ok, nil} -> {:error, :not_found}
      {:ok, row} -> {:ok, row(row)}
      error -> error
    end
  end
end
