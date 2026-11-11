defmodule Helyx.Tool.SubscriptionList do
  @moduledoc """
  The coordinator tool `subscription_list`: the event subscriptions of a
  session, or of every session of the user of the calling session
  (`Helyx.Hub.subscriptions/3`, `docs/features/hub.md`, decision 17). An
  item never holds the secret of the webhook. See
  `docs/features/coordinator.md`.
  """

  @behaviour Helyx.Tool

  alias Helyx.Coordinator

  # The text of the lines, under the result bound of 65,536 bytes.
  @budget_bytes 60_000
  # The template bytes of one line, before `inspect` escapes them.
  @template_bytes 256

  @impl true
  def name, do: "subscription_list"

  @impl true
  def concurrent?, do: true

  @impl true
  def description do
    "List the event subscriptions of a session, or of every session that you own. " <>
      "The secret of a subscription is never shown; only the create step shows it once."
  end

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "id" => %{"type" => "string", "description" => "Optional: the id of a session"}
      }
    }
  end

  @impl true
  def run(args, _cwd) when is_map(args) do
    with true <- only_id?(args) || {:error, "subscription_list takes only an id"},
         {:ok, session} <- session(args),
         {:ok, env} <- Coordinator.setup(),
         {:ok, subscriptions} <- listed(Helyx.Hub.subscriptions(env.hub, env.user, session)) do
      {:ok, text(subscriptions)}
    else
      {:error, text} when is_binary(text) -> {:error, "subscription_list: " <> text}
      {:error, reason} -> {:error, "subscription_list: " <> Coordinator.text(reason)}
    end
  end

  def run(_args, _cwd), do: {:error, "subscription_list takes an optional id"}

  defp only_id?(args), do: Map.keys(args) -- ["id"] == []

  defp session(%{"id" => id}) do
    if Coordinator.id?(id), do: {:ok, id}, else: {:error, "the id must be a session id"}
  end

  defp session(%{}), do: {:ok, nil}

  defp listed({:ok, subscriptions}), do: {:ok, subscriptions}
  defp listed({:error, reason}), do: {:error, reason}

  defp text([]), do: "no event subscriptions"

  # 256 subscriptions of a user, each with a template of 256 bytes that
  # `inspect` with `binaries: :as_strings` can make four times longer, pass
  # the result bound, so the lines stop at a budget below
  # `Helyx.Message.max_result_bytes/0` and a last line counts the rest.
  defp text(subscriptions) do
    {shown, _bytes} =
      Enum.reduce_while(subscriptions, {[], 0}, fn subscription, {lines, bytes} ->
        line = line(subscription)
        bytes = bytes + byte_size(line) + 1

        if bytes > @budget_bytes,
          do: {:halt, {lines, bytes}},
          else: {:cont, {[line | lines], bytes}}
      end)

    body = shown |> Enum.reverse() |> Enum.join("\n")

    case length(subscriptions) - length(shown) do
      0 -> body
      rest -> body <> "\n#{rest} more not shown; list the subscriptions of one session"
    end
  end

  defp line(subscription) do
    label =
      case subscription.label do
        "" -> ""
        label -> ", label " <> label
      end

    outcome =
      case subscription.last_outcome do
        nil -> "no delivery yet"
        outcome -> "last delivery " <> outcome
      end

    prompt = Helyx.Text.cap(subscription.template, @template_bytes, :head)

    cut =
      if prompt == subscription.template,
        do: "",
        else: " (cut, #{byte_size(subscription.template)} bytes)"

    "subscription #{subscription.id}: session #{subscription.session}#{label}, " <>
      "pending #{subscription.pending}, #{outcome}\n" <>
      "  endpoint: #{Helyx.Hub.Subscriptions.path(subscription)}\n" <>
      "  prompt: #{inspect(prompt, binaries: :as_strings)}#{cut}"
  end
end
