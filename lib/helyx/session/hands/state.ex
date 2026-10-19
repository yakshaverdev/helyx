defmodule Helyx.Session.Hands.State do
  @moduledoc false

  alias Helyx.Session.Background

  # `tools` is the tool module by name. `tasks` holds each running Task,
  # its turn, its call id, its tool module, and its place, by monitor
  # ref: a background Task has no turn and `{:background, id}` for its
  # call id. The place is the id of the run from `background/0` to the end
  # of the Task, else nil. `background` holds the ends that no turn took
  # (`Helyx.Session.Background`); `background_dir` is the background
  # folder. `held` holds the handles per Task pid. `unconfirmed?` is true
  # once a release left a handle unconfirmed; the log got the handles then.
  # `release_ms` is the release deadline of a delivery or a cancel, and
  # `connect_ms` the armed kill of a provider process: seams for tests.
  @enforce_keys [:core, :cwd, :background_dir, :session, :tools]

  # The default release deadline, the one source (`Helyx.Session.Server.Stop`
  # derives its stop bounds from it).
  @release_ms 20_000
  def release_ms, do: @release_ms

  defstruct [
    :core,
    :cwd,
    :background_dir,
    :session,
    :tools,
    tasks: %{},
    background: %Background{},
    held: %{},
    unconfirmed?: false,
    release_ms: @release_ms,
    connect_ms: 30_000
  ]
end
