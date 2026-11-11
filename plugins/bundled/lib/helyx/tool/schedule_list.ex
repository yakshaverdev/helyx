defmodule Helyx.Tool.ScheduleList do
  @moduledoc """
  The coordinator tool `schedule_list`: the schedules of the user of the
  calling session, all of them or those of one session (`Helyx.Hub.schedules/3`,
  `docs/features/hub.md`, decisions 11 and 12). A session that the user may
  not read gives the text of a missing one. See `docs/features/coordinator.md`.
  """

  @behaviour Helyx.Tool

  alias Helyx.Coordinator
  alias Helyx.Tool.Args

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
    with {:ok, args} <- Args.check(args, parameters()),
         :ok <- checked(args),
         {:ok, env} <- Coordinator.setup(),
         {:ok, schedules} <- listed(Helyx.Hub.schedules(env.hub, env.user, args["id"])) do
      {:ok, text(schedules)}
    else
      {:error, text} -> {:error, "schedule_list: " <> text}
    end
  end

  defp checked(args) do
    cond do
      Map.keys(args) -- ["id"] != [] ->
        {:error, "it takes only the optional id of a session"}

      args["id"] == nil ->
        :ok

      Coordinator.id?(args["id"]) ->
        :ok

      true ->
        {:error, "the id must be a session id"}
    end
  end

  defp listed({:ok, schedules}), do: {:ok, schedules}
  defp listed({:error, reason}), do: {:error, Coordinator.text(reason)}

  defp text([]), do: "no schedules"

  defp text(schedules),
    do: Coordinator.lines(schedules, &line/1, "list the schedules of one session")

  defp line(schedule) do
    every = if schedule.every, do: " each #{schedule.every} s", else: " once"
    pending = if schedule.pending, do: "pending", else: "ended"

    "schedule #{schedule.id}: session #{schedule.session} at #{schedule.at}#{every}, " <>
      "#{pending}#{last(schedule)}, prompt #{Coordinator.excerpt(schedule.prompt, 256)}"
  end

  defp last(%{last_outcome: nil}), do: ""
  defp last(%{last_outcome: outcome, last_at: at}), do: ", last run #{outcome} at #{at}"
end
