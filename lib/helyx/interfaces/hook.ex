defmodule Helyx.Hook do
  # The most ms of a hook at one point (ADR 0013 §3).
  @max_limit_ms 600_000

  @moduledoc """
  A check before and after each Helyx tool call, and before a session
  settles (ADR 0013, `docs/features/hooks.md`,
  `docs/features/before-settle.md`).

  A hook plugin implements the points that it handles, each optional:
  `before_tool/1` answers `:allow`, `{:allow, reason}`, or `{:deny,
  reason}`; `after_tool/1` answers `:keep` or `{:replace, {:ok | :error,
  text}}`; `before_settle/1` answers `:settle` or `{:continue, text}`. A
  reason and a text are strings of valid UTF-8, and the text of a continue
  is at most the bytes of a client text. `limit/1`
  gives the limit of the hook at a point, an integer of ms from 1 to
  #{@max_limit_ms}. Core checks it once at its start, and refuses a hook plugin
  with no point (`{:no_hook_point, module}`), a bad limit
  (`{:invalid_hook_limit, module}`), and a `before_settle/1` plugin whose
  name is over the bytes of an origin id (`{:invalid_hook_name, module}`).

  The hooks of a point run in the order of the plugin list. A deny ends
  the `before_tool` chain, and the call does not run; each `after_tool`
  hook gets the result that the hook before it left. A raise, a throw, an
  exit, a hook past its limit, and a return that is not an answer of its
  point is a failed hook: `before_tool` denies the call, `after_tool`
  keeps the result and the session emits a `:notice`.

  `before_settle` runs after a turn that ended `done`, not a compaction,
  before the session takes its queues, with the session id, the turn id,
  the stop reason, and `cwd`, the session's folder; the first continue
  ends its chain.
  A continue starts the next turn with `text` as a user message whose
  origin is `%{kind: :hook, id: inspect(module)}`. A failed hook there is
  a `:notice`, and the chain goes on with the next hook; with no continue
  the session settles. At most 8 turns in a row start from a continue; a
  client message resets the count.

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

  @callback before_tool(call()) :: :allow | {:allow, String.t()} | {:deny, String.t()}
  @callback after_tool(%{required(:result) => result(), optional(atom()) => term()}) ::
              :keep | {:replace, result()}
  @callback before_settle(settle()) :: :settle | {:continue, String.t()}
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
  does from a call Task: the same request rules, the same `:ask` event
  with the call id and the tool name, and the same answers. Any other
  caller than a hook Task of a running call, a `before_settle` hook too,
  gets `{:error, :not_running}`: the session checks it against its record of the call
  and hook Tasks that the hands started. The session ends the ask with the outcome `:ended` when
  the hook Task ends, so a hook killed at its limit leaves no question
  open.
  """
  @spec ask(map()) :: {:ok, map()} | {:error, :no_client | :not_running}
  def ask(request), do: Helyx.Session.Ask.ask(:hook, request)
end
