defmodule Helyx.Tool.Schedule do
  @moduledoc """
  The coordinator tool `schedule`: a Hub wake-up that sends a prompt to a
  session that the user of the calling session owns, at a time, once or
  each period (`Helyx.Hub.schedule/3`, `docs/features/hub.md`, decisions
  11 and 12). The Hub caps hold: 16 schedules of a session, 256 of a user.
  See `docs/features/coordinator.md`.
  """

  @behaviour Helyx.Tool

  alias Helyx.Coordinator

  @impl true
  def name, do: "schedule"

  @impl true
  def concurrent?, do: true

  @impl true
  def description do
    "Schedule a prompt that the server sends to a session at a time, once or each period, " <>
      "also when the session is stopped then. at is in POSIX seconds, UTC."
  end

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "id" => %{"type" => "string", "description" => "The id of the session"},
        "at" => %{
          "type" => "integer",
          "description" => "When, in POSIX seconds, from now to 366 days on"
        },
        "prompt" => %{"type" => "string", "description" => "The prompt, at most 16,384 bytes"},
        "every" => %{
          "type" => "integer",
          "description" => "Optional: the period in seconds, 300 to 2,678,400"
        }
      },
      "required" => ["id", "at", "prompt"]
    }
  end

  @impl true
  def run(%{"id" => id, "at" => at, "prompt" => prompt} = args, _cwd) do
    # The Hub checks each value with the rules of `hub.schedules.create`.
    params =
      Map.merge(
        %{"session" => id, "at" => at, "prompt" => prompt},
        Map.take(args, ["every"])
      )

    with true <- Coordinator.id?(id) || {:error, "the id must be a session id"},
         {:ok, env} <- Coordinator.setup(),
         {:ok, schedule} <- made(Helyx.Hub.schedule(env.hub, env.user, params)) do
      every = if schedule.every, do: " each #{schedule.every} s", else: " once"
      {:ok, "schedule #{schedule.id}: session #{schedule.session} at #{schedule.at}#{every}"}
    else
      {:error, text} -> {:error, "schedule: " <> text}
    end
  end

  def run(_args, _cwd), do: {:error, "schedule needs an id, a time at, and a prompt"}

  defp made({:ok, schedule}), do: {:ok, schedule}

  defp made({:error, :bad_params}),
    do:
      {:error,
       "at must be from now to 366 days on, every from 300 to 2,678,400 s, " <>
         "and the prompt not empty"}

  defp made({:error, reason}), do: {:error, Coordinator.text(reason)}
end
