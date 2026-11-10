defmodule Helyx.Tool.ScheduleDelete do
  @moduledoc """
  The coordinator tool `schedule_delete`: deletes a schedule of the user of
  the calling session (`Helyx.Hub.delete_schedule/3`,
  `docs/features/hub.md`, decisions 11 and 12). A schedule of another user
  gives the text of a missing one. See `docs/features/coordinator.md`.
  """

  @behaviour Helyx.Tool

  alias Helyx.Coordinator

  @impl true
  def name, do: "schedule_delete"

  @impl true
  def concurrent?, do: true

  @impl true
  def description do
    "Delete a schedule of the user. Its pending wake-up goes, so it sends no later prompt."
  end

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "schedule" => %{"type" => "string", "description" => "The id of the schedule"}
      },
      "required" => ["schedule"]
    }
  end

  @impl true
  def run(%{"schedule" => id}, _cwd) do
    with true <- Coordinator.id?(id) || {:error, "the id must be a schedule id"},
         {:ok, env} <- Coordinator.setup(),
         :ok <- deleted(Helyx.Hub.delete_schedule(env.hub, env.user, id)) do
      {:ok, "deleted schedule #{id}"}
    else
      {:error, text} -> {:error, "schedule_delete: " <> text}
    end
  end

  def run(_args, _cwd), do: {:error, "schedule_delete needs the id of a schedule"}

  defp deleted(:ok), do: :ok

  defp deleted({:error, :unknown_schedule}),
    do: {:error, "no such schedule, or it is not yours"}

  defp deleted({:error, reason}), do: {:error, Coordinator.text(reason)}
end
