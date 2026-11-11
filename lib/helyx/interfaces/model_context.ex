defmodule Helyx.ModelContext do
  @moduledoc """
  Builds the context a provider sees on one call.

  A model context plugin implements this behaviour. The session builds a base
  `Helyx.Context` with the transcript and the tools, and `build/2` returns
  the context to send. `opts` carries
  `:core`, `:session_id`, `:turn_id`, `:cwd`, `:model` (the
  `Helyx.ModelRef` of the turn), `:session_dir` (the folder of the
  session file, under the `:sessions_dir` of the Core, or nil when the
  session is not saved), `:summary` (the stored `Helyx.Summary`, or nil),
  and `:deadline`. A message that the plugin adds has no id, so the
  Compaction plugin can tell it from a message of the transcript
  (`docs/features/summary-compaction.md`).

  `:deadline` is the monotonic time in milliseconds
  (`System.monotonic_time(:millisecond)`) at which the session kills the
  prepare Task, 10,000 ms after its start. The build, the
  `Helyx.Compaction.compact/2` call, and the `Helyx.Memory` recall run in
  that Task and share the budget, in that order: the recall gets what is
  left. At the kill the turn fails with `:context_timeout`
  (`docs/features/session-lifecycle.md`). A plugin that calls a slow
  service sets its own limit before the deadline, with room for the steps
  after it.

  A Core can register several. A session uses the one that its start
  names with `:model_context`, or the first one registered
  (`docs/features/session-model-context.md`).
  """

  @callback build(context :: Helyx.Context.t(), opts :: keyword()) :: Helyx.Context.t()
end
