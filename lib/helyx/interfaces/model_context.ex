defmodule Helyx.ModelContext do
  @moduledoc """
  Builds the context a provider sees on one call.

  A model context plugin implements this behaviour. The session builds a base
  `Helyx.Context` with the transcript and the tools, and `build/2` returns
  the context to send. `opts` carries
  `:core`, `:session_id`, `:turn_id`, `:cwd`, `:model` (the
  `Helyx.ModelRef` of the turn), `:session_dir` (the folder of the
  session file, under `:sessions_dir` as the caller gave it, or nil when the
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

  The optional `user_text/2` replaces the checked text of a user message (`docs/features/skills.md`).
  """

  @callback build(context :: Helyx.Context.t(), opts :: keyword()) :: Helyx.Context.t()

  @doc """
  The text of a user message, in place of the text that the caller gives.

  Core calls it for each text of `Helyx.Session.prompt/3`, `steer/3`, and
  `follow_up/3` whose origin is the user (the default origin, kind `:user`),
  after the text checks. A text of another origin, such as one of product
  code or of a hook, is not passed. `opts` has `:core`, `:session_id`, and
  `:cwd`. It runs in the process of the caller, so the caller's own deadline
  bounds it. A return that is not a binary is a contract break and raises in
  the caller. The returned text takes the checks of a text again, valid UTF-8
  and at most 4 MiB, with their usual errors.
  """
  @callback user_text(text :: String.t(), opts :: keyword()) :: String.t()
  @optional_callbacks user_text: 2
end
