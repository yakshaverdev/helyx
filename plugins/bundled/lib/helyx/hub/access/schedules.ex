defmodule Helyx.Hub.Access.Schedules do
  @moduledoc false
  # The schedule part of the authority of a Hub (`docs/features/hub.md`,
  # decision 11): `hub.schedules.*` on the wire and the Elixir API that
  # `Helyx.Hub.schedule/3` uses. `Helyx.Hub.Access` delegates them to it.

  alias Helyx.Hub
  alias Helyx.Hub.{Params, Schedules}

  def create(arg, auth, {id, fields}) do
    case call(arg, auth, id, fields) do
      {:ok, schedule} -> {:ok, %{"schedule" => wire(Schedules.view(schedule))}}
      other -> Helyx.Hub.Access.error(other)
    end
  end

  def list(arg, auth, id) do
    case rows(arg, auth, id) do
      {:ok, rows} -> {:ok, %{"schedules" => Enum.map(rows, &wire(Schedules.view(&1)))}}
      other -> Helyx.Hub.Access.error(other)
    end
  end

  # `hub.schedules.list`, also for `Helyx.Hub.schedules/3`: the schedules of
  # one session need the existence check; all need none.
  def rows(arg, auth, id) do
    exists? = id != nil and Helyx.Hub.Access.found?(arg, id)
    Hub.call(arg.hub, {:schedule_list, auth, id, exists?}, Map.get(arg, :until, :infinity))
  end

  # `Helyx.Hub.schedule/3`: `hub.schedules.create` for the user `user_id`,
  # with the same checks in the same order.
  def schedule(arg, user_id, params) do
    case Params.check("hub.schedules.create", params) do
      {:ok, {id, fields}} ->
        case call(arg, %{user: user_id, token: nil}, id, fields) do
          {:ok, row} -> {:ok, Schedules.view(row)}
          :revoked -> {:error, :unknown_user}
          other -> other
        end

      code ->
        {:error, code}
    end
  end

  defp call(arg, auth, id, fields) do
    request = {:schedule_create, auth, id, Helyx.Hub.Access.found?(arg, id), fields}

    Hub.call(arg.hub, request, Map.get(arg, :until, :infinity))
  end

  defp wire(schedule), do: Helyx.Hub.Access.wire(schedule)
end
