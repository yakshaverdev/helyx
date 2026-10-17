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
  summary or a failed one).

  It returns the context to send, `{:summarize, %Helyx.Summary.Plan{}}` to
  have the session run the summary call and build again, or `{:error,
  text}` to fail the build. See `docs/features/summary-compaction.md`.
  """

  use Helyx.Interface, mode: :single

  @callback compact(context :: Helyx.Context.t(), opts :: keyword()) ::
              Helyx.Context.t() | {:summarize, Helyx.Summary.Plan.t()} | {:error, String.t()}
end
