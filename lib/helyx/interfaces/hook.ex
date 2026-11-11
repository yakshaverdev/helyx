defmodule Helyx.Hook do
  # The most ms of a hook at one point (ADR 0013 §3).
  @max_limit_ms 600_000

  @moduledoc """
  A check before and after each Helyx tool call, and before a session
  settles (ADR 0013, `docs/features/hooks.md`,
  `docs/features/before-settle.md`).

  A hook plugin implements the points that it handles, each optional, and
  `limit/1`. Core refuses a hook plugin with no point
  (`{:no_hook_point, module}`). A reason and a text are strings of valid
  UTF-8. The hooks of a point run in the order of the plugin list. A raise,
  a throw, an exit, a hook past its limit, and a return that is not an
  answer of its point is a failed hook.

  Each hook runs in a Task of the hands of its own, with the call's
  context (`Helyx.Tool.context/0`). It holds an OS resource with
  `Helyx.Tool.hold/1` and implements the optional `release/3`, with the
  rules of `Helyx.Tool`. A `before_settle` hook gets the context of a
  call of the ended turn with `tool` and `call_id` nil. Each answer of a
  `before_tool` hook, and each replace, continue, or failure of the other
  points, is a `hook` entry of the session file; a keep and a settle
  change nothing and are not written.
  """

  @type point :: :before_tool | :after_tool | :before_settle
  @type call :: %{
          tool: String.t(),
          arguments: map(),
          cwd: String.t(),
          session_id: String.t(),
          turn_id: String.t(),
          call_id: String.t(),
          provider: String.t() | nil
        }
  @type result :: {:ok | :error, String.t()}
  @type settle :: %{
          session_id: String.t(),
          turn_id: String.t(),
          stop_reason: Helyx.Message.stop_reason(),
          cwd: String.t()
        }

  @doc """
  Before a call runs. A deny ends the chain, and the call does not run. A
  failed hook denies the call.
  """
  @callback before_tool(call()) :: :allow | {:allow, String.t()} | {:deny, String.t()}

  @doc """
  After a call. Each hook gets the result that the hook before it left. A
  failed hook keeps the result, and the session emits a `:notice`.
  """
  @callback after_tool(%{required(:result) => result(), optional(atom()) => term()}) ::
              :keep | {:replace, result()}

  @doc """
  After a turn that ended `done`, not a compaction, before the session
  takes its queues; `cwd` is the session's folder. The first continue ends
  the chain and starts the next turn with `text`, at most the bytes of a
  client text, as a user message whose origin is
  `%{kind: :hook, id: inspect(module)}`. A failed hook is a `:notice`, and
  the chain goes on; with no continue the session settles. At most 8 turns
  in a row start from a continue; a client message resets the count. Core
  refuses a plugin whose name is over the bytes of an origin id
  (`{:invalid_hook_name, module}`).
  """
  @callback before_settle(settle()) :: :settle | {:continue, String.t()}

  @doc """
  The limit of the hook at a point, in ms from 1 to #{@max_limit_ms}. Core
  reads it once at its start; a bad limit refuses the plugin
  (`{:invalid_hook_limit, module}`).
  """
  @callback limit(point()) :: pos_integer()
  @callback release(handles :: [term()], mode :: :deliver | :cancel, deadline :: integer()) ::
              [term()]

  @optional_callbacks before_tool: 1, after_tool: 1, before_settle: 1, release: 3

  @doc false
  def max_limit_ms, do: @max_limit_ms

  @doc false
  # The points: those of a call in the order that its chain runs them,
  # then the one of the session.
  @spec points() :: [point()]
  def points, do: [:before_tool, :after_tool, :before_settle]

  @doc """
  Asks the clients of the session from a hook Task, as `Helyx.Tool.ask/1`
  does from a call Task. Another caller than a hook Task of a running call,
  a `before_settle` hook too, gets `{:error, :not_running}`. The session
  ends the ask with the outcome `:ended` when the hook Task ends, so a hook
  killed at its limit leaves no question open.
  """
  @spec ask(map()) :: {:ok, map()} | {:error, :no_client | :not_running}
  def ask(request), do: Helyx.Session.Ask.ask(:hook, request)
end
