defmodule Helyx.Hook do
  # The most ms of a hook at one point (ADR 0013 §3).
  @max_limit_ms 600_000

  @moduledoc """
  A check before and after each Helyx tool call (ADR 0013,
  `docs/features/hooks.md`).

  A hook plugin implements the points that it handles, each optional:
  `before_tool/1` answers `:allow`, `{:allow, reason}`, or `{:deny,
  reason}`; `after_tool/1` answers `:keep` or `{:replace, {:ok | :error,
  text}}`. A reason and a text are strings of valid UTF-8. `limit/1`
  gives the limit of the hook at a point, an integer of ms from 1 to
  #{@max_limit_ms}. Core checks it once at its start, and refuses a hook plugin
  with no point (`{:no_hook_point, module}`) and a bad limit
  (`{:invalid_hook_limit, module}`).

  The hooks of a point run in the order of the plugin list. A deny ends
  the `before_tool` chain, and the call does not run; each `after_tool`
  hook gets the result that the hook before it left. A raise, a throw, an
  exit, a hook past its limit, and a return that is not an answer of its
  point is a failed hook: `before_tool` denies the call, `after_tool`
  keeps the result and the session emits a `:notice`.

  Each hook runs in a Task of the hands of its own, with the call's
  context (`Helyx.Tool.context/0`). It holds an OS resource with
  `Helyx.Tool.hold/1` and implements the optional `release/3`, with the
  rules of `Helyx.Tool`. Each answer of a `before_tool` hook, and each
  replace or failure of an `after_tool` hook, is a `hook` entry of the
  session file; a keep changes nothing and is not written.
  """

  use Helyx.Interface, mode: :multi

  @type point :: :before_tool | :after_tool
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

  @callback before_tool(call()) :: :allow | {:allow, String.t()} | {:deny, String.t()}
  @callback after_tool(%{required(:result) => result(), optional(atom()) => term()}) ::
              :keep | {:replace, result()}
  @callback limit(point()) :: pos_integer()
  @callback release(handles :: [term()], mode :: :deliver | :cancel, deadline :: integer()) ::
              [term()]

  @optional_callbacks before_tool: 1, after_tool: 1, release: 3

  @doc false
  def max_limit_ms, do: @max_limit_ms

  @doc false
  # The points in the order that the chain of a call runs them.
  @spec points() :: [point()]
  def points, do: [:before_tool, :after_tool]

  @doc """
  Asks the clients of the session from a hook Task, as `Helyx.Tool.ask/1`
  does from a call Task: the same request rules, the same `:ask` event
  with the call id and the tool name, and the same answers. Any other
  caller than a hook Task of a running call gets `{:error,
  :not_running}`. The session ends the ask with the outcome `:ended` when
  the hook Task ends, so a hook killed at its limit leaves no question
  open.
  """
  @spec ask(map()) :: {:ok, map()} | {:error, :no_client | :not_running}
  def ask(request), do: Helyx.Session.Ask.ask(:hook, request)
end
