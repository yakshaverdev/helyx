defmodule Helyx.Text do
  @moduledoc false
  # The text helpers of the bundled plugins: a bounded file read and the
  # cut of a tool result. A helper module (ADR 0005): no interface and no
  # registration entry.

  # The cut of a tool result, in lines and in bytes of line content (50
  # KiB): pi's read and bash defaults (`docs/research/coding-tools.md`).
  @max_lines 2000
  @max_bytes 51_200
  # The largest file a tool reads, in bytes (10 MiB): room for any source
  # file, and small enough to load whole.
  @max_file_bytes 10_485_760

  @doc "The line limit of `truncate/2` and `truncate/3`."
  @spec max_lines() :: pos_integer()
  def max_lines, do: @max_lines

  @doc "The byte limit of `truncate/2` and `truncate/3`."
  @spec max_bytes() :: pos_integer()
  def max_bytes, do: @max_bytes

  @doc "The byte limit of `read_file/1`."
  @spec max_file_bytes() :: pos_integer()
  def max_file_bytes, do: @max_file_bytes

  @doc """
  Reads a regular file of at most #{@max_file_bytes} bytes, whole. A device,
  a directory, a larger file, or a file that is not valid UTF-8 is an error,
  so a tool never loads unbounded input and never returns text a later
  encoder cannot handle. The read itself is bounded, so a file that grows
  after the check is still an error. The error is a short reason without
  the path.
  """
  @spec read_file(Path.t()) :: {:ok, String.t()} | {:error, String.t()}
  def read_file(full) do
    case File.stat(full) do
      {:ok, %File.Stat{type: :regular}} -> read_bounded(full)
      {:ok, %File.Stat{type: type}} -> {:error, "not a regular file (#{type})"}
      {:error, reason} -> {:error, to_string(:file.format_error(reason))}
    end
  end

  defp read_bounded(full) do
    case File.open(full, [:read, :binary], &IO.binread(&1, @max_file_bytes + 1)) do
      {:ok, data} -> bounded(data)
      {:error, _} = error -> bounded(error)
    end
  end

  defp bounded(:eof), do: {:ok, ""}
  defp bounded({:error, reason}), do: {:error, to_string(:file.format_error(reason))}

  defp bounded(bin) when byte_size(bin) > @max_file_bytes,
    do: {:error, "over the #{@max_file_bytes}-byte limit"}

  defp bounded(bin) do
    if String.valid?(bin), do: {:ok, bin}, else: {:error, "binary file, #{byte_size(bin)} bytes"}
  end

  @doc """
  Caps text at #{@max_lines} lines or #{@max_bytes} bytes of line content,
  on whole lines. One trailing newline is a terminator and does not count.
  `:head` keeps the start and `:tail` keeps the end. A truncated result says
  which lines it shows; a truncated `:head` result also names the offset that
  continues the read, unless the cut line is the last line. When the line at
  the kept edge is over the byte cap by itself, it is cut to the cap and is
  the only line shown (see `cap/3`); the notice names that line and the
  bytes kept of it, and no offset reaches the rest.
  """
  @spec truncate(String.t(), :head | :tail) :: String.t()
  def truncate(text, :head), do: truncate(text, :head, 1)

  def truncate(text, :tail) do
    lines = lines(text)
    total = length(lines)

    case take_within_limits(Enum.reverse(lines), :tail) do
      :all ->
        text

      {kept, n, cut_bytes} ->
        "[truncated: showing lines #{total - n + 1}-#{total} of #{total}#{cut_note(cut_bytes, total)}]\n" <>
          Enum.join(Enum.reverse(kept), "\n")
    end
  end

  @doc """
  Like `truncate/2` with `:head`, starting at line `first`: earlier lines are
  dropped before the caps apply. A truncated result names the absolute line
  numbers it shows and, when lines follow them, the offset that continues
  the read. A window that starts past line 1 is rebuilt from its lines, so it
  carries no trailing newline.
  """
  @spec truncate(String.t(), :head, pos_integer()) :: String.t()
  def truncate(text, :head, first) do
    shown = Enum.drop(lines(text), first - 1)

    case take_within_limits(shown, :head) do
      :all when first == 1 ->
        text

      :all ->
        Enum.join(shown, "\n")

      {kept, n, cut_bytes} ->
        last = first + n - 1
        total = first - 1 + length(shown)

        Enum.join(kept, "\n") <>
          "\n[truncated: showing lines #{first}-#{last} of #{total}" <>
          "#{cut_note(cut_bytes, first)}#{offset_note(last, total)}]"
    end
  end

  # Only a cut last line is truncated with no line after it; an offset past
  # it returns nothing, so the notice names none.
  defp offset_note(total, total), do: ""
  defp offset_note(last, _total), do: "; read again with offset #{last + 1}"

  # The cut line is always the one at the kept edge: the first line of a
  # head window, the last line of a tail.
  defp cut_note(nil, _line_number), do: ""
  defp cut_note(bytes, line_number), do: ", line #{line_number} cut at #{bytes} bytes"

  # One trailing newline ends the last line; more are blank lines that count.
  defp lines(text), do: text |> String.replace_suffix("\n", "") |> String.split("\n")

  # Returns `:all` when every line fits, else the lines within the limits in
  # the given order, their count, and `nil`. A first line over the byte limit
  # is cut to the limit from the end kept; the third element is then the
  # bytes shown of it.
  defp take_within_limits([first | _], keep) when byte_size(first) > @max_bytes do
    shown = cap(first, @max_bytes, keep)
    {[shown], 1, byte_size(shown)}
  end

  defp take_within_limits(lines, _keep) do
    {count, _bytes, acc} =
      Enum.reduce_while(lines, {0, 0, []}, fn line, {count, bytes, acc} ->
        if count < @max_lines and bytes + byte_size(line) <= @max_bytes,
          do: {:cont, {count + 1, bytes + byte_size(line) + 1, [line | acc]}},
          else: {:halt, {count, bytes, acc}}
      end)

    if count == length(lines), do: :all, else: {Enum.reverse(acc), count, nil}
  end

  @doc """
  Keeps at most `max` bytes of `text`: the start with `:head`, the end with
  `:tail`. The result is valid UTF-8: the cap drops a character it splits
  and every invalid byte.
  """
  @spec cap(binary(), non_neg_integer(), :head | :tail) :: binary()
  def cap(text, max, :head),
    do: text |> binary_part(0, min(max, byte_size(text))) |> String.replace_invalid("")

  def cap(text, max, :tail) do
    kept = min(max, byte_size(text))
    text |> binary_part(byte_size(text) - kept, kept) |> String.replace_invalid("")
  end
end
