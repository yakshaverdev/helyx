defmodule Helyx.Hub.Schedules do
  @moduledoc false
  # The `hub.schedules.*` operations that the Hub process decides
  # (`docs/features/hub.md`, decision 11). The caller checked the params and
  # ran the existence check of decision 8; each request first checks the
  # credential, as `Helyx.Hub.Rules`.

  alias Helyx.Hub.Rules

  # The caps of Bounds.
  @per_session 16
  @per_user 256

  # A schedule of a session that the user owns; its first pending wake-up
  # is due at `at` (decision 12).
  def handle({:schedule_create, auth, session_id, exists?, fields}, deadline, state) do
    %{store: mod, db: db} = state

    with :ok <- Rules.credential(auth, state),
         {:ok, access} <- Rules.access(session_id, exists?, state),
         :ok <- Rules.allowed(:write, access, auth.user) do
      row = %{
        id: new_id(),
        owner: auth.user,
        session_id: session_id,
        prompt: fields.prompt,
        at: fields.at,
        every: fields.every,
        run: 0,
        delivery_id: new_id(),
        due_at: fields.at,
        next_try_at: fields.at,
        last_at: nil,
        last_outcome: nil,
        created_at: System.os_time(:second),
        subscription_id: nil
      }

      with :ok <- mod.put_schedule(db, row, @per_session, @per_user, deadline), do: {:ok, row}
    end
  end

  # The schedules of the user; of one session only when the user may read it.
  def handle({:schedule_list, auth, nil, _exists?}, _deadline, %{store: mod, db: db} = state) do
    with :ok <- Rules.credential(auth, state), do: mod.schedules(db, auth.user, nil)
  end

  def handle({:schedule_list, auth, session_id, exists?}, _deadline, state) do
    %{store: mod, db: db} = state

    with :ok <- Rules.credential(auth, state),
         {:ok, access} <- Rules.access(session_id, exists?, state),
         :ok <- Rules.allowed(:read, access, auth.user),
         do: mod.schedules(db, auth.user, session_id)
  end

  def handle({:schedule_delete, auth, id}, deadline, %{store: mod, db: db} = state) do
    with :ok <- Rules.credential(auth, state) do
      case mod.delete_schedule(db, auth.user, id, deadline) do
        {:error, :not_found} -> {:error, :unknown_schedule}
        other -> other
      end
    end
  end

  # A schedule as the API shows it: `pending` while the row holds a pending
  # wake-up; its delivery id is not shown (decision 12).
  def view(row) do
    %{
      id: row.id,
      session: row.session_id,
      at: row.at,
      every: row.every,
      prompt: row.prompt,
      pending: row.delivery_id != nil,
      last_at: row.last_at,
      last_outcome: row.last_outcome
    }
  end

  # A random id of 12 characters: a schedule id, and the delivery id of a
  # pending wake-up, which names no schedule and no run (decision 12).
  def new_id, do: Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)
end
