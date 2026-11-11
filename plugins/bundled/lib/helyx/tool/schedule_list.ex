defmodule Helyx.Tool.ScheduleList do
  @moduledoc """
  The coordinator tool `schedule_list`: the schedules of the user of the
  calling session, all of them or those of one session (`Helyx.Hub.schedules/3`,
  `docs/features/hub.md`, decisions 11 and 12). A session that the user may
  not read gives the text of a missing one. See `docs/features/coordinator.md`.
  """

  @behaviour Helyx.Tool

  alias Helyx.Coordinator

  # The text of the lines, under the result bound of 65,536 bytes.
  @budget_bytes 60_000

  @impl true
  def name, do: "schedule_list"

  @impl true
  def concurrent?, do: true

  @impl true
  def description do
    "List the schedules of the user: all of them, or those of one session. " <>
      "Each line holds its id, session, next time, period, pending state, the outcome of " <>
      "its last run, and the first 256 bytes of its prompt, with the full size when cut."
  end

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "id" => %{
          "type" => "string",
          "description" => "Optional: the id of a session, for its schedules only"
        }
      },
      "required" => []
    }
  end

  @impl true
  def run(args, _cwd) do
    id = Map.get(args, "id")

    with :ok <- checked(args, id),
         {:ok, env} <- Coordinator.setup(),
         {:ok, schedules} <- listed(Helyx.Hub.schedules(env.hub, env.user, id)) do
      {:ok, text(schedules)}
    else
      {:error, text} -> {:error, "schedule_list: " <> text}
    end
  end

  defp checked(args, nil) when map_size(args) == 0, do: :ok

  defp checked(args, id) when map_size(args) == 1 and is_map_key(args, "id"),
    do: if(Coordinator.id?(id), do: :ok, else: {:error, "the id must be a session id"})

  defp checked(_args, _id), do: {:error, "it takes only the optional id of a session"}

  defp listed({:ok, schedules}), do: {:ok, schedules}
  defp listed({:error, reason}), do: {:error, Coordinator.text(reason)}

  defp text([]), do: "no schedules"

  # 256 schedules of a user, each with a prompt of 256 bytes that
  # `inspect` with `binaries: :as_strings` can make four times longer, pass
  # the result bound, so the lines stop at a budget below
  # `Helyx.Message.max_result_bytes/0` and a last line counts the rest.
  defp text(schedules) do
    {shown, _bytes} =
      Enum.reduce_while(schedules, {[], 0}, fn schedule, {lines, bytes} ->
        line = line(schedule)
        bytes = bytes + byte_size(line) + 1

        if bytes > @budget_bytes,
          do: {:halt, {lines, bytes}},
          else: {:cont, {[line | lines], bytes}}
      end)

    body = shown |> Enum.reverse() |> Enum.join("\n")

    case length(schedules) - length(shown) do
      0 -> body
      rest -> body <> "\n#{rest} more not shown; list the schedules of one session"
    end
  end

  defp line(schedule) do
    every = if schedule.every, do: " each #{schedule.every} s", else: " once"
    pending = if schedule.pending, do: "pending", else: "ended"
    prompt = Helyx.Text.cap(schedule.prompt, 256, :head)

    cut =
      if prompt == schedule.prompt, do: "", else: " (cut, #{byte_size(schedule.prompt)} bytes)"

    "schedule #{schedule.id}: session #{schedule.session} at #{schedule.at}#{every}, " <>
      "#{pending}#{last(schedule)}, prompt #{inspect(prompt, binaries: :as_strings)}#{cut}"
  end

  defp last(%{last_outcome: nil}), do: ""
  defp last(%{last_outcome: outcome, last_at: at}), do: ", last run #{outcome} at #{at}"
end
