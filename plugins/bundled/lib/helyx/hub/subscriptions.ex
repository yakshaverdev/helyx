defmodule Helyx.Hub.Subscriptions do
  @moduledoc false
  # The event subscription operations that the Hub process decides
  # (`docs/features/hub.md`, decision 17): `hub.subscriptions.create`,
  # `hub.subscriptions.list`, and `hub.subscriptions.delete`. The caller
  # checked the params and ran the existence check of decision 8; each
  # request first checks the credential, as `Helyx.Hub.Rules`.
  #
  # The secret leaves the Hub process only twice: once as the text of the
  # create reply, and then into `Helyx.Hub.Webhook`, which computes the HMAC
  # of a payload with it. No listing and no log carries it.

  alias Helyx.Hub.Rules

  # The caps of Bounds.
  @per_session 16
  @per_user 256

  # A subscription of a session that the user owns.
  def handle({:subscription_create, auth, session_id, exists?, fields}, deadline, state) do
    %{store: mod, db: db} = state

    with :ok <- Rules.credential(auth, state),
         {:ok, access} <- Rules.access(session_id, exists?, state),
         :ok <- Rules.allowed(:write, access, auth.user) do
      row = %{
        id: Helyx.Hub.Schedules.new_id(),
        owner: auth.user,
        session_id: session_id,
        template: fields.template,
        label: fields.label,
        secret: secret(),
        created_at: System.os_time(:second),
        last_at: nil,
        last_outcome: nil
      }

      with :ok <- mod.put_subscription(db, row, @per_session, @per_user, deadline),
           do: {:ok, Map.put(row, :pending, false)}
    end
  end

  # The subscriptions of the user; of one session only when the user may
  # read it.
  def handle({:subscription_list, auth, nil, _exists?}, _deadline, %{store: mod, db: db} = state) do
    with :ok <- Rules.credential(auth, state), do: mod.subscriptions(db, auth.user, nil)
  end

  def handle({:subscription_list, auth, session_id, exists?}, _deadline, state) do
    %{store: mod, db: db} = state

    with :ok <- Rules.credential(auth, state),
         {:ok, access} <- Rules.access(session_id, exists?, state),
         :ok <- Rules.allowed(:read, access, auth.user),
         do: mod.subscriptions(db, auth.user, session_id)
  end

  def handle({:subscription_delete, auth, id}, deadline, %{store: mod, db: db} = state) do
    with :ok <- Rules.credential(auth, state) do
      case mod.delete_subscription(db, auth.user, id, deadline) do
        {:error, :not_found} -> {:error, :unknown_subscription}
        other -> other
      end
    end
  end

  # A subscription as the API shows it: no secret (decision 17).
  def view(row) do
    %{
      id: row.id,
      session: row.session_id,
      label: row.label,
      template: row.template,
      created_at: row.created_at,
      pending: row.pending,
      last_at: row.last_at,
      last_outcome: row.last_outcome
    }
  end

  # The endpoint path of a subscription: the id is the path.
  def path(row), do: "/hooks/" <> row.id

  # The secret of a new subscription: 43 characters, the base64url of 32
  # random bytes with no padding. The sender signs with this text; the store
  # keeps it.
  defp secret, do: Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
end
