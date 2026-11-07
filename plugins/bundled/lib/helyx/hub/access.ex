defmodule Helyx.Hub.Access do
  @moduledoc false
  # The authority of a transport for a Hub (`Helyx.Transport.WebSocket.
  # Authority`, `docs/features/hub.md`, decision 5): `Helyx.Hub.authority/1`
  # gives `{Helyx.Hub.Access, hub}`. Each callback runs in the process of the
  # transport that calls it, and each but `release` makes one Hub call, which
  # first checks the credential: one that no longer holds closes the
  # connection with 4403.

  @behaviour Helyx.Transport.WebSocket.Authority

  alias Helyx.Hub

  # The bound of the `prompt` of a record: the caller cuts the text, so no
  # Hub call carries more of it (Store schema).
  @max_prompt_bytes 1_024

  @read_ops ~w(subscribe history)
  @text_ops ~w(prompt steer follow_up)
  @write_ops ~w(abort set_model compact answer stop)
  @bad_params {:error, "bad_params", "a param is missing, of the wrong type, or unknown"}

  @impl true
  def hello(hub, %{nonce: nonce, token: token_id, proof: proof}) do
    case Hub.call(hub, {:hello, token_id}) do
      {:ok, found} ->
        with {:ok, key} <- key(found),
             true <- proof?(key, nonce, proof),
             do: {:ok, Map.take(found, [:user, :token])},
             else: (_ -> :error)

      :error ->
        # The answer for an unknown id costs the HMAC of a known one, so it
        # does not tell whether the id exists (decision 3).
        _ = proof?(:crypto.strong_rand_bytes(32), nonce, proof)
        :error

      {:error, :busy} ->
        {:error, :busy}
    end
  end

  # The key of a token, or of the server token, which the closure of the
  # option gives and the caller checks: a closure that gives no text proves
  # nothing.
  defp key(%{key: key}), do: {:ok, key}

  defp key(%{server_token: token}) do
    case token.() do
      text when is_binary(text) and text != "" -> {:ok, :crypto.hash(:sha256, text)}
      _ -> :error
    end
  end

  defp proof?(key, nonce, proof) do
    expected = Base.encode64(:crypto.mac(:hmac, :sha256, key, nonce))
    is_binary(proof) and Plug.Crypto.secure_compare(expected, proof)
  end

  @impl true
  def check(hub, auth, "sessions.live", params),
    do: passed(Hub.call(hub, {:credential, auth}), params)

  def check(hub, auth, "start", %{"cwd" => cwd} = params),
    do: passed(Hub.call(hub, {:start, auth, byte_size(cwd)}), params)

  def check(hub, auth, "resume", %{"id" => id} = params),
    do: passed(Hub.call(hub, {:session, auth, :resume, id, {:touch, nil}}), params)

  # The resume of a folder under a Hub (decision 7) is not built yet: it
  # resumes nothing.
  def check(hub, auth, "resume", %{"cwd" => _}),
    do: passed(Hub.call(hub, {:credential, auth}), {:error, "not_found"})

  def check(hub, auth, op, %{"session" => id} = params) when op in @read_ops,
    do: passed(Hub.call(hub, {:session, auth, :read, id, nil}), params)

  def check(hub, auth, op, %{"session" => id, "text" => text} = params) when op in @text_ops,
    do: passed(Hub.call(hub, {:session, auth, :write, id, {:touch, cut(text)}}), params)

  def check(hub, auth, op, %{"session" => id} = params) when op in @write_ops,
    do: passed(Hub.call(hub, {:session, auth, :write, id, nil}), params)

  defp passed(:ok, {:error, _} = refusal), do: refusal
  defp passed(:ok, params), do: {:ok, params}
  defp passed(other, _params), do: refused(other)

  defp refused(:revoked), do: {:close, 4403}
  defp refused({:error, code}), do: {:error, Atom.to_string(code)}

  # The first 1,024 bytes of a text, cut on a UTF-8 boundary: the frame
  # decode of the transport admits only UTF-8.
  defp cut(text) do
    head = binary_part(text, 0, min(byte_size(text), @max_prompt_bytes))
    Enum.find([head | trims(head)], &String.valid?/1)
  end

  defp trims(head) do
    for n <- 1..3, byte_size(head) > n, do: binary_part(head, 0, byte_size(head) - n)
  end

  @impl true
  def run(hub, auth, "hub.me", params) when map_size(params) == 0 do
    case Hub.call(hub, {:me, auth}) do
      {:ok, user} -> {:ok, %{"user" => %{"id" => user.id, "name" => user.name}}}
      other -> error(other)
    end
  end

  def run(hub, auth, "hub.tokens.list", params) when map_size(params) == 0 do
    case Hub.call(hub, {:tokens, auth}) do
      {:ok, tokens} -> {:ok, %{"tokens" => Enum.map(tokens, &token/1)}}
      other -> error(other)
    end
  end

  # A revoke of the token of the connection closes it before the reply
  # (decision 13).
  def run(hub, auth, "hub.tokens.revoke", %{"token" => token_id} = params)
      when map_size(params) == 1 and is_binary(token_id) do
    case Hub.call(hub, {:revoke, auth, token_id}) do
      :ok when token_id == auth.token -> {:close, 4403}
      :ok -> {:ok, %{}}
      other -> error(other)
    end
  end

  # The answers that need no object still check the credential first, so a
  # revoked one closes the connection at its next request.
  def run(hub, auth, op, _params) when op in ~w(hub.me hub.tokens.list hub.tokens.revoke),
    do: after_credential(hub, auth, @bad_params)

  # The page of `sessions.saved` under a Hub (decision 7) is not built yet.
  def run(hub, auth, "sessions.saved", _params),
    do: after_credential(hub, auth, {:error, "failed", "the operation failed"})

  def run(hub, auth, _op, _params),
    do: after_credential(hub, auth, {:error, "unknown_op", "unknown operation"})

  defp after_credential(hub, auth, answer) do
    case Hub.call(hub, {:credential, auth}) do
      :ok -> answer
      other -> error(other)
    end
  end

  defp token(token),
    do: %{"id" => token.id, "name" => token.name, "created_at" => token.created_at}

  defp error(:revoked), do: {:close, 4403}
  defp error({:error, :busy}), do: {:error, "busy", "too many requests in flight"}
  defp error({:error, :timeout}), do: {:error, "timeout", "the operation passed its deadline"}
  defp error({:error, :unknown_token}), do: {:error, "unknown_token", "unknown token"}
  defp error({:error, _}), do: {:error, "failed", "the operation failed"}

  @impl true
  def result(hub, auth, "sessions.live", _params, %{"sessions" => lines} = result) do
    case Hub.call(hub, {:readable, auth, Enum.map(lines, & &1["id"])}) do
      {:ok, ids} ->
        readable = MapSet.new(ids)
        {:ok, %{result | "sessions" => Enum.filter(lines, &(&1["id"] in readable))}}

      other ->
        refused(other)
    end
  end

  def result(hub, auth, "start", params, %{"session" => id} = result) do
    start = %{session_id: id, cwd: params["cwd"], model: Map.get(params, "model")}

    case Hub.call(hub, {:started, auth, start}) do
      :ok -> {:ok, result}
      other -> refused(other)
    end
  end

  def result(hub, auth, "resume", _params, result),
    do: passed(Hub.call(hub, {:credential, auth}), result)

  @impl true
  def release(_hub, _auth, _op, _params), do: :ok
end
