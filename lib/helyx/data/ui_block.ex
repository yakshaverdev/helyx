defmodule Helyx.UIBlock do
  @moduledoc """
  The check and the cut of a UI block (ADR 0011, `docs/features/ui-blocks.md`).

  A UI block is a JSON object with string keys: `"kind"`, a name of 1 to 64
  bytes of `a`-`z`, `0`-`9`, and `_`; `"text"`, its fallback text; `"cut"`,
  a boolean when present; and the fields of its kind, which Core does not
  read. Its bound is
  `Helyx.Message.max_result_bytes/0` bytes of JSON encode. A block over the
  bound becomes `%{"kind" => kind, "text" => cut_text, "cut" => true}`.
  """

  alias Helyx.Message

  @type t :: %{required(String.t()) => term()}

  @max_bytes Message.max_result_bytes()
  # The blocks of one tool result, and the keys of `:ui_block` events for
  # one call id or for nil in one turn (`docs/features/ui-blocks.md`).
  @max_result_blocks 8
  @max_keys 8
  # The blocks of `:ui_block` events that one turn holds at once, as the
  # snapshot gives them: the keys of 8 calls and of nil.
  @max_turn_blocks 72
  @max_kind_bytes 64
  @max_key_bytes 64
  # The bytes that the JSON encode escapes, as the pattern of
  # `:binary.matches/2`: the quote, the backslash, and the control
  # characters, as two bytes or as six (`\u00XX`).
  @escaped Enum.map([?", ?\\ | Enum.to_list(0..31)], &<<&1>>)
  @short [?", ?\\, ?\b, ?\f, ?\n, ?\r, ?\t]
  @cut_marker "\n[… cut …]\n"

  @doc "The byte bound of the JSON encode of one UI block."
  @spec max_bytes() :: pos_integer()
  def max_bytes, do: @max_bytes

  @doc "The most UI blocks of one tool result."
  @spec max_result_blocks() :: pos_integer()
  def max_result_blocks, do: @max_result_blocks

  @doc "The most keys of `:ui_block` events for one call id, or for nil in one turn."
  @spec max_keys() :: pos_integer()
  def max_keys, do: @max_keys

  @doc "The most blocks of `:ui_block` events that one turn holds at once."
  @spec max_turn_blocks() :: pos_integer()
  def max_turn_blocks, do: @max_turn_blocks

  @doc """
  Checks the UI blocks of a tool result: a proper list of at most
  #{@max_result_blocks} blocks that `check/1` takes. `{:ok, blocks}` with
  each block over the bound cut, or `:error`.
  """
  @spec check_list(term()) :: {:ok, [t()]} | :error
  def check_list(blocks) when is_list(blocks) do
    if List.improper?(blocks) or length(blocks) > @max_result_blocks,
      do: :error,
      else: check_each(blocks, [])
  end

  def check_list(_blocks), do: :error

  defp check_each([], acc), do: {:ok, Enum.reverse(acc)}

  defp check_each([block | rest], acc) do
    with {:ok, block} <- check(block), do: check_each(rest, [block | acc])
  end

  @doc """
  Checks one UI block. `{:ok, block}` for a block within the bound,
  `{:ok, cut}` for one over it, and `:error` for a value that is not a UI
  block: not a map with string keys, an envelope that fails `envelope?/1`,
  a string that is not valid UTF-8, an integer of more than
  `Helyx.Message.max_integer_digits/0` digits, or a term that is not JSON
  (`docs/features/ui-blocks.md`).
  """
  @spec check(term()) :: {:ok, t()} | :error
  def check(value) when is_map(value) and not is_struct(value) do
    with true <- envelope?(value),
         {:ok, bytes} <- size(value) do
      if bytes <= @max_bytes, do: {:ok, value}, else: {:ok, cut(value)}
    else
      _ -> :error
    end
  end

  def check(_value), do: :error

  @doc """
  Whether `map` has the envelope of a UI block: a valid `"kind"`, a string
  `"text"`, and `"cut"` absent or a boolean. It does not check UTF-8 or the
  fields of the kind: `check/1` and the ask check do.
  """
  @spec envelope?(map()) :: boolean()
  def envelope?(%{"kind" => kind, "text" => text} = map) when is_binary(text) do
    kind?(kind) and (not is_map_key(map, "cut") or is_boolean(map["cut"]))
  end

  def envelope?(_map), do: false

  @doc "Whether `value` is a key of a `:ui_block` event: valid UTF-8 of 1 to #{@max_key_bytes} bytes."
  @spec key?(term()) :: boolean()
  def key?(value),
    do: is_binary(value) and byte_size(value) in 1..@max_key_bytes and String.valid?(value)

  defp kind?(kind) when is_binary(kind) and byte_size(kind) in 1..@max_kind_bytes,
    do: kind |> :binary.bin_to_list() |> Enum.all?(&(&1 in ?a..?z or &1 in ?0..?9 or &1 == ?_))

  defp kind?(_kind), do: false

  # The bytes of the JSON encode of a value, or :error. It walks the whole
  # value: a value past the bound is still checked.
  defp size(value) when is_binary(value) do
    if String.valid?(value), do: {:ok, string_bytes(value)}, else: :error
  end

  # An integer over the digit limit is not encoded: its encode is quadratic.
  defp size(value) when is_integer(value) do
    if Message.big_integer?(value),
      do: :error,
      else: {:ok, byte_size(Integer.to_string(value))}
  end

  defp size(value) when is_float(value), do: {:ok, byte_size(JSON.encode!(value))}
  defp size(true), do: {:ok, 4}
  defp size(false), do: {:ok, 5}
  defp size(nil), do: {:ok, 4}
  defp size(value) when is_list(value), do: items(value, 2, 0)
  # The map is read one key at a time, so the walk makes no list of it.
  defp size(value) when is_map(value) and not is_struct(value),
    do: pairs(:maps.next(:maps.iterator(value)), 2, 0)

  defp size(_value), do: :error

  # The brackets, then each item, with a comma before each but the first.
  defp items([], acc, _comma), do: {:ok, acc}

  defp items([value | rest], acc, comma) do
    with {:ok, bytes} <- size(value), do: items(rest, acc + comma + bytes, 1)
  end

  defp items(_improper_tail, _acc, _comma), do: :error

  defp pairs(:none, acc, _comma), do: {:ok, acc}

  defp pairs({key, value, next}, acc, comma) when is_binary(key) do
    with {:ok, key_bytes} <- size(key),
         {:ok, bytes} <- size(value),
         do: pairs(:maps.next(next), acc + comma + key_bytes + 1 + bytes, 1)
  end

  defp pairs(_pairs, _acc, _comma), do: :error

  # The bytes of the JSON string of valid UTF-8, quotes included, with no
  # escaped copy: the encode keeps every other character as it is.
  defp string_bytes(string),
    do: byte_size(string) + 2 + extra(string, :binary.matches(string, @escaped))

  defp extra(string, matches),
    do: Enum.reduce(matches, 0, fn {pos, 1}, acc -> acc + extra_of(:binary.at(string, pos)) end)

  defp extra_of(char) when char in @short, do: 1
  defp extra_of(_char), do: 5

  # The replacement of a block over the bound: its fallback text cut so that
  # the JSON encode of the whole replacement is within the bound.
  defp cut(%{"kind" => kind, "text" => text}) do
    empty = %{"kind" => kind, "text" => "", "cut" => true}
    {:ok, overhead} = size(empty)
    %{empty | "text" => cut_text(text, @max_bytes - overhead)}
  end

  # `room` is the bytes of the JSON string of the text, quotes included.
  defp cut_text(text, room) do
    if string_bytes(text) <= room, do: text, else: cut_long(text, room - 2)
  end

  defp cut_long(text, room) do
    total = byte_size(text)
    # The kept count is at most the total, so the notice with the total in
    # its place is the longest that the cut can make.
    fixed = escaped(notice(total, total)) + escaped(@cut_marker)
    head_room = div(room - fixed, 2)
    tail_room = room - fixed - head_room
    head = binary_part(text, 0, prefix(text, head_room)) |> String.replace_invalid("")
    tail_len = suffix(text, tail_room)
    tail = binary_part(text, total - tail_len, tail_len) |> String.replace_invalid("")
    kept = byte_size(head) + byte_size(tail)
    IO.iodata_to_binary([notice(kept, total), head, @cut_marker, tail])
  end

  defp notice(kept, total), do: "[cut to #{kept} of #{total} bytes, start and end kept]\n"

  # The escaped bytes of a string, without the quotes.
  defp escaped(string), do: string_bytes(string) - 2

  # The most bytes from the start of `text` whose escaped bytes fit `room`.
  # The escaped bytes are at least the raw bytes, so only the first `room`
  # bytes are read.
  defp prefix(text, room) do
    window = min(byte_size(text), room)
    part = binary_part(text, 0, window)
    matches = :binary.matches(part, @escaped)
    walk_prefix(part, matches, 0, window, room)
  end

  defp walk_prefix(_part, [], extra, window, room), do: min(window, room - extra)

  defp walk_prefix(part, [{pos, 1} | rest], extra, window, room) do
    e = extra_of(:binary.at(part, pos))

    cond do
      pos + extra > room -> room - extra
      pos + 1 + extra + e > room -> pos
      true -> walk_prefix(part, rest, extra + e, window, room)
    end
  end

  # The most bytes from the end of `text` whose escaped bytes fit `room`.
  defp suffix(text, room) do
    window = min(byte_size(text), room)
    part = binary_part(text, byte_size(text) - window, window)
    matches = part |> :binary.matches(@escaped) |> Enum.reverse()
    walk_suffix(part, matches, 0, window, room)
  end

  defp walk_suffix(_part, [], extra, window, room), do: min(window, room - extra)

  defp walk_suffix(part, [{pos, 1} | rest], extra, window, room) do
    # The bytes from `pos` to the end of the window, the escaped one included.
    dist = window - pos
    e = extra_of(:binary.at(part, pos))

    cond do
      dist - 1 + extra > room -> room - extra
      dist + extra + e > room -> dist - 1
      true -> walk_suffix(part, rest, extra + e, window, room)
    end
  end
end
