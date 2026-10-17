defmodule Helyx.Session.Input do
  @moduledoc false
  # The checks of client input at the session API: the cwd of a start or a
  # resume, and the origin and the text of a send (docs/features/coding-agent.md,
  # "Bounds"; docs/features/message-identity.md). Inner code trusts them.

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
end
