defmodule Helyx.Session.Hands.Term.Session.Provider do
  @moduledoc false
  # The terms of the provider process that the session sends to its hands: its
  # start, its go, a request to it, and its stop.

  alias Helyx.Message
  alias Helyx.Session.Hands.Term.{Data, Request}

  @kinds [
    provider_start: "hands.provider_start",
    provider_go: "hands.provider_go",
    provider_request: "hands.provider_request",
    provider_stop: "hands.provider_stop"
  ]

  @doc false
  def kinds, do: @kinds

  @doc false
  def direction(_tag), do: :session_to_hands

  def check(
        %{
          t: :provider_start,
          instance: instance,
          provider: provider,
          id: id,
          model: model,
          tools: tools,
          session: session,
          resume_id: resume_id,
          resume_usage: usage
        } = term
      ) do
    if map_size(term) == 9 and
         provider_start?(instance, provider, id, model, tools, session, resume_id, usage),
       do: {:ok, term},
       else: :error
  end

  def check(%{t: :provider_go, instance: instance, id: id} = term) do
    if map_size(term) == 3 and Data.id?(instance) and Data.id?(id), do: {:ok, term}, else: :error
  end

  def check(
        %{t: :provider_request, instance: instance, id: id, from: from, request: request, ms: ms} =
          term
      ) do
    with true <- map_size(term) == 6,
         true <- Data.id?(instance) and Data.id?(id) and Data.id?(from),
         true <- Data.integer?(ms),
         {:ok, request} <- Request.check(request) do
      {:ok, %{term | request: request}}
    else
      _ -> :error
    end
  end

  def check(%{t: :provider_stop, instance: instance, id: id, reason: reason} = term) do
    if map_size(term) == 4 and Data.id?(instance) and Data.id?(id) and Data.reason?(reason),
      do: {:ok, term},
      else: :error
  end

  def check(_term), do: :error

  defp provider_start?(instance, provider, id, model, tools, session, resume_id, usage) do
    Data.id?(instance) and Data.plugin?(provider) and Data.id?(id) and model?(model) and
      Data.list?(tools, &Data.spec?/1) and Data.id?(session) and resume_id?(resume_id) and
      Data.usage?(usage)
  end

  defp model?(model), do: Data.text?(model) and byte_size(model) > 0

  defp resume_id?(nil), do: true
  defp resume_id?(id), do: Message.resume_id?(id)

  # --- the JSON map of each term ---

  @doc false
  def encode(%{t: :provider_start} = term) do
    {:ok,
     %{
       "t" => "hands.provider_start",
       "instance" => term.instance,
       "provider" => term.provider,
       "id" => term.id,
       "model" => term.model,
       "tools" => Enum.map(term.tools, &Data.spec_to_map/1),
       "session" => term.session,
       "resume_id" => term.resume_id,
       "resume_usage" => usage_map(term.resume_usage)
     }}
  end

  def encode(%{t: :provider_go} = term),
    do: {:ok, %{"t" => "hands.provider_go", "instance" => term.instance, "id" => term.id}}

  def encode(%{t: :provider_request} = term) do
    {:ok,
     %{
       "t" => "hands.provider_request",
       "instance" => term.instance,
       "id" => term.id,
       "from" => term.from,
       "request" => Request.request_to_map(term.request),
       "ms" => term.ms
     }}
  end

  def encode(%{t: :provider_stop} = term) do
    {:ok,
     %{
       "t" => "hands.provider_stop",
       "instance" => term.instance,
       "id" => term.id,
       "reason" => term.reason
     }}
  end

  defp usage_map(nil), do: nil
  defp usage_map(usage), do: Data.usage_to_map(usage)

  # --- the term of a JSON map ---

  @doc false
  def decode(%{"t" => "hands.provider_start"} = map) do
    Data.decode_fields(
      map,
      ~w(instance provider id model tools session resume_id resume_usage),
      fn [instance, provider, id, model, tools, session, resume_id, usage] ->
        with {:ok, tools} <- to_specs(tools),
             {:ok, usage} <- Data.to_usage(usage) do
          check(%{
            t: :provider_start,
            instance: instance,
            provider: provider,
            id: id,
            model: model,
            tools: tools,
            session: session,
            resume_id: resume_id,
            resume_usage: usage
          })
        end
      end
    )
  end

  def decode(%{"t" => "hands.provider_go"} = map) do
    Data.decode_fields(map, ~w(instance id), fn [instance, id] ->
      check(%{t: :provider_go, instance: instance, id: id})
    end)
  end

  def decode(%{"t" => "hands.provider_request"} = map) do
    Data.decode_fields(map, ~w(instance id from request ms), fn
      [instance, id, from, request, ms] ->
        with {:ok, request} <- Request.to_request(request) do
          check(%{
            t: :provider_request,
            instance: instance,
            id: id,
            from: from,
            request: request,
            ms: ms
          })
        end
    end)
  end

  def decode(%{"t" => "hands.provider_stop"} = map) do
    Data.decode_fields(map, ~w(instance id reason), fn [instance, id, reason] ->
      check(%{t: :provider_stop, instance: instance, id: id, reason: reason})
    end)
  end

  def decode(_map), do: :error

  defp to_specs(specs) when is_list(specs) do
    specs
    |> Enum.reduce_while({:ok, []}, fn spec, {:ok, acc} ->
      case Data.to_spec(spec) do
        {:ok, spec} -> {:cont, {:ok, [spec | acc]}}
        :error -> {:halt, :error}
      end
    end)
    |> Data.reversed()
  end

  defp to_specs(_specs), do: :error
end
