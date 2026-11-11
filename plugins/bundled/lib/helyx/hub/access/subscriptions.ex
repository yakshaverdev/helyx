defmodule Helyx.Hub.Access.Subscriptions do
  @moduledoc false
  # The event subscription part of the authority of a Hub
  # (`docs/features/hub.md`, decision 17): `hub.subscriptions.*` on the wire,
  # the raw Hub calls that `Helyx.Hub.Api` wraps for the Elixir API, and the
  # optional `webhook/3` callback of the transport. `Helyx.Hub.Access` keeps
  # the callbacks of the behaviour and delegates these to it.

  alias Helyx.Hub
  alias Helyx.Hub.{Access, Subscriptions}

  # The wire operations of decision 17. The create reply is the only reply
  # that carries the secret.
  def create(arg, auth, {id, fields}) do
    case create_row(arg, auth, id, fields) do
      {:ok, row} ->
        {:ok,
         %{"subscription" => wire(row), "secret" => row.secret, "path" => Subscriptions.path(row)}}

      other ->
        Access.error(other)
    end
  end

  def list(arg, auth, id) do
    case list_rows(arg, auth, id) do
      {:ok, rows} -> {:ok, %{"subscriptions" => Enum.map(rows, &wire/1)}}
      other -> Access.error(other)
    end
  end

  # The webhook endpoint of decision 17. The transport read the body within
  # its bound; this checks the UTF-8, extracts the signature header, and
  # asks the Hub, which answers the HTTP status and body. A Hub that does
  # not answer gives 503, so a sender tries again later.
  def webhook(arg, id, %{headers: headers, body: body}) do
    if String.valid?(body) do
      signature = signature(headers)

      try do
        case Hub.call(arg.hub, {:webhook, id, signature, body}) do
          {:ok, status, text} -> {:ok, status, text}
          _busy_or_failed -> {:ok, 503, ""}
        end
      catch
        :exit, _reason -> {:ok, 503, ""}
      end
    else
      {:ok, 400, ""}
    end
  end

  defp signature(headers) do
    case for {"x-hub-signature-256", value} <- headers, do: value do
      [value | _] -> value
      [] -> nil
    end
  end

  @doc false
  def create_row(arg, auth, id, fields) do
    request = {:subscription_create, auth, id, Access.found?(arg, id), fields}
    Hub.call(arg.hub, request, Map.get(arg, :until, :infinity))
  end

  # The subscriptions of one session need the existence check; all need none.
  @doc false
  def list_rows(arg, auth, id) do
    exists? = id != nil and Access.found?(arg, id)
    Hub.call(arg.hub, {:subscription_list, auth, id, exists?}, Map.get(arg, :until, :infinity))
  end

  # A subscription on the wire: never its secret (decision 17).
  defp wire(row),
    do: row |> Subscriptions.view() |> Access.wire() |> Map.put("path", Subscriptions.path(row))
end
