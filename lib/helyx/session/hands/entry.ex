defmodule Helyx.Session.Hands.Entry do
  @moduledoc false
  # One Task of `Helyx.Session.Hands`, by the monitor ref of its Task in
  # `Helyx.Session.Hands.State` (`tasks`).
  #
  # Nine kinds, and the data that only a kind has:
  #
  # - `{:call, call_id}`: a tool call, from its start to its end.
  # - `{:placed, call_id, place}`: the call took the background place of
  #   `Helyx.Tool.background/0`; the place is its run folder until the start
  #   answer or the end of the call.
  # - `{:run, id}`: a background run, from its start answer to its end; its
  #   id is the place it took, which it holds until its Task ends.
  # - `{:hook, chain_id, run}`: a hook of the call or chain Task `chain_id`;
  #   `run` holds its caller, its start, and its request
  #   (`Helyx.Session.Hands.Hooks`).
  # - `{:settle, ref}`: the chain Task of a `before_settle` request `ref`
  #   (`Helyx.Session.Hands.Settle`).
  # - `{:approval, call_id}`: the chain Task of an approval request
  #   (`Helyx.Session.Hands.Approval`).
  # - `:provider`: the provider process (`Helyx.Session.Hands`).
  # - `{:source, plugin}`: the process of the tool source `plugin`
  #   (`Helyx.Session.Hands.Sources`).
  # - `{:server, source, ref}`: a server Task that the source process
  #   `source` started with `Helyx.Tool.launch/1`, under its request `ref`.
  #
  # `turn_id` is the turn that owns the Task, and nil for the provider
  # process, a source and a server Task, which no turn owns
  # (`Helyx.Session.Ask.asker/1`). `tool` is the plugin whose `release/3`
  # gets the handles of the Task, and nil for the two chain Tasks, which
  # run no plugin code and hold none. `handles` are the handles that the
  # Task holds with `Helyx.Tool.hold/1`.

  @enforce_keys [:task, :kind]
  defstruct [:task, :kind, :turn_id, :tool, handles: []]

  @type kind ::
          {:call, String.t()}
          | {:placed, String.t(), String.t()}
          | {:run, String.t()}
          | {:hook, term(), map()}
          | {:settle, reference()}
          | {:approval, String.t()}
          | :provider
          | {:source, module()}
          | {:server, pid(), reference()}

  @type t :: %__MODULE__{
          task: Task.t(),
          kind: kind(),
          turn_id: String.t() | nil,
          tool: module() | nil,
          handles: [term()]
        }
end
