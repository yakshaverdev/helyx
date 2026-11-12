defmodule Helyx.Session.Hands.Term.Session do
  @moduledoc false
  # The terms that the session sends to its hands for the work of a session: the
  # capability request, a call, the go of a Task, the hook requests, the cancel
  # and the stop, and the read of the folder. The provider process terms are in
  # `Helyx.Session.Hands.Term.Session.Provider`.

  alias Helyx.Session.Hands.Term.Data

  @kinds [
    open: "hands.open",
    call: "hands.call",
    taken: "hands.taken",
    go: "hands.go",
    settle: "hands.settle",
    approve: "hands.approve",
    cancel: "hands.cancel",
    revoke: "hands.revoke",
    stop: "hands.stop",
    read: "hands.read"
  ]

  @doc false
  def kinds, do: @kinds

  @doc false
  def direction(_tag), do: :session_to_hands

  def check(
        %{
          t: :open,
          instance: instance,
          session: session,
          only: only,
          provider_opts: opts,
          max_output_tokens: limit
        } = term
      ) do
    if map_size(term) == 6 and Data.id?(instance) and Data.id?(session) and only?(only) and
         Data.provider_opts?(opts) and limit?(limit),
       do: {:ok, term},
       else: :error
  end

  def check(%{t: :call, instance: instance, turn: turn, call: call, context: context} = term) do
    if map_size(term) == 5 and Data.id?(instance) and Data.turn_id?(turn) and Data.call?(call) and
         Data.context?(context),
       do: {:ok, term},
       else: :error
  end

  def check(%{t: :taken, instance: instance, id: id} = term) do
    if map_size(term) == 3 and Data.id?(instance) and Data.id?(id), do: {:ok, term}, else: :error
  end

  def check(%{t: :go, instance: instance, task: task} = term) do
    if map_size(term) == 3 and Data.id?(instance) and Data.id?(task),
      do: {:ok, term},
      else: :error
  end

  def check(
        %{t: :settle, instance: instance, ref: ref, turn: turn, input: input, context: context} =
          term
      ) do
    if map_size(term) == 6 and Data.id?(instance) and Data.id?(ref) and Data.turn_id?(turn) and
         Data.settle_input?(input) and Data.context?(context),
       do: {:ok, term},
       else: :error
  end

  def check(
        %{
          t: :approve,
          instance: instance,
          turn: turn,
          call: call,
          context: context,
          provider: provider
        } = term
      ) do
    if map_size(term) == 6 and Data.id?(instance) and Data.turn_id?(turn) and Data.call?(call) and
         Data.context?(context) and Data.plugin?(provider),
       do: {:ok, term},
       else: :error
  end

  def check(%{t: :cancel, instance: instance, turn: turn} = term) do
    if map_size(term) == 3 and Data.id?(instance) and Data.turn_id?(turn),
      do: {:ok, term},
      else: :error
  end

  def check(%{t: :revoke, instance: instance, turn: turn} = term) do
    if map_size(term) == 3 and Data.id?(instance) and Data.turn_id?(turn),
      do: {:ok, term},
      else: :error
  end

  def check(%{t: :stop, instance: instance, release_ms: ms} = term) do
    if map_size(term) == 3 and Data.id?(instance) and Data.integer?(ms),
      do: {:ok, term},
      else: :error
  end

  def check(%{t: :read, instance: instance, read: read, paths: paths, max_bytes: max} = term) do
    if map_size(term) == 5 and Data.id?(instance) and read?(read, max) and paths?(paths),
      do: {:ok, term},
      else: :error
  end

  def check(_term), do: :error

  defp only?(nil), do: true
  defp only?(names), do: Data.list?(names, &Data.text?/1)

  defp limit?(nil), do: true
  defp limit?(limit), do: is_integer(limit) and limit in 1..Data.max_output_tokens()

  defp read?(:read, max), do: Data.integer?(max)
  defp read?(:list, max), do: is_nil(max)
  defp read?(_read, _max), do: false

  defp paths?(paths) do
    Data.list?(paths, &Data.path?/1) and length(paths) <= Data.max_paths()
  end

  # --- the JSON map of each term ---

  @doc false
  def encode(%{t: :open} = term) do
    {:ok,
     %{
       "t" => "hands.open",
       "instance" => term.instance,
       "session" => term.session,
       "only" => term.only,
       "provider_opts" => Data.provider_opts_to_map(term.provider_opts),
       "max_output_tokens" => term.max_output_tokens
     }}
  end

  def encode(%{t: :call} = term) do
    {:ok,
     %{
       "t" => "hands.call",
       "instance" => term.instance,
       "turn" => term.turn,
       "call" => Data.call_to_map(term.call),
       "context" => Data.context_to_map(term.context)
     }}
  end

  def encode(%{t: :taken} = term),
    do: {:ok, %{"t" => "hands.taken", "instance" => term.instance, "id" => term.id}}

  def encode(%{t: :go} = term),
    do: {:ok, %{"t" => "hands.go", "instance" => term.instance, "task" => term.task}}

  def encode(%{t: :settle} = term) do
    {:ok,
     %{
       "t" => "hands.settle",
       "instance" => term.instance,
       "ref" => term.ref,
       "turn" => term.turn,
       "input" => Data.settle_input_to_map(term.input),
       "context" => Data.context_to_map(term.context)
     }}
  end

  def encode(%{t: :approve} = term) do
    {:ok,
     %{
       "t" => "hands.approve",
       "instance" => term.instance,
       "turn" => term.turn,
       "call" => Data.call_to_map(term.call),
       "context" => Data.context_to_map(term.context),
       "provider" => term.provider
     }}
  end

  def encode(%{t: :cancel} = term),
    do: {:ok, %{"t" => "hands.cancel", "instance" => term.instance, "turn" => term.turn}}

  def encode(%{t: :revoke} = term),
    do: {:ok, %{"t" => "hands.revoke", "instance" => term.instance, "turn" => term.turn}}

  def encode(%{t: :stop} = term),
    do:
      {:ok, %{"t" => "hands.stop", "instance" => term.instance, "release_ms" => term.release_ms}}

  def encode(%{t: :read} = term) do
    {:ok,
     %{
       "t" => "hands.read",
       "instance" => term.instance,
       "read" => Atom.to_string(term.read),
       "paths" => term.paths,
       "max_bytes" => term.max_bytes
     }}
  end

  # --- the term of a JSON map ---

  @doc false
  def decode(%{"t" => "hands.open"} = map) do
    Data.decode_fields(map, ~w(instance session only provider_opts max_output_tokens), fn
      [instance, session, only, opts, limit] ->
        with {:ok, opts} <- Data.to_provider_opts(opts) do
          check(%{
            t: :open,
            instance: instance,
            session: session,
            only: only,
            provider_opts: opts,
            max_output_tokens: limit
          })
        end
    end)
  end

  def decode(%{"t" => "hands.call"} = map) do
    Data.decode_fields(map, ~w(instance turn call context), fn
      [instance, turn, call, context] ->
        with {:ok, call} <- Data.to_call(call),
             {:ok, context} <- Data.to_context(context) do
          check(%{t: :call, instance: instance, turn: turn, call: call, context: context})
        end
    end)
  end

  def decode(%{"t" => "hands.taken"} = map) do
    Data.decode_fields(map, ~w(instance id), fn [instance, id] ->
      check(%{t: :taken, instance: instance, id: id})
    end)
  end

  def decode(%{"t" => "hands.go"} = map) do
    Data.decode_fields(map, ~w(instance task), fn [instance, task] ->
      check(%{t: :go, instance: instance, task: task})
    end)
  end

  def decode(%{"t" => "hands.settle"} = map) do
    Data.decode_fields(map, ~w(instance ref turn input context), fn
      [instance, ref, turn, input, context] ->
        with {:ok, input} <- Data.to_settle_input(input),
             {:ok, context} <- Data.to_context(context) do
          check(%{
            t: :settle,
            instance: instance,
            ref: ref,
            turn: turn,
            input: input,
            context: context
          })
        end
    end)
  end

  def decode(%{"t" => "hands.approve"} = map) do
    Data.decode_fields(map, ~w(instance turn call context provider), fn
      [instance, turn, call, context, provider] ->
        with {:ok, call} <- Data.to_call(call),
             {:ok, context} <- Data.to_context(context) do
          check(%{
            t: :approve,
            instance: instance,
            turn: turn,
            call: call,
            context: context,
            provider: provider
          })
        end
    end)
  end

  def decode(%{"t" => "hands.cancel"} = map) do
    Data.decode_fields(map, ~w(instance turn), fn [instance, turn] ->
      check(%{t: :cancel, instance: instance, turn: turn})
    end)
  end

  def decode(%{"t" => "hands.revoke"} = map) do
    Data.decode_fields(map, ~w(instance turn), fn [instance, turn] ->
      check(%{t: :revoke, instance: instance, turn: turn})
    end)
  end

  def decode(%{"t" => "hands.stop"} = map) do
    Data.decode_fields(map, ~w(instance release_ms), fn [instance, release_ms] ->
      check(%{t: :stop, instance: instance, release_ms: release_ms})
    end)
  end

  def decode(%{"t" => "hands.read"} = map) do
    Data.decode_fields(map, ~w(instance read paths max_bytes), fn
      [instance, read, paths, max] ->
        with {:ok, read} <- read(read) do
          check(%{t: :read, instance: instance, read: read, paths: paths, max_bytes: max})
        end
    end)
  end

  def decode(_map), do: :error

  defp read("read"), do: {:ok, :read}
  defp read("list"), do: {:ok, :list}
  defp read(_read), do: :error
end
