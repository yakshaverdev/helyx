defmodule Helyx.Tool.Edit do
  @moduledoc """
  Replaces one occurrence of text in a file. The search text must appear
  exactly once; zero or several matches is an error and the file is
  untouched. With no exact match, the text is matched again after Unicode
  NFKC, quote, dash, line end, and trailing space normalization; only the
  matched range changes. A leading BOM and CRLF line ends stay. See
  `docs/features/fuzzy-edit.md`.
  """

  @behaviour Helyx.Tool

  @impl true
  def name, do: "edit"

  @impl true
  def description do
    "Replace old_text with new_text in a file. old_text must match exactly once, " <>
      "so include enough surrounding lines to make it unique."
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
        "old_text" => %{"type" => "string", "description" => "Exact text to replace"},
        "new_text" => %{"type" => "string", "description" => "Replacement text"}
      },
      "required" => ["path", "old_text", "new_text"]
    }
  end

  @impl true
  def run(%{"path" => path, "old_text" => old, "new_text" => new}, cwd)
      when is_binary(path) and is_binary(old) and is_binary(new) do
    full = Path.expand(path, cwd)

    with :ok <- valid_utf8(old, new),
         {:ok, content} <- read(full, path),
         {bom, text} = split_bom(content),
         {:ok, from, to} <- locate(text, strip_bom(old), path),
         edited = splice(text, from, to, line_ends(strip_bom(new), text, from)),
         :ok <- write(full, bom <> edited, path) do
      {:ok, "Edited #{path}"}
    end
  end

  def run(_args, _cwd), do: {:error, "edit needs a path, old_text, and new_text"}

  defp valid_utf8(old, new) do
    if String.valid?(old) and String.valid?(new),
      do: :ok,
      else: {:error, "old_text and new_text must be valid UTF-8"}
  end

  defp split_bom(<<0xEF, 0xBB, 0xBF, text::binary>>), do: {<<0xEF, 0xBB, 0xBF>>, text}
  defp split_bom(text), do: {<<>>, text}

  defp strip_bom(text), do: String.replace_prefix(text, "\uFEFF", "")

  # A file whose first line end is CRLF gets CRLF in the new text too. A CR
  # just before the range already pairs with a leading LF of the new text.
  defp line_ends(new, text, from) do
    case next_line(text) do
      {_line, 2, _rest} ->
        crlf = String.replace(new, ["\r\n", "\n"], "\r\n")
        cr_before = from > 0 and :binary.at(text, from - 1) == ?\r

        if cr_before and String.starts_with?(new, "\n"),
          do: binary_slice(crlf, 1..-1//1),
          else: crlf

      _lf ->
        new
    end
  end

  defp locate(_text, "", _path), do: {:error, "old_text is empty"}

  defp locate(text, old, path) do
    case find(text, old) do
      {:one, pos, len} -> {:ok, pos, pos + len}
      :none -> locate_normalized(text, old, path)
      :many -> ambiguous(path)
    end
  end

  defp locate_normalized(text, old, path) do
    with norm_old when norm_old != "" <- normalize(old),
         norm = normalize(text),
         {:one, pos, len} <- find(norm, norm_old),
         {:ok, from} <- offset(text, norm, 0, 0, pos, :start),
         {:ok, to} <- offset(text, norm, 0, 0, pos + len, :end) do
      {:ok, from, to}
    else
      :many -> ambiguous(path)
      # An empty normalized old_text, no match, or a match inside a cluster.
      _not_found -> {:error, "old_text not found in #{path}"}
    end
  end

  defp ambiguous(path),
    do: {:error, "old_text matches more than once in #{path}; make it unique"}

  defp find(haystack, needle) do
    case :binary.match(haystack, needle) do
      :nomatch ->
        :none

      {pos, len} ->
        # A second match may overlap the first, so the search restarts one
        # byte after the start of the first match, not after its end.
        scope = {pos + 1, byte_size(haystack) - pos - 1}

        if :binary.match(haystack, needle, scope: scope) == :nomatch,
          do: {:one, pos, len},
          else: :many
    end
  end

  defp splice(text, from, to, new),
    do: binary_part(text, 0, from) <> new <> binary_part(text, to, byte_size(text) - to)

  # Lines collect in a chunk that moves to a list past 64 KiB; see the
  # bounds of `docs/features/fuzzy-edit.md`.
  defp normalize(text), do: normalize(text, <<>>, [])

  defp normalize(text, chunk, chunks) when byte_size(chunk) > 65_536,
    do: normalize(text, <<>>, [chunk | chunks])

  defp normalize(text, chunk, chunks) do
    case next_line(text) do
      {line, _end, nil} ->
        IO.iodata_to_binary(Enum.reverse(chunks, [chunk, norm_line(line)]))

      {line, _end, rest} ->
        normalize(rest, <<chunk::binary, norm_line(line)::binary, ?\n>>, chunks)
    end
  end

  # The first line without its end, the byte size of the end (LF 1, CRLF 2),
  # and the rest, nil after the last line. A lone CR is text.
  defp next_line(text) do
    case :binary.match(text, "\n") do
      :nomatch ->
        {text, 0, nil}

      {pos, 1} ->
        <<line::binary-size(pos), ?\n, rest::binary>> = text

        case line do
          <<body::binary-size(pos - 1), ?\r>> -> {body, 2, rest}
          _ -> {line, 1, rest}
        end
    end
  end

  defp norm_line(line),
    do: trim_trailing(if ascii?(line), do: line, else: norm_graphemes(line, <<>>))

  defp ascii?(<<a, rest::binary>>) when a < 128, do: ascii?(rest)
  defp ascii?(rest), do: rest == <<>>

  defp norm_graphemes(line, acc) do
    case next_grapheme(line) do
      nil -> acc
      {g, rest} -> norm_graphemes(rest, <<acc::binary, norm(g)::binary>>)
    end
  end

  # An ASCII byte before another ASCII byte is a grapheme cluster alone (a
  # line holds no CR LF), so most text skips the Unicode segmentation.
  defp next_grapheme(<<a, b, _::binary>> = line) when a < 128 and b < 128,
    do: {<<a>>, binary_part(line, 1, byte_size(line) - 1)}

  defp next_grapheme(line), do: String.next_grapheme(line)

  defp norm(<<_ascii>> = g), do: g

  defp norm(g) do
    for <<c::utf8 <- :unicode.characters_to_nfkc_binary(g)>>, into: <<>>, do: plain(c)
  end

  defp plain(c) when c in 0x2018..0x201B, do: "'"
  defp plain(c) when c in 0x201C..0x201F, do: "\""
  defp plain(c) when c in 0x2010..0x2015 or c == 0x2212, do: "-"
  defp plain(c), do: <<c::utf8>>

  # The trim can cut the normalized form of a cluster: a Prepend character
  # joins the space after it (U+0600 then a space). `boundary/5` caps its
  # offsets at the trimmed length for that.
  defp trim_trailing(s), do: binary_part(s, 0, kept(s, byte_size(s)))

  defp kept(s, n) when n > 0 and binary_part(s, n - 1, 1) in [" ", "\t"], do: kept(s, n - 1)
  defp kept(_s, n), do: n

  # The original byte offset of normalized offset `target`, from a walk over
  # the lines of the text and of its normalized form `norm` in step, so no
  # offset table is held. A start takes the last such offset and an end the
  # first, so trailing spaces next to the match stay. An offset inside the
  # normalized form of one grapheme cluster is :error.
  defp offset(text, norm, o, n, target, side) do
    {line, end_size, rest} = next_line(text)

    nl =
      case :binary.match(norm, "\n", scope: {n, byte_size(norm) - n}) do
        {pos, 1} -> pos - n
        :nomatch -> byte_size(norm) - n
      end

    cond do
      target > n + nl ->
        offset(rest, norm, o + byte_size(line) + end_size, n + nl + 1, target, side)

      target == n + nl and side == :start ->
        {:ok, o + byte_size(line)}

      true ->
        boundary(line, target - n, o, 0, nl)
    end
  end

  defp boundary(_line, t, k, t, _nl), do: {:ok, k}
  defp boundary(_line, t, _k, nk, _nl) when nk > t, do: :error

  defp boundary(line, t, k, nk, nl) do
    {g, rest} = next_grapheme(line)
    boundary(rest, t, k + byte_size(g), min(nk + byte_size(norm(g)), nl), nl)
  end

  defp read(full, path) do
    with {:error, reason} <- Helyx.Text.read_file(full) do
      {:error, "cannot read #{path}: #{reason}"}
    end
  end

  defp write(full, content, path) do
    with {:error, reason} <- File.write(full, content) do
      {:error, "cannot write #{path}: #{:file.format_error(reason)}"}
    end
  end
end
