defmodule Helyx.Message do
  @moduledoc """
  One message in a conversation: from the user, from the assistant, or a tool
  result. Content is a list of blocks. The shape is provider neutral and
  follows ADR 0001; the field names are the ones `docs/features/coding-agent.md`
  lists under the session file.

  A tool result message links to its call with `tool_call_id` and `tool_name`,
  and flags a failed call with `is_error`.

  The module also defines the rules of the values in a message and in a
  turn: the stop reason set, the resume id, the JSON round trip,
  and the integer limit. It does not check input. Its callers are the
  boundaries: the session and its stream check input against these rules,
  and the session file reader checks the disk against them.
  """

  defmodule Text do
    @moduledoc "A text content block."
    @enforce_keys [:text]
    defstruct [:text]
    @type t :: %__MODULE__{text: String.t()}
  end

  defmodule Thinking do
    @moduledoc "A thinking block. `signature` is set when the provider sends one."
    @enforce_keys [:thinking]
    defstruct [:thinking, :signature]
    @type t :: %__MODULE__{thinking: String.t(), signature: String.t() | nil}
  end

  defmodule ToolCall do
    @moduledoc "A tool call block. `arguments` is the decoded argument map."
    @enforce_keys [:id, :name, :arguments]
    defstruct [:id, :name, :arguments]
    @type t :: %__MODULE__{id: String.t(), name: String.t(), arguments: map()}
  end

  defmodule Image do
    @moduledoc "An image block with base64 `data`."
    @enforce_keys [:mime_type, :data]
    defstruct [:mime_type, :data]
    @type t :: %__MODULE__{mime_type: String.t(), data: String.t()}
  end

  @enforce_keys [:role, :content]
  defstruct [
    :role,
    :content,
    :model,
    :stop_reason,
    :tool_call_id,
    :tool_name,
    is_error: false,
    usage: %{}
  ]

  @type block :: Text.t() | Thinking.t() | ToolCall.t() | Image.t()
  @type role :: :user | :assistant | :tool_result
  @typedoc "A stream event that `add_block/2` adds to assistant content."
  @type block_event ::
          {:text_delta, String.t()} | {:thinking_delta, String.t()} | {:tool_call, ToolCall.t()}
  @type t :: %__MODULE__{
          role: role(),
          content: [block()],
          model: String.t() | nil,
          stop_reason: atom() | nil,
          tool_call_id: String.t() | nil,
          tool_name: String.t() | nil,
          is_error: boolean(),
          usage: map()
        }

  @doc "Builds a user message with one text block."
  @spec user(String.t()) :: t()
  def user(text) when is_binary(text), do: %__MODULE__{role: :user, content: [%Text{text: text}]}

  @doc """
  Builds the tool result message for a call from `{:ok, text}` or
  `{:error, text}`. The text is valid UTF-8: the hands repair the output of
  a tool, and `Helyx.Session.Stream` repairs a tool result of a provider.
  """
  @spec tool_result(ToolCall.t(), {:ok, String.t()} | {:error, String.t()}) :: t()
  def tool_result(%ToolCall{} = call, {:ok, text}), do: tool_result(call, text, false)
  def tool_result(%ToolCall{} = call, {:error, text}), do: tool_result(call, text, true)

  defp tool_result(%ToolCall{id: id, name: name}, text, is_error) when is_binary(text) do
    %__MODULE__{
      role: :tool_result,
      tool_call_id: id,
      tool_name: name,
      is_error: is_error,
      content: [%Text{text: text}]
    }
  end

  # A closed set: the session file encodes it. The session closes the
  # partial message of an aborted or a failed turn with `:aborted` or
  # `:error`; a provider normalizes its wire protocol into the rest, and
  # the session guards stream events with the rest. A session file reader decodes a stop
  # reason outside the set as nil, so an older reader reads a new stop
  # reason as no stop reason.
  @stop_reasons [:end_turn, :tool_use, :max_tokens, :aborted, :error]

  # The bundled providers give a UUID as the resume id, alone or with a
  # short suffix; 256 bytes leaves room for the ids of another provider.
  @resume_id_max_bytes 256

  @typedoc "A stop reason of a message end, one of `stop_reasons/0`."
  @type stop_reason ::
          unquote(@stop_reasons |> Enum.reverse() |> Enum.reduce(&{:|, [], [&1, &2]}))

  @doc "The stop reasons of a message end: the closed set of `t:stop_reason/0`."
  @spec stop_reasons() :: [stop_reason()]
  def stop_reasons, do: @stop_reasons

  @doc """
  Whether `id` is a valid resume id: valid UTF-8 of 1 to
  #{@resume_id_max_bytes} bytes. The session checks an id from a provider
  with it before the id is written, and a resume does not use the id of an
  entry that fails it.
  """
  @spec resume_id?(term()) :: boolean()
  def resume_id?(id),
    do: is_binary(id) and byte_size(id) in 1..@resume_id_max_bytes and String.valid?(id)

  @doc """
  Whether the value round-trips to the session file, which holds only JSON.

  It rejects text that is not valid UTF-8, and a term JSON cannot encode,
  such as a tuple, a pid, or a non-string, non-atom map key. Used at the
  provider-stream boundary for a turn's usage, where the value is arbitrary
  and must survive the write to disk; a tool call's fields get the same
  check from `encoded_size/1`, which also gives their size.
  """
  @spec encodable?(term()) :: boolean()
  def encodable?(value), do: encoded_size(value) != :error

  @doc """
  The byte size of the JSON encode of the value, or `:error` for a value
  that `encodable?/1` rejects.
  """
  @spec encoded_size(term()) :: {:ok, non_neg_integer()} | :error
  def encoded_size(value) do
    {:ok, byte_size(JSON.encode!(value))}
  rescue
    _ -> :error
  end

  # 100 digits is far above every integer a tool can use: a 64-bit value has
  # at most 20 digits. The JSON encode of an integer is quadratic in its
  # digits (185 ms for 100,000 digits, 18.7 s for 1,000,000). With this limit
  # the worst arguments that the 10 MiB limit on tool call bytes permits,
  # 103,819 integers of 100 digits, encode in about 50 ms (#79).
  @max_integer_digits 100
  @integer_limit 10 ** @max_integer_digits
  @integer_marker "integer of more than #{@max_integer_digits} digits removed"

  @doc """
  The digit limit of `cap_integers/1`.
  """
  @spec max_integer_digits() :: pos_integer()
  def max_integer_digits, do: @max_integer_digits

  @doc """
  Replaces every integer of more than #{@max_integer_digits} digits in the
  value with a short marker string. `big_integer?/1` tells whether the
  value holds such an integer.

  The walk covers every compound term: maps with their keys (JSON writes an
  integer key as its digits), lists, tuples, and structs. A struct that holds
  such an integer in a field becomes the marker as a whole, because a struct
  with a string in an integer field is not a valid struct; JSON encodes some
  structs, such as `Date`. A tuple is walked because the error reason of a
  malformed stream event holds the value, and `inspect/1` makes digit text too.

  Callers apply this before any JSON encode, because the encode time is
  quadratic in the digits. The walk compares each integer with a constant
  and never makes digit text, so its time is linear in the size of the value.
  """
  @spec cap_integers(term()) :: term()
  # `@integer_limit` is the first integer over the digit limit.
  def cap_integers(value) when is_integer(value) and abs(value) >= @integer_limit,
    do: @integer_marker

  def cap_integers(%_{} = struct),
    do: if(big_integer?(struct), do: @integer_marker, else: struct)

  def cap_integers(value) when is_map(value),
    do: Map.new(value, fn {key, val} -> {cap_integers(key), cap_integers(val)} end)

  def cap_integers(value) when is_tuple(value),
    do: value |> Tuple.to_list() |> cap_integers() |> List.to_tuple()

  # The head-tail walk never raises on an improper list.
  def cap_integers([head | tail]), do: [cap_integers(head) | cap_integers(tail)]
  def cap_integers(value), do: value

  @doc """
  Tells whether the value holds an integer of more than
  #{@max_integer_digits} digits, with the walk of `cap_integers/1`. It
  builds no term, so it suits a value that is rejected as a whole.
  """
  @spec big_integer?(term()) :: boolean()
  def big_integer?(value) when is_integer(value), do: abs(value) >= @integer_limit
  def big_integer?(%_{} = struct), do: big_integer?(Map.from_struct(struct))

  def big_integer?(value) when is_map(value),
    do: Enum.any?(value, fn {key, val} -> big_integer?(key) or big_integer?(val) end)

  def big_integer?(value) when is_tuple(value), do: big_integer?(Tuple.to_list(value))
  def big_integer?([head | tail]), do: big_integer?(head) or big_integer?(tail)
  def big_integer?(_value), do: false

  @doc """
  Makes the text of a tool result valid UTF-8: every invalid byte becomes
  U+FFFD, so the text can grow up to three times. The session applies it at
  each boundary of tool text, the hands and a provider's `tool_result`.
  Valid text, the common case, is returned without a copy.
  """
  @spec scrub({status, String.t()}) :: {status, String.t()} when status: :ok | :error
  def scrub({status, text}) do
    if String.valid?(text), do: {status, text}, else: {status, String.replace_invalid(text)}
  end

  @doc """
  Adds a stream delta to a reversed block list, newest first. Consecutive
  deltas of one kind extend the head block. The session and every client
  build assistant content with this, so the delta vocabulary lives in one
  place.
  """
  @spec add_block([block()], block_event()) :: [block()]
  def add_block([%Text{text: t} = b | rest], {:text_delta, d}), do: [%{b | text: t <> d} | rest]
  def add_block(blocks, {:text_delta, d}), do: [%Text{text: d} | blocks]

  def add_block([%Thinking{thinking: t} = b | rest], {:thinking_delta, d}),
    do: [%{b | thinking: t <> d} | rest]

  def add_block(blocks, {:thinking_delta, d}), do: [%Thinking{thinking: d} | blocks]
  def add_block(blocks, {:tool_call, %ToolCall{} = call}), do: [call | blocks]

  @doc "Concatenates the text blocks of a message. Other blocks are skipped."
  @spec text(t()) :: String.t()
  def text(%__MODULE__{content: content}) do
    for %Text{text: text} <- content, into: "", do: text
  end
end
