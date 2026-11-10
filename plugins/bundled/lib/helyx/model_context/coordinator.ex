defmodule Helyx.ModelContext.Coordinator do
  @moduledoc """
  The model context of the coordinator mode: a base prompt for an agent
  with no working folder that starts, steers, reads, waits for, and
  schedules other sessions with the coordinator tools (`session_create`,
  `session_send`, `session_read`, `session_wait`, `schedule`,
  `schedule_list`, `schedule_delete`), then a
  section with the modes of the product, the session id, the model, and
  the time in UTC to the minute, which `schedule` needs. It reads no
  context file. Each value is one line of at most 4,096 bytes. See
  `docs/features/coordinator.md`.
  """

  @behaviour Helyx.ModelContext

  # The cap of one value line, as in `Helyx.ModelContext.Default`.
  @max_value_bytes 4_096
  # The names of the modes in the section, sorted; the rest are left out.
  @max_modes 32

  @base_prompt """
  You are a coordinator. You have no working folder and no file or shell tools. You get work \
  done by other sessions: each is an agent of its own, in a folder, with a mode.

  - session_create starts a session in a folder with a mode and sends it a first prompt. It \
  returns the id of the session, which runs on after the call.
  - session_wait waits until one of the sessions ends its turn. Call it again past its deadline.
  - session_read reads the transcript of a session. With a question, it gives only the answer.
  - session_send sends a session a prompt, a steer into its running turn, or a follow-up.
  - schedule makes the server send a session a prompt at a time, once or each period.
  - schedule_list lists the schedules, with the outcome of the last run of each.
  - schedule_delete deletes a schedule. To change one, delete it and schedule it again.

  Give each session the whole task: it has none of this conversation. Tell the user the ids \
  of the sessions that you start, and what each one did.\
  """

  @impl true
  def build(context, opts) do
    modes = Helyx.Coordinator.mode_names() |> Enum.take(@max_modes) |> Enum.join(", ")
    now = DateTime.utc_now() |> DateTime.truncate(:second) |> Map.put(:second, 0)

    section = """
    ## This session

    #{line("Modes", if(modes == "", do: "none", else: modes))}
    #{line("Model", Helyx.ModelRef.to_string(Keyword.fetch!(opts, :model)))}
    #{line("Session id", Keyword.fetch!(opts, :session_id))}
    #{line("Time", "#{DateTime.to_iso8601(now)}, POSIX #{DateTime.to_unix(now)}")}\
    """

    %{context | system: @base_prompt <> "\n\n" <> section}
  end

  defp line(label, value) do
    "#{label}: " <> String.replace(Helyx.Text.cap(value, @max_value_bytes, :head), ~r/\R/u, " ")
  end
end
