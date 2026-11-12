defmodule Helyx.Hub.Records do
  @moduledoc false
  # The record and project operations that the Hub process decides
  # (`docs/features/hub.md`, `hub.records.*`, `hub.projects.*`, decisions 4,
  # 7, 8). The caller checked the params and ran the existence check of
  # decision 8; each request first checks the credential, as `Helyx.Hub.Rules`.

  alias Helyx.Hub.Live, as: HubLive
  alias Helyx.Hub.{Params, Rules}
  alias Helyx.Session.File.Scan.Summary
  alias Helyx.Sessions.Live

  # The cap of Bounds.
  @max_projects 256

  # A record that the user may read. An id that the existence check found
  # gets its row first, so the default owner reads it as a stored record.
  def handle({:record_get, auth, session_id, found}, deadline, state) do
    with :ok <- Rules.credential(auth, state),
         :ok <- ensure(session_id, found, deadline, state),
         {:ok, access} <- Rules.access(session_id, found != nil, state),
         :ok <- Rules.allowed(:read, access, auth.user),
         do: row_view(session_id, auth.user, state)
  end

  # Only the owner writes; the row of a session that the existence check
  # found comes before the change.
  def handle({:record_update, auth, session_id, found, changes}, deadline, state) do
    %{store: mod, db: db} = state

    with :ok <- Rules.credential(auth, state),
         :ok <- ensure(session_id, found, deadline, state),
         {:ok, access} <- Rules.access(session_id, found != nil, state),
         :ok <- Rules.allowed(:write, access, auth.user),
         :ok <- mod.update_record(db, session_id, changes, deadline),
         do: row_view(session_id, auth.user, state)
  end

  def handle({:record_delete, auth, session_id, found}, deadline, %{store: mod, db: db} = state) do
    with :ok <- Rules.credential(auth, state),
         {:ok, access} <- Rules.access(session_id, found != nil, state),
         :ok <- Rules.allowed(:write, access, auth.user) do
      case mod.delete_record(db, session_id, deadline) do
        # A session that the feed never saw has no row to delete.
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

  # The records that the user may read, at most `limit` + 1 after the cursor.
  # The scan of the default owner writes the rows of the files that have
  # none before the page reads them, so one source gives the page
  # (decision 7).
  def handle({:saved, auth, cwd, cursor, limit, scanned}, deadline, state) do
    %{store: mod, db: db} = state

    with :ok <- Rules.credential(auth, state),
         :ok <- ensure_scan(scanned, auth.user, deadline, state) do
      mod.saved(db, auth.user, cwd, cursor, limit + 1)
    end
  end

  # The session of the `resume` of a folder (decision 7): the newest record
  # of the folder that the user owns, after the scan of the default owner
  # has written the rows of its files that have none.
  def handle({:newest, auth, cwd, scanned}, deadline, %{store: mod, db: db} = state) do
    with :ok <- Rules.credential(auth, state),
         :ok <- ensure_scan(scanned, auth.user, deadline, state),
         {:ok, row} <- mod.newest(db, auth.user, cwd),
         do: {:ok, row.session_id}
  end

  def handle({:projects, auth}, _deadline, %{store: mod, db: db} = state) do
    with :ok <- Rules.credential(auth, state), do: mod.projects(db, auth.user)
  end

  def handle({:project_create, auth, name}, deadline, %{store: mod, db: db} = state) do
    project = %{
      id: Helyx.Hub.Schedules.new_id(),
      owner: auth.user,
      name: name,
      created_at: System.os_time(:second)
    }

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

  # A Live of the feed writes the row of its session, or moves the model and
  # `active_at` of the row it has (decision 8). A write that fails is dropped:
  # the repair path writes the row the next time Hub sees the session. A
  # parent link goes in a new row only. The result lets the records feed send
  # a change only after a write that took.
  def seen(%Live{} = live, deadline, %{store: mod, db: db} = state) do
    if Params.record_fields?(live.cwd, live.model) do
      now = System.os_time(:second)

      mod.seen_record(
        db,
        Map.merge(
          %{
            session_id: live.id,
            owner: state.default_owner_id,
            cwd: live.cwd,
            model: live.model,
            prompt: "",
            active_at: now,
            created_at: now
          },
          parent(live.parent)
        ),
        deadline
      )
    else
      :ok
    end
  end

  # The row of a session that the existence check found, which Hub writes the
  # first time it sees the session with a `cwd` and a model that a record
  # holds (decision 8). A write that fails leaves no row, and the next get or
  # update writes it.
  defp ensure(_session_id, nil, _deadline, _state), do: :ok

  defp ensure(session_id, found, deadline, %{store: mod, db: db} = state) do
    if Params.record_fields?(found.cwd, found.model) and
         mod.record(db, session_id) == {:error, :not_found} do
      now = System.os_time(:second)

      record =
        Map.merge(
          %{
            session_id: session_id,
            owner: state.default_owner_id,
            cwd: found.cwd,
            model: found.model,
            prompt: "",
            active_at: now,
            created_at: now
          },
          parent(Map.get(found, :parent))
        )

      _ = mod.ensure_records(db, [record], deadline)
    end

    :ok
  end

  # The columns of the parent link: both, or neither, so the pair rule of the
  # store holds (hub.md, "Store schema").
  defp parent(nil), do: %{parent_id: nil, parent_kind: nil}
  defp parent(%{session_id: id}), do: %{parent_id: id, parent_kind: "child"}

  # The files of the scan of Core, for the default owner only, become rows
  # before the page reads them (decision 8). Each file gives its own prompt
  # and `mtime`; a session that has a row keeps it. The scan bounds the list
  # to 256 files, and a page with no file writes nothing.
  defp ensure_scan(summaries, user, deadline, %{default_owner_id: user} = state) do
    rows =
      for %Summary{} = summary <- summaries,
          Params.record_fields?(summary.cwd, summary.model) do
        %{
          session_id: summary.id,
          owner: user,
          cwd: summary.cwd,
          model: summary.model,
          prompt: Params.cut(summary.prompt),
          active_at: summary.mtime,
          created_at: summary.mtime
        }
      end

    if rows == [], do: :ok, else: ensure_rows(rows, deadline, state)
  end

  defp ensure_scan(_summaries, _user, _deadline, _state), do: :ok

  defp ensure_rows(rows, deadline, %{store: mod, db: db}) do
    _ = mod.ensure_records(db, rows, deadline)
    :ok
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

  defp cursor(row), do: "#{row.updated_at}:#{row.session_id}"

  # The record of the session. A found session whose row the store did not
  # write, because the write failed or passed its deadline, answers
  # `failed`: the record no longer has a `stored` field to tell a stored row
  # from one the store does not hold, so it does not answer a record that it
  # cannot read back (decision 8).
  defp row_view(session_id, user, %{store: mod, db: db} = state) do
    case mod.record(db, session_id) do
      {:ok, row} -> with {:ok, [view]} <- views([row], user, state), do: {:ok, view}
      {:error, :not_found} -> {:error, :failed}
      error -> error
    end
  end

  # A record as the wire shows it: the project only for its owner, and the
  # status derived from the live set, never stored (decision 8;
  # live-records.md).
  @doc false
  def views(rows, user, %{store: mod, db: db} = state) do
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
           created_at: row.created_at,
           updated_at: row.updated_at,
           cwd: row.cwd,
           model: row.model,
           prompt: row.prompt,
           active_at: row.active_at,
           parent: parent_link(row),
           status: HubLive.status(state, row.session_id)
         }
       end)}
    end
  end

  @doc false
  # One row as the wire shows it, for a change of the records feed.
  def view(row, user, state) do
    with {:ok, [view]} <- views([row], user, state), do: {:ok, view}
  end

  @doc false
  # A record of `views/3` as the wire shows it. The one shape for
  # `hub.records.*` and the records feed.
  def wire(view) do
    %{
      "session" => view.session,
      "owner" => %{"id" => view.owner.id, "name" => view.owner.name},
      "project" => view.project,
      "title" => view.title,
      "labels" => view.labels,
      "visibility" => view.visibility,
      "archived" => view.archived,
      "created_at" => view.created_at,
      "updated_at" => view.updated_at,
      "cwd" => view.cwd,
      "model" => view.model,
      "prompt" => view.prompt,
      "active_at" => view.active_at,
      "parent" => wire_parent(view.parent),
      "status" => view.status
    }
  end

  # The parent link of a record as the wire shows it: the session and the
  # kind of the link, or null.
  defp wire_parent(nil), do: nil
  defp wire_parent({session, kind}), do: %{"session" => session, "kind" => kind}

  defp parent_link(%{parent_id: nil}), do: nil
  defp parent_link(%{parent_id: id, parent_kind: kind}), do: {id, kind}
end
