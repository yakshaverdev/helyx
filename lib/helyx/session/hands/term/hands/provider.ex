defmodule Helyx.Session.Hands.Term.Hands.Provider do
  @moduledoc false
  # The terms of the provider process that the hands send to the session: its
  # ready signal, its end, a reply, an event, a context request, and its end
  # after the release.

  alias Helyx.Session.Hands.Term.{Data, Event, Request}
  alias Helyx.Session.ProviderRequest

  @kinds [
    provider_ready: "hands.provider_ready",
    provider_exit: "hands.provider_exit",
    provider_reply: "hands.provider_reply",
    provider_event: "hands.provider_event",
    need_context: "hands.need_context",
    provider_down: "hands.provider_down"
  ]

  @doc false
  def kinds, do: @kinds

  @doc false
  def direction(_tag), do: :hands_to_session

  def check(%{t: kind, instance: instance, id: id} = term)
      when kind in [:provider_ready, :provider_exit] do
    if map_size(term) == 3 and Data.id?(instance) and Data.id?(id), do: {:ok, term}, else: :error
  end

  def check(
        %{t: :provider_reply, instance: instance, id: id, from: from, kind: kind, value: value} =
          term
      ) do
    if map_size(term) == 6 and Data.id?(instance) and Data.id?(id) and Data.id?(from) and
         Request.reply_kind?(kind) and reply?(kind, value),
       do: {:ok, term},
       else: :error
  end

  def check(%{t: :provider_event, instance: instance, id: id, turn: turn, event: event} = term) do
    if map_size(term) == 5 and Data.id?(instance) and Data.id?(id) and Data.turn_id?(turn) and
         Event.event?(event),
       do: {:ok, term},
       else: :error
  end

  def check(
        %{t: :need_context, instance: instance, id: id, turn: turn, overflow: overflow} = term
      ) do
    if map_size(term) == 5 and Data.id?(instance) and Data.id?(id) and Data.turn_id?(turn) and
         is_boolean(overflow),
       do: {:ok, term},
       else: :error
  end

  def check(%{t: :provider_down, instance: instance, id: id, reason: reason} = term) do
    if map_size(term) == 4 and Data.id?(instance) and Data.id?(id) and Data.reason?(reason),
      do: {:ok, term},
      else: :error
  end

  def check(_term), do: :error

  defp reply?(kind, value) when value in [:ok, :busy, :rejected, :unsupported],
    do: ProviderRequest.reply?(kind, value)

  defp reply?(kind, {:error, reason}),
    do: Data.reason?(reason) and ProviderRequest.reply?(kind, {:error, reason})

  defp reply?(_kind, _value), do: false

  # --- the JSON map of each term ---

  @doc false
  def encode(%{t: kind} = term) when kind in [:provider_ready, :provider_exit] do
    {:ok, %{"t" => name(kind), "instance" => term.instance, "id" => term.id}}
  end

  def encode(%{t: :provider_reply} = term) do
    {:ok,
     %{
       "t" => "hands.provider_reply",
       "instance" => term.instance,
       "id" => term.id,
       "from" => term.from,
       "kind" => Atom.to_string(term.kind),
       "value" => reply_value(term.value)
     }}
  end

  def encode(%{t: :provider_event} = term) do
    {:ok,
     %{
       "t" => "hands.provider_event",
       "instance" => term.instance,
       "id" => term.id,
       "turn" => term.turn,
       "event" => Event.event_to_map(term.event)
     }}
  end

  def encode(%{t: :need_context} = term) do
    {:ok,
     %{
       "t" => "hands.need_context",
       "instance" => term.instance,
       "id" => term.id,
       "turn" => term.turn,
       "overflow" => term.overflow
     }}
  end

  def encode(%{t: :provider_down} = term) do
    {:ok,
     %{
       "t" => "hands.provider_down",
       "instance" => term.instance,
       "id" => term.id,
       "reason" => term.reason
     }}
  end

  defp name(kind), do: kind |> Atom.to_string() |> then(&"hands.#{&1}")

  defp reply_value(value) when is_atom(value), do: Atom.to_string(value)
  defp reply_value({:error, reason}), do: %{"error" => reason}

  # --- the term of a JSON map ---

  @doc false
  def decode(%{"t" => kind} = map)
      when kind in ["hands.provider_ready", "hands.provider_exit"] do
    Data.decode_fields(map, ~w(instance id), fn [instance, id] ->
      check(%{t: kind(kind), instance: instance, id: id})
    end)
  end

  def decode(%{"t" => "hands.provider_reply"} = map) do
    Data.decode_fields(map, ~w(instance id from kind value), fn
      [instance, id, from, kind, value] ->
        with {:ok, kind} <- reply_kind(kind),
             {:ok, value} <- reply(value) do
          check(%{
            t: :provider_reply,
            instance: instance,
            id: id,
            from: from,
            kind: kind,
            value: value
          })
        end
    end)
  end

  def decode(%{"t" => "hands.provider_event"} = map) do
    Data.decode_fields(map, ~w(instance id turn event), fn [instance, id, turn, event] ->
      with {:ok, event} <- Event.to_event(event) do
        check(%{t: :provider_event, instance: instance, id: id, turn: turn, event: event})
      end
    end)
  end

  def decode(%{"t" => "hands.need_context"} = map) do
    Data.decode_fields(map, ~w(instance id turn overflow), fn [instance, id, turn, overflow] ->
      check(%{t: :need_context, instance: instance, id: id, turn: turn, overflow: overflow})
    end)
  end

  def decode(%{"t" => "hands.provider_down"} = map) do
    Data.decode_fields(map, ~w(instance id reason), fn [instance, id, reason] ->
      check(%{t: :provider_down, instance: instance, id: id, reason: reason})
    end)
  end

  def decode(_map), do: :error

  defp kind("hands.provider_ready"), do: :provider_ready
  defp kind("hands.provider_exit"), do: :provider_exit

  defp reply_kind(kind) do
    atom = :erlang.binary_to_existing_atom(kind, :utf8)
    if Request.reply_kind?(atom), do: {:ok, atom}, else: :error
  rescue
    ArgumentError -> :error
  end

  defp reply(%{"error" => reason} = map) when map_size(map) == 1, do: {:ok, {:error, reason}}

  defp reply(value) when value in ["ok", "busy", "rejected", "unsupported"] do
    {:ok, :erlang.binary_to_existing_atom(value, :utf8)}
  end

  defp reply(_value), do: :error
end
