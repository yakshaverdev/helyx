defmodule Helyx.ModelContext do
  @moduledoc """
  Builds the context a provider sees on one call.

  A model context plugin implements this behaviour. The session builds a base
  `Helyx.Context` with the transcript and the tools, and `build/2` returns
  the context to send, usually with a system prompt added. `opts` carries
  `:core`, `:session_id`, `:turn_id`, `:cwd`, `:model` (the
  `Helyx.ModelRef` of the turn), and `:session_dir` (the folder of the
  session file, under `:sessions_dir` as the caller gave it, or nil when the
  session is not saved).
  """

  use Helyx.Interface, mode: :single

  @callback build(context :: Helyx.Context.t(), opts :: keyword()) :: Helyx.Context.t()
end
