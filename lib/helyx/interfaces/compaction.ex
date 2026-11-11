defmodule Helyx.Compaction do
  @moduledoc """
  Shrinks the context before a provider call.

  A compaction plugin implements this behaviour. The session calls
  `compact/2` on the built context before every provider call. `opts` carries
  `:core`, `:session_id`, `:turn_id`, `:cwd`, `:model` (the
  `Helyx.ModelRef` of the turn), `:session_dir` (as for
  `Helyx.ModelContext.build/2`), `:summary` (the stored `Helyx.Summary`, or
  nil), `:instructions` (the text of a `/compact`, else `""`), and
  `:trigger`: `:auto` before a call, `:manual` in a `/compact`, `:overflow`
  after a context overflow, or nil when the plugin must not ask for a
  summary (a provider that keeps its own history, or the build after a
  summary or a failed one). It also carries `:deadline`, the monotonic time
  in milliseconds at which the session kills the prepare Task, the same
  value that `Helyx.ModelContext.build/2` got. The build, the compaction,
  and the `Helyx.Memory` recall share the budget of that Task, 10,000 ms
  from its start; at the kill the turn fails with `:context_timeout` (see
  `Helyx.ModelContext`).

  It returns the context to send, `{:summarize, %Helyx.Summary.Plan{}}` to
  have the session run the summary call and build again, or `{:error,
  text}` to fail the build. See `docs/features/summary-compaction.md`.
  """


  @callback compact(context :: Helyx.Context.t(), opts :: keyword()) ::
              Helyx.Context.t() | {:summarize, Helyx.Summary.Plan.t()} | {:error, String.t()}
end
