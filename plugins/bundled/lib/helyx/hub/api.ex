defmodule Helyx.Hub.Api do
  @moduledoc false
  # The Elixir API of the session for a product and for the coordinator
  # tools (`docs/features/hub.md`, decision 5, Interface changes;
  # `docs/features/coordinator.md`): the `check`, the Core call, and the
  # `result` of the wire, in the caller, for a user with no token. An exit
  # of a Hub call is `:timeout`, as on the wire.

  alias Helyx.Hub.Access
  alias Helyx.Hub.{Params, Subscriptions}

  # The session operations that `authorize/4` checks, with the rules of
  # `Helyx.Hub.Access.check/4`.
  @ops ~w(subscribe history prompt steer follow_up abort set_model compact answer stop)

  def start_session(arg, user_id, opts) do
    auth = %{user: user_id, token: nil}
    params = %{"cwd" => opts[:cwd], "model" => opts[:model]}

    with :ok <- cwd(opts[:cwd]),
         :ok <- answer(safe(fn -> Access.check(arg, auth, "start", params) end)),
         do: core_start(arg, auth, params, opts)
  end

  # The resume of a session as the wire `resume` does, for a user with no
  # token: the place of the live sessions, the Core resume, and the starter
  # (docs/features/idle-unload.md).
  def resume(arg, user_id, session_id) do
    auth = %{user: user_id, token: nil}
    params = %{"id" => session_id}

    with :ok <- answer(safe(fn -> Access.check(arg, auth, "resume", params) end)),
         do: core_resume(arg, auth, params, session_id)
  end

  defp core_resume(arg, auth, params, id) do
    case Helyx.Sessions.resume(arg.core, id: id) do
      {:ok, session} ->
        resumed(arg, auth, params, id, session)

      {:error, reason} ->
        # The place of decision 14 goes back at once.
        _ = safe(fn -> Access.release(arg, auth, "resume", params) end)
        {:error, missing(reason)}
    end
  end

  # A resume whose starter the Hub did not bind stops its session: the
  # caller gets no session that acts for no user.
  defp resumed(arg, auth, params, id, session) do
    case answer(safe(fn -> Access.result(arg, auth, "resume", params, %{"session" => id}) end)) do
      :ok ->
        {:ok, session}

      error ->
        _ = Helyx.Sessions.stop(session)
        _ = safe(fn -> Access.release(arg, auth, "resume", params) end)
        error
    end
  end

  # A file that a resume does not find answers as a missing session in the
  # tests of the coordinator tools, as it does on the wire
  # (`Helyx.Transport.WebSocket.Ops.load/3`).
  defp missing(reason) when reason in [:not_found, :invalid_id], do: :session_not_found
  defp missing(reason), do: reason

  defp core_start(arg, auth, params, opts) do
    case Helyx.Sessions.start(arg.core, opts) do
      {:ok, session} ->
        started(arg, auth, params, session)

      {:error, _} = error ->
        # The place of decision 14 goes back at once.
        _ = safe(fn -> Access.release(arg, auth, "start", params) end)
        error
    end
  end

  # A start whose record the Hub did not write stops its session: the
  # caller gets no id of it, and the default owner would own it.
  defp started(arg, auth, params, session) do
    case answer(
           safe(fn -> Access.result(arg, auth, "start", params, %{"session" => session.id}) end)
         ) do
      :ok ->
        {:ok, session}

      error ->
        _ = Helyx.Sessions.stop(session)
        _ = safe(fn -> Access.release(arg, auth, "start", params) end)
        error
    end
  end

  def authorize(arg, user_id, op, params) when op in @ops,
    do: answer(safe(fn -> Access.check(arg, %{user: user_id, token: nil}, op, params) end))

  def owner(arg, session_id) do
    exists? = Access.exists?(arg, session_id)
    safe(fn -> Helyx.Hub.call(arg.hub, {:owner, session_id, exists?}) end)
  end

  def schedules(arg, user_id, session_id) do
    case safe(fn -> Access.Schedules.rows(arg, %{user: user_id, token: nil}, session_id) end) do
      {:ok, rows} -> {:ok, Enum.map(rows, &Helyx.Hub.Schedules.view/1)}
      other -> revoked(other)
    end
  end

  def delete_schedule(arg, user_id, schedule_id) do
    request = {:schedule_delete, %{user: user_id, token: nil}, schedule_id}
    revoked(safe(fn -> Helyx.Hub.call(arg.hub, request) end))
  end

  # `Helyx.Hub.subscribe/3`: `hub.subscriptions.create` for the user
  # `user_id`, with the same checks in the same order as the wire.
  def subscribe(arg, user_id, params) do
    case Params.check("hub.subscriptions.create", params) do
      {:ok, {id, fields}} -> subscribed(arg, user_id, id, fields)
      code -> {:error, code}
    end
  end

  defp subscribed(arg, user_id, id, fields) do
    request = %{user: user_id, token: nil}

    case revoked(safe(fn -> Access.Subscriptions.create_row(arg, request, id, fields) end)) do
      {:ok, row} ->
        {:ok,
         %{
           subscription: Subscriptions.view(row),
           secret: row.secret,
           path: Subscriptions.path(row)
         }}

      other ->
        other
    end
  end

  # `Helyx.Hub.subscriptions/3`: `hub.subscriptions.list`.
  def subscriptions(arg, user_id, session_id) do
    case revoked(
           safe(fn ->
             Access.Subscriptions.list_rows(arg, %{user: user_id, token: nil}, session_id)
           end)
         ) do
      {:ok, rows} -> {:ok, Enum.map(rows, &Subscriptions.view/1)}
      other -> other
    end
  end

  # `Helyx.Hub.unsubscribe/3`: `hub.subscriptions.delete`.
  def unsubscribe(arg, user_id, subscription_id) do
    request = {:subscription_delete, %{user: user_id, token: nil}, subscription_id}
    revoked(safe(fn -> Helyx.Hub.call(arg.hub, request) end))
  end

  defp revoked(:revoked), do: {:error, :unknown_user}
  defp revoked(other), do: other

  # Core checks the rest of the `cwd` at its start; the record needs a text.
  defp cwd(cwd) when is_binary(cwd), do: :ok
  defp cwd(_cwd), do: {:error, :invalid_cwd}

  defp answer({:ok, _params_or_result}), do: :ok
  defp answer({:close, 4403}), do: {:error, :unknown_user}
  defp answer({:error, code}) when is_binary(code), do: {:error, String.to_existing_atom(code)}
  defp answer({:error, code}) when is_atom(code), do: {:error, code}

  defp safe(fun) do
    fun.()
  catch
    :exit, _reason -> {:error, :timeout}
  end
end
