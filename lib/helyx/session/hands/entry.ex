defmodule Helyx.Session.Hands.Entry do
  @moduledoc false
  # One Task of `Helyx.Session.Hands`, by the monitor ref of its Task in
  # `Helyx.Session.Hands.State` (`tasks`).
  #
  # `turn_id` is the turn that owns the Task, and nil for the provider process,
  # a source and a server Task. `tool` is the plugin whose `release/3` gets the
  # handles of the Task, and nil for the two chain Tasks. `handles` are the
  # handles that the Task holds with `Helyx.Tool.hold/1`.

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
