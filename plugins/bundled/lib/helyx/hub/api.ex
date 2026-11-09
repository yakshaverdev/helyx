defmodule Helyx.Hub.Api do
  @moduledoc false
  # The Elixir API of the session for a product and for the coordinator
  # tools (`docs/features/hub.md`, decision 5, Interface changes;
  # `docs/features/coordinator.md`): the `check`, the Core call, and the
  # `result` of the wire, in the caller, for a user with no token. An exit
  # of a Hub call is `:timeout`, as on the wire.

  alias Helyx.Hub.Access

  # The session operations that `authorize/4` checks, with the rules of
  # `Helyx.Hub.Access.check/4`.
  @ops ~w(subscribe history prompt steer follow_up abort set_model compact answer stop)

  def start_session(arg, user_id, opts) do
    auth = %{user: user_id, token: nil}
    params = %{"cwd" => opts[:cwd], "model" => opts[:model]}

    with :ok <- cwd(opts[:cwd]),
         :ok <- answer(safe(fn -> Access.check(arg, auth, "start", params) end)) do
      case Helyx.Sessions.start(arg.core, opts) do
        {:ok, session} ->
          started(arg, auth, params, session)

        {:error, _} = error ->
          # The place of decision 14 goes back at once.
          _ = safe(fn -> Access.release(arg, auth, "start", params) end)
          error
      end
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
