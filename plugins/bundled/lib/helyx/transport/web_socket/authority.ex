defmodule Helyx.Transport.WebSocket.Authority do
  @moduledoc """
  The authority of the connections of `Helyx.Transport.WebSocket`: who a
  connection is, and what it may do (`docs/features/hub.md`, decision 5).
  A product gives it with the option `authority: {module, arg}`;
  `Helyx.Hub.authority/1` gives the value for a Hub. The transport names no
  Hub module.

  Each callback runs in the process of the transport that calls it: `hello`
  in the connection, `check` in the worker of a request or in the
  subscription process, `run`, `result`, and `release` in the worker. An
  exit of `check`, `run`, or `result` answers as a `timeout` of the
  operation, and of `hello` closes with `4503`; an exit of `release` leaves
  the answer of the Core call.

  The order of a request: the transport checks the params, then `check`
  decides the access, then the Core call runs within the deadline of the
  operation, then `result` for `sessions.live`, `start`, and `resume`, with
  no deadline of the transport. An operation whose name starts with `hub.`,
  and `sessions.saved`, go to `run` with no `check`: the authority decides
  the access in it, within the deadline of the operation (15,000 ms for
  `sessions.saved`). `release` follows a `start` or `resume` that `check`
  passed and whose Core call failed or exited. `{:close, 4403}`
  from a callback closes the connection with that code in place of a reply.
  """

  @typedoc "The second element of the `:authority` option."
  @type arg :: term()

  @typedoc "The credential of a connection that `hello/2` returned, opaque to the transport."
  @type auth :: term()

  @typedoc """
  The `hello` of a connection: the nonce of its challenge, the `token` and
  `proof` fields of the frame (each nil when absent), and the connection pid.
  """
  @type hello :: %{
          nonce: binary(),
          token: String.t() | nil,
          proof: String.t() | nil,
          connection: pid()
        }

  @typedoc "A wire error code, such as `\"session_not_found\"`."
  @type code :: String.t()

  @doc """
  The credential of a connection. `:error` closes with `4401`; `{:error,
  :busy}` and an exit close with `4503`.
  """
  @callback hello(arg(), hello()) :: {:ok, auth()} | :error | {:error, :busy}

  @doc """
  The access of a request or a subscription, after the transport checked
  its params. `{:ok, params}` can give other params of the same operation.
  """
  @callback check(arg(), auth(), op :: String.t(), params :: map()) ::
              {:ok, map()} | {:error, code()} | {:close, 4403}

  @doc "Runs an operation of the authority: `hub.*` and `sessions.saved`."
  @callback run(arg(), auth(), op :: String.t(), params :: map()) ::
              {:ok, map()} | {:error, code(), text :: String.t()} | {:close, 4403}

  @doc "Filters or records the result of `sessions.live`, `start`, or `resume`."
  @callback result(arg(), auth(), op :: String.t(), params :: map(), result :: map()) ::
              {:ok, map()} | {:error, code()} | {:close, 4403}

  @doc "A `start` or `resume` that `check` passed failed or exited."
  @callback release(arg(), auth(), op :: String.t(), params :: map()) :: :ok

  @doc """
  A request of the webhook path of the transport, `POST /hooks/<id>`
  (`docs/features/hub.md`, decision 17). The transport read the body within
  its bound and checked nothing else: `id` is the path segment, `headers`
  the request headers with lower-case names, and `body` the raw bytes. The
  answer is the HTTP status and the body of the response. A transport whose
  authority does not export this callback answers 404 on the path.
  """
  @callback webhook(arg(), id :: String.t(), %{
              headers: [{String.t(), String.t()}],
              body: binary()
            }) ::
              {:ok, status :: 200..599, body :: String.t()}

  @optional_callbacks webhook: 3
end
