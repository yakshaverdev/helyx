defmodule Helyx.Session.Input do
  @moduledoc false
  # The checks of client input at the session API: the cwd, the model, and the
  # provider options of a start or a resume, the other options of a start, the
  # origin and the text of a send, and the JSON object of an answer, which also
  # checks the request of a tool (docs/features/coding-agent.md,
  # docs/features/message-identity.md). Inner code trusts them.

  alias Helyx.Message

  # The most bytes of a user text (#672).
  @max_text_bytes 4 * 1_048_576

  @spec max_text_bytes() :: pos_integer()
  def max_text_bytes, do: @max_text_bytes

  # The cwd goes into the session file as JSON, into the system prompt, and to
  # programs, which cut a string at a NUL byte.
  @spec cwd(term()) :: {:ok, String.t()} | {:error, :invalid_cwd}
  def cwd(cwd) when is_binary(cwd) do
    if String.valid?(cwd) and not String.contains?(cwd, <<0>>),
      do: {:ok, cwd},
      else: {:error, :invalid_cwd}
  end

  def cwd(_cwd), do: {:error, :invalid_cwd}

  @spec cwd_option(keyword()) :: {:ok, String.t()} | {:error, :invalid_cwd}
  def cwd_option(opts), do: opts |> Keyword.get_lazy(:cwd, &File.cwd!/0) |> cwd()

  # The folder of the session file: none, or the folder of the Core, whose
  # lock covers it (docs/features/session-lock.md).
  @spec sessions_dir(Helyx.Core.name(), keyword()) ::
          {:ok, String.t() | nil} | {:error, {:invalid_option, :sessions_dir}}
  def sessions_dir(core, opts) do
    case opts[:sessions_dir] do
      nil ->
        {:ok, nil}

      dir ->
        if dir == Helyx.Core.config(core, :sessions_dir),
          do: {:ok, dir},
          else: {:error, {:invalid_option, :sessions_dir}}
    end
  end

  # Every `init/3` of the session gets them as they are: a provider checks the
  # keys that it reads (docs/features/harness-no-state.md).
  @spec provider_opts(keyword()) :: {:ok, keyword()} | {:error, :invalid_provider_opts}
  def provider_opts(opts) do
    provider_opts = Keyword.get(opts, :provider_opts, [])

    if Keyword.keyword?(provider_opts),
      do: {:ok, provider_opts},
      else: {:error, :invalid_provider_opts}
  end

  # The start options that a resume does not take: `:parent`, the link to the
  # call that started a child, for the header, `:tools`, the names of the tools,
  # nil for all (docs/features/agent-tool.md), `:model_context`, nil for the
  # first (docs/features/session-model-context.md), and `:max_output_tokens`,
  # nil for none (docs/features/output-limit.md).
  @spec start_options(Helyx.Core.name(), keyword()) ::
          {:ok, map() | nil, [String.t()] | nil, module() | nil, pos_integer() | nil}
          | {:error,
             :invalid_parent
             | :invalid_tools
             | :invalid_model_context
             | :invalid_max_output_tokens}
  def start_options(core, opts) do
    with {:ok, parent} <- parent(opts[:parent]),
         {:ok, names} <- tools(opts[:tools]),
         {:ok, model_context} <- model_context(core, opts[:model_context]),
         {:ok, limit} <- max_output_tokens(opts[:max_output_tokens]),
         do: {:ok, parent, names, model_context, limit}
  end

  # The call id bound keeps the header far under the head that a scan reads.
  @max_call_id_bytes 256

  @doc false
  # The parent link of a start: `%{session_id:, call_id:}`. The option takes
  # only this map, so a header map is refused here and read by
  # `header_parent/1` (docs/features/agent-tool.md).
  @spec parent(term()) :: {:ok, Helyx.Sessions.Live.parent()} | {:error, :invalid_parent}
  def parent(nil), do: {:ok, nil}

  def parent(%{session_id: session_id, call_id: call_id} = parent)
      when map_size(parent) == 2,
      do: parent?(session_id, call_id)

  def parent(_parent), do: {:error, :invalid_parent}

  @doc false
  # The parent link of the header of a session file, which has string keys:
  # `%{"session_id" => id, "call_id" => id}`. A caller drops a link that
  # fails, so a damaged header link costs the session no resume.
  def header_parent(nil), do: {:ok, nil}

  def header_parent(%{"session_id" => session_id, "call_id" => call_id} = header)
      when map_size(header) == 2,
      do: parent(%{session_id: session_id, call_id: call_id})

  def header_parent(_link), do: {:error, :invalid_parent}

  defp parent?(session_id, call_id)
       when is_binary(call_id) and byte_size(call_id) in 1..@max_call_id_bytes do
    if Helyx.Session.Id.valid?(session_id) and String.valid?(call_id),
      do: {:ok, %{session_id: session_id, call_id: call_id}},
      else: {:error, :invalid_parent}
  end

  defp parent?(_session_id, _call_id), do: {:error, :invalid_parent}

  defp tools(nil), do: {:ok, nil}

  defp tools(names) when is_list(names) do
    if not List.improper?(names) and Enum.all?(names, &is_binary/1),
      do: {:ok, names},
      else: {:error, :invalid_tools}
  end

  defp tools(_names), do: {:error, :invalid_tools}

  # nil stays nil: the session resolves it to the first one at its start
  # (`Helyx.Session.Server.Open`).
  defp model_context(_core, nil), do: {:ok, nil}

  defp model_context(core, module) do
    if module in Helyx.Core.plugins(core, Helyx.ModelContext),
      do: {:ok, module},
      else: {:error, :invalid_model_context}
  end

  # The largest signed 32-bit integer: a server that reads the field as an
  # integer takes it (docs/features/output-limit.md).
  @max_output_tokens 2_147_483_647

  defp max_output_tokens(nil), do: {:ok, nil}

  defp max_output_tokens(limit) when is_integer(limit) and limit in 1..@max_output_tokens,
    do: {:ok, limit}

  defp max_output_tokens(_limit), do: {:error, :invalid_max_output_tokens}

  # The tools of a start or a resume: the checked specs of `Helyx.Tool.specs/2`,
  # the tool sources, none with a list `only` (docs/features/mcp-client.md), and
  # the `check/0` of both.
  def tools(core, only) do
    plugins = Helyx.Core.plugins(core, Helyx.Tool)
    sources = if only, do: [], else: Enum.filter(plugins, &Helyx.Tool.source?/1)
    labelled = for source <- sources, do: {source, %{name: inspect(source)}}

    with {:ok, tools} <- Helyx.Tool.specs(core, only),
         :ok <- Helyx.Tool.check_available(tools ++ labelled),
         do: {:ok, tools, sources}
  end

  # A model ref string to its parsed ref and its provider plugin, for a start, a
  # resume, and a switch alike. With a limit, the provider must apply it
  # (docs/features/output-limit.md).
  @spec model(Helyx.Core.name(), String.t(), pos_integer() | nil) ::
          {:ok, {Helyx.ModelRef.t(), module()}} | {:error, Helyx.Session.model_error()}
  def model(core, string, limit \\ nil) do
    with {:ok, ref} <- Helyx.ModelRef.parse(string),
         {:ok, provider} <- Helyx.Provider.find(core, ref.provider),
         :ok <- limit(limit == nil or limit_supported?(core, provider), ref.provider),
         do: {:ok, {ref, provider}}
  end

  # Core read the callback at start, so no plugin code runs here.
  @spec limit_supported?(Helyx.Core.name(), module()) :: boolean()
  def limit_supported?(core, provider), do: provider in Helyx.Core.limit_providers(core)

  # Whether a session's limit allows the provider of the ref prefix `id`.
  @spec limit(boolean(), String.t()) ::
          :ok | {:error, {:max_output_tokens_unsupported, String.t()}}
  def limit(true, _id), do: :ok
  def limit(false, id), do: {:error, {:max_output_tokens_unsupported, id}}

  # Product code may set only `:product`.
  @spec origin(keyword()) :: {:ok, Message.origin()} | {:error, :invalid_origin}
  def origin([]), do: {:ok, %{kind: :user, id: nil}}

  def origin(origin: %{kind: :product} = origin),
    do: if(Message.origin?(origin), do: {:ok, origin}, else: {:error, :invalid_origin})

  def origin(_opts), do: {:error, :invalid_origin}

  # The size first, so the UTF-8 check reads at most the bound.
  @spec text(binary()) :: :ok | {:error, :text_too_large | :invalid_utf8}
  def text(text) when byte_size(text) > @max_text_bytes, do: {:error, :text_too_large}
  def text(text), do: if(String.valid?(text), do: :ok, else: {:error, :invalid_utf8})

  # A JSON object as a JSON decoder gives it: string keys, values that are
  # strings, numbers, booleans, nil, lists, and such objects, every string valid
  # UTF-8, and no integer over the digit limit, whose encode is quadratic. Its
  # JSON encode is at most `max` bytes. One walk counts the bytes of the encode
  # and stops past `max` (docs/features/question-tool.md).
  @spec json_object(term(), pos_integer()) :: :ok | :error
  def json_object(value, max) when is_map(value) do
    case size(value, max) do
      left when is_integer(left) and left >= 0 -> :ok
      _error_or_past -> :error
    end
  end

  def json_object(_value, _max), do: :error

  # `left` less the bytes of the encode of `value`, or :error. A negative
  # `left` stops the walk at the next value.
  defp size(_value, left) when left < 0, do: :error
  defp size(value, _left) when is_struct(value), do: :error

  # A string is at least its bytes and two quotes: one past the bound is
  # neither read nor encoded.
  defp size(value, left) when is_binary(value) do
    if byte_size(value) + 2 <= left and String.valid?(value),
      do: left - byte_size(JSON.encode!(value)),
      else: :error
  end

  # An integer over the digit limit is not encoded: its encode is quadratic.
  defp size(value, left) when is_number(value) or is_boolean(value) or is_nil(value),
    do: if(Message.big_integer?(value), do: :error, else: left - byte_size(JSON.encode!(value)))

  # The brackets, then each item, with a comma before each but the first.
  defp size(value, left) when is_list(value), do: items(value, left - 2, 0)

  defp size(value, left) when is_map(value),
    do: pairs(:maps.next(:maps.iterator(value)), left - 2, 0)

  defp size(_value, _left), do: :error

  defp items([], left, _comma), do: left

  defp items([value | rest], left, comma) do
    with left when is_integer(left) <- size(value, left - comma), do: items(rest, left, 1)
  end

  defp items(_improper_tail, _left, _comma), do: :error

  # The map is read one key at a time, so a large map is never listed.
  defp pairs(:none, left, _comma), do: left

  defp pairs({key, value, next}, left, comma) when is_binary(key) do
    with left when is_integer(left) <- size(key, left - comma - 1),
         left when is_integer(left) <- size(value, left),
         do: pairs(:maps.next(next), left, 1)
  end

  defp pairs(_pair, _left, _comma), do: :error
end
