defmodule Helyx.Session.Input do
  @moduledoc false
  # The checks of client input at the session API: the cwd and the model
  # of a start or a resume, the child options of a start, the origin and
  # the text of a send, and the JSON object of an answer, which also checks
  # the request of a tool (docs/features/coding-agent.md, "Bounds";
  # docs/features/message-identity.md). Inner code trusts them.

  alias Helyx.Message

  # The most bytes of a user text (#672).
  @max_text_bytes 4 * 1_048_576

  @spec max_text_bytes() :: pos_integer()
  def max_text_bytes, do: @max_text_bytes

  # The cwd goes into the session file as JSON, into the system prompt, and
  # to programs, which cut a string at a NUL byte.
  @spec cwd(term()) :: {:ok, String.t()} | {:error, :invalid_cwd}
  def cwd(cwd) when is_binary(cwd) do
    if String.valid?(cwd) and not String.contains?(cwd, <<0>>),
      do: {:ok, cwd},
      else: {:error, :invalid_cwd}
  end

  def cwd(_cwd), do: {:error, :invalid_cwd}

  # The start options of a child session: `:parent`, the link to the call
  # that started it, for the header, and `:tools`, the names of the tools
  # that it gets, nil for all (docs/features/agent-tool.md, "Bounds").
  @spec child(keyword()) ::
          {:ok, map() | nil, [String.t()] | nil} | {:error, :invalid_parent | :invalid_tools}
  def child(opts) do
    with {:ok, parent} <- parent(opts[:parent]),
         {:ok, names} <- tools(opts[:tools]),
         do: {:ok, parent, names}
  end

  # The call id bound keeps the header far under the head that a scan reads.
  @max_call_id_bytes 256

  defp parent(nil), do: {:ok, nil}

  defp parent(%{session_id: session_id, call_id: call_id} = parent)
       when map_size(parent) == 2 and is_binary(call_id) and
              byte_size(call_id) in 1..@max_call_id_bytes do
    if Helyx.Session.Id.valid?(session_id) and String.valid?(call_id),
      do: {:ok, parent},
      else: {:error, :invalid_parent}
  end

  defp parent(_parent), do: {:error, :invalid_parent}

  defp tools(nil), do: {:ok, nil}

  defp tools(names) when is_list(names) do
    if not List.improper?(names) and Enum.all?(names, &is_binary/1),
      do: {:ok, names},
      else: {:error, :invalid_tools}
  end

  defp tools(_names), do: {:error, :invalid_tools}

  # A model ref string to its parsed ref and its provider plugin, for a
  # start, a resume, and a switch alike.
  @spec model(Helyx.Core.name(), String.t()) ::
          {:ok, {Helyx.ModelRef.t(), module()}} | {:error, Helyx.Session.model_error()}
  def model(core, string) do
    with {:ok, ref} <- Helyx.ModelRef.parse(string),
         {:ok, provider} <- Helyx.Provider.find(core, ref.provider),
         do: {:ok, {ref, provider}}
  end

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

  # A JSON object as a JSON decoder gives it: string keys, and values that
  # are strings, numbers, booleans, nil, lists, and such objects; every
  # string valid UTF-8, and no integer over the digit limit, whose encode is
  # quadratic. Its JSON encode is at most `max` bytes. One walk counts the
  # bytes of the encode and stops past `max`, so a larger value costs no
  # more than the bound (docs/features/question-tool.md, "Bounds").
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
