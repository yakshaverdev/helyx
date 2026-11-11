defmodule Helyx.Tool.SubscriptionDelete do
  @moduledoc """
  The coordinator tool `subscription_delete`: deletes an event subscription
  of the user of the calling session (`Helyx.Hub.unsubscribe/3`,
  `docs/features/hub.md`, decision 17). A subscription of another user gives
  the answer of a missing one. See `docs/features/coordinator.md`.
  """

  @behaviour Helyx.Tool

  alias Helyx.Coordinator
  alias Helyx.Tool.Args

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
  def run(args, _cwd) do
    with {:ok, args} <- Args.check(args, parameters()),
         true <- Coordinator.id?(args["id"]) || {:error, "the id must be a subscription id"},
         {:ok, env} <- Coordinator.setup(),
         :ok <- Helyx.Hub.unsubscribe(env.hub, env.user, args["id"]) do
      {:ok, "subscription #{args["id"]} deleted"}
    else
      {:error, text} when is_binary(text) -> {:error, "subscription_delete: " <> text}
      {:error, reason} -> {:error, "subscription_delete: " <> Coordinator.text(reason)}
    end
  end
end
