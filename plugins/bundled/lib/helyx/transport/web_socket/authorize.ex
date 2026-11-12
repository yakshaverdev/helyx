defmodule Helyx.Transport.WebSocket.Authorize do
  @moduledoc false
  # The calls of the authority of a transport (`Helyx.Transport.WebSocket.
  # Authority`, `docs/features/hub.md`, decision 5): the `hello` in the
  # connection, and the request of a worker with its `check`, its Core call
  # or `run`, and its `result` or `release`. A callback that exits answers
  # as a timeout; a `{:close, 4403}` closes the connection in place of the
  # reply.

  alias Helyx.Transport.WebSocket.{Ops, Outbound}

  # The bound of the `token` field of a `hello`: an id (the frame rule).
  @max_token_bytes 64

  # `{:ok, auth}`, or the close code of the connection.
  def hello({mod, arg}, nonce, hello) do
    with {:ok, token} <- field(hello["token"]),
         {:ok, proof} <- field(hello["proof"]) do
      fields = %{nonce: nonce, token: token, proof: proof, connection: self()}

      case mod.hello(arg, fields) do
        {:ok, auth} -> {:ok, auth}
        :error -> {:close, 4401}
        {:error, :busy} -> {:close, 4503}
      end
    end
  catch
    :exit, _reason -> {:close, 4503}
  end

  defp field(nil), do: {:ok, nil}

  defp field(value) when is_binary(value) and byte_size(value) in 1..@max_token_bytes,
    do: {:ok, value}

  # One bound for both fields: a token id has 12 characters and a proof 44,
  # so a field over 64 bytes is neither.
  defp field(_value), do: {:close, 4401}

  # The proof of the server token: the base64 HMAC-SHA256 of the nonce with
  # the key, the SHA-256 of the token. A server with no token takes any
  # proof.
  @doc false
  @spec proof?((-> binary()) | nil, binary(), term()) :: boolean()
  def proof?(nil, _nonce, _given), do: true

  def proof?(key, nonce, given) when is_binary(given) do
    proof = Base.encode64(:crypto.mac(:hmac, :sha256, key.(), nonce))
    Plug.Crypto.secure_compare(proof, given)
  end

  def proof?(_key, _nonce, _given), do: false

  # The worker of a request under an authority, or the error of its params.
  # The transport checks the params of an op of Core before `check`; the
  # authority checks those of its own ops in `run`.
  def worker(conn, out, id, op, params, %{core: core, authority: authority, auth: auth}) do
    if Ops.run?(op) do
      {:ok, fn -> run(conn, out, id, op, params, authority, auth) end}
    else
      with {:ok, _call} <- Ops.check(core, op, params),
           do: {:ok, fn -> checked(conn, out, id, op, params, core, authority, auth) end}
    end
  end

  defp run(conn, out, id, op, params, {mod, arg}, auth) do
    within(conn, out, id, op, fn ->
      answer(out, id, op, call(fn -> mod.run(arg, auth, op, params) end))
    end)
  end

  defp checked(conn, out, id, op, params, core, {mod, arg} = authority, auth) do
    case call(fn -> mod.check(arg, auth, op, params) end) do
      {:ok, params} ->
        # The params of the authority are params of the op that the
        # transport checked; one that is not ends the worker: `failed`.
        {:ok, call} = Ops.check(core, op, params, loader(core, op, params, authority, auth))

        # A text op loads a session that a stop unloaded before its deadline
        # (docs/features/idle-unload.md).
        case load(core, op, params, authority, auth) do
          :ok -> loaded(conn, out, id, op, params, call, authority, auth)
          error -> answer(out, id, op, error)
        end

      other ->
        answer(out, id, op, other)
    end
  end

  # The authority loads the session through its own resume when it exports
  # `load/4`, so the place of the user and the starter hold under a Hub; else
  # the Core resume (`Ops.load/3`). The sender uses the same load when the
  # session stops while the text is in flight (`Helyx.Send`).
  defp load(core, op, params, {mod, arg}, auth) do
    if function_exported?(mod, :load, 4),
      do: call(fn -> mod.load(arg, auth, op, params) end),
      else: Ops.load(core, op, params)
  end

  # The load as the sender of a text op calls it, with the session that the
  # send addresses, in the shape of the wire. The one shape of both loaders:
  # a function of one session (`Helyx.Send`).
  defp loader(core, op, params, authority, auth) do
    fn session ->
      case load(core, op, params, authority, auth) do
        :ok -> {:ok, session}
        {:error, code, text} -> {:error, code, text}
        {:error, code} -> Ops.error(op, code)
        {:close, 4403} -> Outbound.error("failed")
      end
    end
  end

  # The Core call of an op whose load succeeded, within the deadline of the op.
  defp loaded(conn, out, id, op, params, call, authority, auth) do
    result = within(conn, out, id, op, fn -> core_call(op, params, call, authority, auth) end)
    reply(out, id, op, params, result, authority, auth)
  end

  # The deadline of the op ends with its Core call: `result` has its own
  # bound beside it. A start or resume whose Core call fails, or exits,
  # gives its reserved place back.
  defp core_call(op, params, call, authority, auth) do
    Ops.run(call)
  catch
    kind, reason ->
      if Ops.release?(op), do: release(op, params, authority, auth)
      :erlang.raise(kind, reason, __STACKTRACE__)
  end

  # The result of an op that the authority answers goes to its `result/5`;
  # an op that reserves a place frees it when its Core call fails.
  defp reply(out, id, op, params, {:ok, result} = ok, {mod, arg} = authority, auth) do
    if Ops.result?(op),
      do: answer(out, id, op, call(fn -> mod.result(arg, auth, op, params, result) end)),
      else: plain_reply(out, id, op, params, ok, authority, auth)
  end

  defp reply(out, id, op, params, result, authority, auth),
    do: plain_reply(out, id, op, params, result, authority, auth)

  defp plain_reply(out, id, op, params, result, authority, auth) do
    if Ops.release?(op), do: release(op, params, authority, auth)
    Outbound.reply(out, id, result)
  end

  defp release(op, params, {mod, arg}, auth),
    do: call(fn -> mod.release(arg, auth, op, params) end)

  # The access of a subscribe, in the subscription process: the session and
  # options of the params that `check` gave, or the answer that the
  # subscription gives in place of its Core call.
  def subscribe({{mod, arg}, auth}, core, params) do
    case call(fn -> mod.check(arg, auth, "subscribe", params) end) do
      {:ok, params} ->
        {:ok, session, opts} = Ops.subscribe_params(core, params)
        {:ok, session, opts}

      other ->
        other
    end
  end

  # The reply of an answer of the authority.
  def answer(out, id, op, answer) do
    case answer do
      {:ok, _result} -> Outbound.reply(out, id, answer)
      {:error, _code, _text} -> Outbound.reply(out, id, answer)
      {:error, code} -> Outbound.reply(out, id, Ops.error(op, code))
      {:close, 4403} -> Outbound.close(out, 4403)
      :timeout -> Outbound.reply(out, id, Outbound.error("timeout"))
    end
  end

  # The deadline of an operation starts after its `check`.
  defp within(conn, out, id, op, body),
    do: Ops.within(conn, out, id, op, Ops.deadline(op, true), body)

  defp call(fun) do
    fun.()
  catch
    :exit, _reason -> :timeout
  end
end
