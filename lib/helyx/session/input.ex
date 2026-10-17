defmodule Helyx.Session.Input do
  @moduledoc false
  # The checks of client input at the session API: the cwd of a start or a
  # resume, the child options of a start, and the origin and the text of a
  # send (docs/features/coding-agent.md, "Bounds";
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
