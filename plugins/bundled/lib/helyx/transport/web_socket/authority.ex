defmodule Helyx.Transport.WebSocket.Authority do
  @moduledoc """
  The authority of the connections of `Helyx.Transport.WebSocket`: who a
  connection is, and what it may do (`docs/features/hub.md`, decision 5).
  A product gives it with the option `authority: {module, arg}`;
  `Helyx.Hub.authority/1` gives the value for a Hub. The transport names no
  Hub module.

  Each callback runs in the process of the transport that calls it.
  `{:close, 4403}` from a callback closes the connection with that code in
  place of a reply.
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
  The credential of a connection, in the connection process. `:error`
  closes with `4401`; `{:error, :busy}` and an exit close with `4503`.
  """
  @callback hello(arg(), hello()) :: {:ok, auth()} | :error | {:error, :busy}

  @doc """
  The access of a request or a subscription, after the transport checked
  its params, in the worker of the request or in the subscription process.
  The Core call then runs within the deadline of the operation.
  `{:ok, params}` can give other params of the same operation. An exit
  answers as a `timeout`.
  """
  @callback check(arg(), auth(), op :: String.t(), params :: map()) ::
              {:ok, map()} | {:error, code()} | {:close, 4403}

  @doc """
  Runs an operation of the authority, `hub.*` and `sessions.saved`, in the
  worker, with no `check`: it decides the access itself, within the
  deadline of the operation (15,000 ms for `sessions.saved`). An exit
  answers as a `timeout`.
  """
  @callback run(arg(), auth(), op :: String.t(), params :: map()) ::
              {:ok, map()} | {:error, code(), text :: String.t()} | {:close, 4403}

  @doc """
  Filters or records the result of `sessions.live`, `start`, or `resume`,
  in the worker after the Core call, with no deadline of the transport. An
  exit answers as a `timeout`.
  """
  @callback result(arg(), auth(), op :: String.t(), params :: map(), result :: map()) ::
              {:ok, map()} | {:error, code()} | {:close, 4403}

  @doc """
  A `start` or `resume` that `check` passed failed or exited in its Core
  call. Runs in the worker; an exit leaves the answer of the Core call.
  """
  @callback release(arg(), auth(), op :: String.t(), params :: map()) :: :ok

  @doc """
  The load of a session that a text operation, `prompt`, `steer`, or
  `follow_up`, addresses, in the worker before the deadline of the
  operation: `:ok` when the session runs or its load succeeded, else the
  error of the operation, shaped as `check/4` gives it. A session that a
  stop unloaded resumes through the authority, so the place of the user and
  the starter hold as at a wire `resume` (`docs/features/idle-unload.md`).
  An authority that does not export it gets the resume of
  `Helyx.Transport.WebSocket.Ops.load/3`.
  """
  @callback load(arg(), auth(), op :: String.t(), params :: map()) ::
              :ok | {:error, code()} | {:close, 4403}

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

  @optional_callbacks webhook: 3, load: 4
end
