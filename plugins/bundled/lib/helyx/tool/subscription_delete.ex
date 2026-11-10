defmodule Helyx.Tool.SubscriptionDelete do
  @moduledoc """
  The coordinator tool `subscription_delete`: deletes an event subscription
  of the user of the calling session (`Helyx.Hub.unsubscribe/3`,
  `docs/features/hub.md`, decision 17). A subscription of another user gives
  the answer of a missing one. See `docs/features/coordinator.md`.
  """

  @behaviour Helyx.Tool

  alias Helyx.Coordinator

  @impl true
  def name, do: "subscription_delete"

  @impl true
  def concurrent?, do: true

  @impl true
  def description do
    "Delete an event subscription, so its webhook path stops working and its pending deliveries go."
  end

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "id" => %{"type" => "string", "description" => "The id of the subscription"}
      },
      "required" => ["id"]
    }
  end

  @impl true
  def run(%{"id" => id}, _cwd) do
    with true <- Coordinator.id?(id) || {:error, "the id must be a subscription id"},
         {:ok, env} <- Coordinator.setup(),
         :ok <- Helyx.Hub.unsubscribe(env.hub, env.user, id) do
      {:ok, "subscription #{id} deleted"}
    else
      {:error, text} when is_binary(text) -> {:error, "subscription_delete: " <> text}
      {:error, reason} -> {:error, "subscription_delete: " <> Coordinator.text(reason)}
    end
  end

  def run(_args, _cwd), do: {:error, "subscription_delete needs an id"}
end
