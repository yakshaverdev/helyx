defmodule Helyx.Memory do
  @moduledoc """
  Recalls records for a model call and keeps the messages of the
  conversation (ADR 0009, `docs/features/memory.md`).

  A memory plugin implements this behaviour. Core calls `recall/2` before
  each model call, after the ModelContext and the Compaction plugin, with
  the text (at most 4,096 bytes) and the origin of the last user message.
  It runs in a Task with the limit `recall_ms` of `Helyx.Core.start_link/1`.
  `{:error, text}`, a raise, an exit, or the limit gives no recall and one
  notice in the turn; a return of another shape fails the turn. Core keeps
  the first 32 records, escapes them, and adds them as one fenced user
  message at the end of the context of that call only; a plugin does not
  format the fence. `opts` carries `:core`, `:session_id`, `:instance_id`,
  `:cwd`, and `:turn_id`.

  Core calls `sync/2` off the session process, one chunk at a time, in order
  for one session instance: at a resume, every message of the session file;
  then, at each turn end, the messages that joined the transcript in the
  turn. `persisted` is true when the append of the message to the session
  file succeeded. A message can come twice, also in two calls at once, so
  the plugin removes duplicates by message id. Content is raw: a plugin
  redacts by its own policy. `opts` carries `:core`, `:session_id`,
  `:instance_id`, and `:cwd`.
  """

  use Helyx.Interface, mode: :single

  @type query :: %{text: String.t(), origin: Helyx.Message.origin()}
  @type record :: %{id: String.t(), source: String.t(), text: String.t()}
  @type entry :: %{message: Helyx.Message.t(), persisted: boolean()}

  @callback recall(query(), opts :: keyword()) :: {:ok, [record()]} | {:error, String.t()}
  @callback sync([entry()], opts :: keyword()) :: :ok | {:error, String.t()}
end
