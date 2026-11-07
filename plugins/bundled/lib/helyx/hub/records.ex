defmodule Helyx.Hub.Records do
  @moduledoc false
  # The record and project operations that the Hub process decides
  # (`docs/features/hub.md`, `hub.records.*`, `hub.projects.*`, decisions 4,
  # 7, 8). The caller checked the params and ran the existence check of
  # decision 8; each request first checks the credential, as `Helyx.Hub.Rules`.

  alias Helyx.Hub.Rules

  # The cap of Bounds.
  @max_projects 256

  # A record that the user may read, stored or derived.
  def handle({:record_get, auth, session_id, found}, _deadline, state) do
    with :ok <- Rules.credential(auth, state),
         {:ok, access} <- Rules.access(session_id, found != nil, state),
         :ok <- Rules.allowed(:read, access, auth.user),
         do: view(session_id, auth.user, state)
  end

  # Only the owner writes; the first update of a derived record writes its
  # row with the `cwd` and `model` that the existence check found.
  def handle({:record_update, auth, session_id, found, changes}, deadline, state) do
    %{store: mod, db: db} = state

    with :ok <- Rules.credential(auth, state),
         {:ok, access} <- Rules.access(session_id, found != nil, state),
         :ok <- Rules.allowed(:write, access, auth.user),
         new = new_row(access, session_id, found, state),
         :ok <- mod.update_record(db, session_id, new, changes, Rules.max_records(), deadline),
         do: view(session_id, auth.user, state)
  end

  def handle({:record_delete, auth, session_id, found}, deadline, %{store: mod, db: db} = state) do
    with :ok <- Rules.credential(auth, state),
         {:ok, access} <- Rules.access(session_id, found != nil, state),
         :ok <- Rules.allowed(:write, access, auth.user) do
      case mod.delete_record(db, session_id, deadline) do
        # A derived record has no row to delete.
        {:error, :not_found} -> :ok
        other -> other
      end
    end
  end

  def handle({:record_search, auth, filters}, _deadline, %{store: mod, db: db} = state) do
    with :ok <- Rules.credential(auth, state),
         :ok <- own_project(auth.user, filters[:project_id], state),
         {:ok, rows} <- mod.search(db, auth.user, filters) do
      {page, more} = Enum.split(rows, filters.limit)
      next = if more != [], do: cursor(List.last(page))

      with {:ok, views} <- views(page, auth.user, state), do: {:ok, views, next}
    end
  end

  def handle({:projects, auth}, _deadline, %{store: mod, db: db} = state) do
    with :ok <- Rules.credential(auth, state), do: mod.projects(db, auth.user)
  end

  def handle({:project_create, auth, name}, deadline, %{store: mod, db: db} = state) do
    project = %{id: new_id(), owner: auth.user, name: name, created_at: System.os_time(:second)}

    with :ok <- Rules.credential(auth, state),
         :ok <- mod.put_project(db, project, @max_projects, deadline),
         do: {:ok, Map.delete(project, :owner)}
  end

  def handle({:project_update, auth, project_id, name}, deadline, %{store: mod, db: db} = state) do
    with :ok <- Rules.credential(auth, state),
         :ok <- mod.rename_project(db, auth.user, project_id, name, deadline) |> unknown(),
         do: mod.project(db, auth.user, project_id)
  end

  def handle({:project_delete, auth, project_id}, deadline, %{store: mod, db: db} = state) do
    with :ok <- Rules.credential(auth, state),
         do: mod.delete_project(db, auth.user, project_id, deadline) |> unknown()
  end

  defp unknown({:error, :not_found}), do: {:error, :unknown_project}
  defp unknown(other), do: other

  defp own_project(_user, nil, _state), do: :ok

  defp own_project(user, project_id, %{store: mod, db: db}) do
    case mod.project(db, user, project_id) do
      {:ok, _project} -> :ok
      error -> unknown(error)
    end
  end

  # The row of a derived record, which its first update writes: its owner
  # is the default owner, its `cwd` and `model` are the ones of the session
  # (decision 8). A stored record has its row.
  defp new_row(%{stored: true}, _session_id, _found, _state), do: nil

  defp new_row(%{stored: false}, session_id, found, state) do
    now = System.os_time(:second)

    %{
      session_id: session_id,
      owner: state.default_owner_id,
      cwd: found.cwd,
      model: found.model,
      prompt: "",
      active_at: now,
      created_at: now
    }
  end

  defp cursor(row), do: "#{row.updated_at}:#{row.session_id}"

  defp view(session_id, user, %{store: mod, db: db} = state) do
    case mod.record(db, session_id) do
      {:ok, row} -> with {:ok, [view]} <- views([row], user, state), do: {:ok, view}
      {:error, :not_found} -> derived_view(session_id, state)
      error -> error
    end
  end

  # A record as the wire shows it: the project only for its owner.
  defp views(rows, user, %{store: mod, db: db}) do
    with {:ok, labels} <- mod.labels(db, Enum.map(rows, & &1.session_id)),
         {:ok, users} <- mod.users(db) do
      names = Map.new(users, &{&1.id, &1.name})

      {:ok,
       Enum.map(rows, fn row ->
         %{
           session: row.session_id,
           owner: %{id: row.owner, name: Map.fetch!(names, row.owner)},
           project: if(row.owner == user, do: row.project_id),
           title: row.title,
           labels: Map.get(labels, row.session_id, []),
           visibility: row.visibility,
           archived: row.archived,
           stored: true,
           created_at: row.created_at,
           updated_at: row.updated_at
         }
       end)}
    end
  end

  defp derived_view(session_id, %{store: mod, db: db} = state) do
    with {:ok, owner} <- mod.user(db, state.default_owner_id) do
      {:ok,
       %{
         session: session_id,
         owner: Map.take(owner, [:id, :name]),
         project: nil,
         title: "",
         labels: [],
         visibility: "private",
         archived: false,
         stored: false,
         created_at: nil,
         updated_at: nil
       }}
    end
  end

  defp new_id, do: Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)
end
