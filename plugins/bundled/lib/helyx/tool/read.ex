defmodule Helyx.Tool.Read do
  @moduledoc """
  Reads a file. Long files keep the head, and the result says which absolute
  lines it shows and, when lines follow them, which offset continues the
  read; `offset` reads from a later line.

  An `offset` that is not a positive integer is an error, never a silent
  default. A float with no fraction, such as `2001.0`, is its integer. A
  missing or null `offset` is line 1.

  An `offset` after the last line is an error that names the offset and the
  line count, so an offset that is too large does not look like an empty
  file. The error shows an offset above 1,000,000,000 as `over 1000000000`.
  The line rule is that of `Helyx.Text.truncate/3`: one trailing newline
  ends the last line, and more are blank lines that count. An offset at a
  trailing blank line is thus an ok result, and it can be empty. The empty
  file is the one exception to that rule: it has 0 lines here. Only line 1 of
  it reads, as an empty ok result.
  """

  @behaviour Helyx.Tool

  # No file within the size limit of `Helyx.Text.read_file/1` has this many
  # lines. The error shows no offset above it, and `truncate/3` gets no offset
  # above it, so neither the text nor the time grows with the digits of a
  # large integer.
  @max_shown_offset 1_000_000_000

  @impl true
  def name, do: "read"

  @impl true
  def description do
    "Read a file. Returns at most #{Helyx.Text.max_lines()} lines or " <>
      "#{div(Helyx.Text.max_bytes(), 1024)} KB, starting at offset " <>
      "(a 1-based line number, default 1); a truncated result names the " <>
      "offset that continues the read, when lines follow."
  end

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "path" => %{
          "type" => "string",
          "description" => "File path, absolute or relative to the working directory"
        },
        "offset" => %{"type" => "integer", "description" => "First line to return, 1-based"}
      },
      "required" => ["path"]
    }
  end

  @impl true
  def run(%{"path" => path} = args, cwd) when is_binary(path) do
    with {:ok, offset} <- offset(args["offset"]) do
      case Helyx.Text.read_file(Path.expand(path, cwd)) do
        {:ok, content} -> window(content, offset, path)
        {:error, reason} -> {:error, "cannot read #{path}: #{reason}"}
      end
    end
  end

  def run(_args, _cwd), do: {:error, "read needs a path"}

  # Every offset after the last line gives an empty window, so only an empty
  # window past line 1 pays for the line count. An empty window at a blank
  # line is an ok result.
  defp window(content, offset, path) do
    case Helyx.Text.truncate(content, :head, min(offset, @max_shown_offset)) do
      "" when offset > 1 -> empty_window(line_count(content), offset, path)
      window -> {:ok, window}
    end
  end

  defp empty_window(total, offset, path) when offset > total do
    {:error,
     "offset #{offset_text(offset)} is after the last line: " <>
       "#{path} has #{line_count_text(total)}"}
  end

  defp empty_window(_total, _offset, _path), do: {:ok, ""}

  # The line rule of `Helyx.Text.truncate/3`, but an empty file has 0 lines:
  # one trailing newline ends the last line. It walks the bytes and builds no
  # list, so a file of 10 MiB of newlines costs no memory here.
  defp line_count(""), do: 0

  defp line_count(content) do
    newlines = newlines(content, 0)
    if String.ends_with?(content, "\n"), do: newlines, else: newlines + 1
  end

  defp newlines(<<?\n, rest::binary>>, n), do: newlines(rest, n + 1)
  defp newlines(<<_byte, rest::binary>>, n), do: newlines(rest, n)
  defp newlines(<<>>, n), do: n

  defp offset_text(offset) when offset > @max_shown_offset, do: "over #{@max_shown_offset}"
  defp offset_text(offset), do: Integer.to_string(offset)

  defp line_count_text(1), do: "1 line"
  defp line_count_text(n), do: "#{n} lines"

  defp offset(nil), do: {:ok, 1}
  defp offset(n) when is_integer(n) and n > 0, do: {:ok, n}
  # The JSON encoders of some models send `2001.0` for 2001 (#75).
  defp offset(f) when is_float(f) and f >= 1.0 and trunc(f) == f, do: {:ok, trunc(f)}

  defp offset(other) do
    {:error, "offset must be a positive integer (a 1-based line number), got #{kind(other)}"}
  end

  # The error names the kind of the value and never shows the value, so its
  # size and its cost do not depend on the argument.
  defp kind(n) when is_integer(n), do: "an integer below 1"
  defp kind(f) when is_float(f), do: "a number that is not a whole number of 1 or more"
  defp kind(s) when is_binary(s), do: "a string"
  defp kind(b) when is_boolean(b), do: "a boolean"
  defp kind(l) when is_list(l), do: "an array"
  defp kind(_other), do: "an object"
end
