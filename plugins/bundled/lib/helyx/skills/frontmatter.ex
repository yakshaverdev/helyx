defmodule Helyx.Skills.Frontmatter do
  @moduledoc false
  # The reader of a `SKILL.md` frontmatter: the YAML between two `---`
  # lines, of which it reads only the top-level keys `name` and
  # `description`. A value is a plain, a single-quoted, or a double-quoted
  # scalar, or a literal (`|`) or folded (`>`) block scalar with its
  # chomping and indentation indicators. Every other top-level key is
  # skipped with its indented lines, unread. An anchor, an alias, or a tag
  # in a value that it reads is an error, so no value expands, and the time
  # is linear in the bytes. The forms that are out are in
  # docs/features/skills.md.

  @keys ["name", "description"]
  @frontmatter ~r/\A---[ \t]*\r?\n((?:.*?\r?\n)?)---[ \t]*(?:\r?\n|\z)/s
  # A plain key and its value: a `:` in the key has no blank after it. The
  # key classes are possessive, so a long line is read once.
  @key ~r/\A((?:[^\s#'"\[\]{},&*!|>%@`?:\-]|[?:\-](?=\S))(?:[^:]|:(?=\S))*+):(?:[ \t]+(.*))?\z/
  @quoted_key ~r/\A("(?:[^"\\]|\\.)*+"|'(?:[^']|'')*+')[ \t]*:(?:[ \t]+(.*))?\z/
  @block ~r/\A([|>])([1-9]?)([-+]?)([1-9]?)[ \t]*(?:#.*)?\z/
  # The plain scalars that YAML reads as a null, a boolean, or a number.
  @not_string ~r/\A(?:~|null|Null|NULL|true|True|TRUE|false|False|FALSE|[-+]?[0-9]+|0o[0-7]+|0x[0-9a-fA-F]+|[-+]?(?:\.[0-9]+|[0-9]+(?:\.[0-9]*)?)(?:[eE][-+]?[0-9]+)?|[-+]?\.(?:inf|Inf|INF)|\.(?:nan|NaN|NAN))\z/
  @not_map "the frontmatter is not a map of keys"
  @escapes %{
    ?0 => 0,
    ?a => 7,
    ?b => 8,
    ?t => 9,
    ?\t => 9,
    ?n => 10,
    ?v => 11,
    ?f => 12,
    ?r => 13,
    ?e => 27,
    ?\s => 32,
    ?" => 34,
    ?/ => 47,
    ?\\ => 92,
    ?N => 0x85,
    ?_ => 0xA0,
    ?L => 0x2028,
    ?P => 0x2029
  }
  @hex %{?x => 2, ?u => 4, ?U => 8}

  # The string values of `name` and `description` in the frontmatter of
  # `content`, or the error of the first key that has none.
  @spec read(String.t()) :: {:ok, %{String.t() => String.t()}} | {:error, String.t()}
  def read(content) do
    case Regex.run(@frontmatter, strip_bom(content)) do
      [_, yaml] ->
        lines = yaml |> String.replace("\r\n", "\n") |> String.replace_suffix("\n", "")

        with {:ok, entries} <- entries(String.split(lines, "\n"), nil, %{}),
             do: values(entries)

      nil ->
        {:error, "no frontmatter between two --- lines"}
    end
  end

  defp strip_bom(<<0xFEFF::utf8, rest::binary>>), do: rest
  defp strip_bom(content), do: content

  # The top-level keys that Helyx reads, each with the text after its colon
  # and its indented lines. Another key is `:skip`, and its lines are
  # dropped as they come.
  defp entries([], current, acc), do: put(current, acc)
  defp entries([line | rest], current, acc), do: entry(kind(line), line, rest, current, acc)

  defp entry(:blank, line, rest, current, acc), do: entries(rest, add(current, line), acc)

  defp entry(:indented, _line, _rest, nil, _acc), do: {:error, @not_map}

  defp entry(:indented, line, rest, current, acc), do: entries(rest, add(current, line), acc)

  # A comment at column 0 ends a value that has begun: no line of it can
  # follow.
  defp entry(:comment, _line, rest, {_key, "", []} = current, acc),
    do: entries(rest, current, acc)

  defp entry(:comment, _line, rest, {_key, _value, _lines} = current, acc) do
    with {:ok, acc} <- put(current, acc), do: entries(rest, nil, acc)
  end

  defp entry(:comment, _line, rest, current, acc), do: entries(rest, current, acc)
  defp entry(:other, _line, _rest, _current, _acc), do: {:error, @not_map}

  defp entry({:key, key, value}, _line, rest, current, acc) do
    with {:ok, acc} <- put(current, acc), do: entries(rest, open(key, value), acc)
  end

  defp kind(line) do
    cond do
      skip_blanks(line) == "" -> :blank
      String.starts_with?(line, [" ", "\t"]) -> :indented
      String.starts_with?(line, "#") -> :comment
      true -> key(Regex.run(@key, line), line)
    end
  end

  defp key([_, key | value], _line), do: {:key, trim(key, :trailing), head(value)}

  defp key(nil, line) do
    with [_, <<q, key::binary>> | value] <- Regex.run(@quoted_key, line),
         {:ok, key} <- quoted(key, [], q) do
      {:key, key, head(value)}
    else
      _ -> :other
    end
  end

  defp open(key, value) when key in @keys, do: {key, value, []}
  defp open(_key, _value), do: :skip

  # Before a value begins, its blank and comment lines are dropped.
  defp add({key, "", []} = current, line) do
    if blank?(line), do: current, else: {key, "", [line]}
  end

  defp add({key, value, lines}, line), do: {key, value, [line | lines]}
  defp add(current, _line), do: current

  defp put({key, value, lines}, acc) do
    if Map.has_key?(acc, key),
      do: {:error, "the frontmatter has the key #{key} twice"},
      else: {:ok, Map.put(acc, key, {value, Enum.reverse(lines)})}
  end

  defp put(_current, acc), do: {:ok, acc}

  defp values(entries) do
    Enum.reduce_while(@keys, {:ok, %{}}, fn key, {:ok, acc} ->
      case Map.fetch(entries, key) do
        :error -> value(key, {:error, :not_string}, acc)
        {:ok, {value, lines}} -> value(key, scalar(value, lines), acc)
      end
    end)
  end

  defp value(key, {:ok, text}, acc), do: {:cont, {:ok, Map.put(acc, key, text)}}

  defp value(key, {:error, why}, _acc) do
    {:halt,
     {:error,
      case why do
        :not_string -> "the frontmatter has no #{key} string"
        :node -> "the #{key} uses an anchor, an alias, or a tag"
        :invalid -> "the #{key} is not valid YAML"
      end}}
  end

  # The text after the colon, trimmed; a comment there is no value.
  defp head([]), do: ""

  defp head([value]) do
    case trim(value) do
      "#" <> _comment -> ""
      value -> value
    end
  end

  # A value on the line of its key, or on the first indented line after it
  # that is neither blank nor a comment (`add/2` dropped those). A key, `-`,
  # or `?` there starts a collection; on the key line, `-` and `?` are no
  # YAML.
  defp scalar("", []), do: {:error, :not_string}

  defp scalar("", [first | rest]) do
    first = trim(first)

    if Regex.match?(@key, first) or collection?(first),
      do: {:error, :not_string},
      else: node(first, rest)
  end

  defp scalar(value, lines) do
    if collection?(value), do: {:error, :invalid}, else: node(value, lines)
  end

  defp collection?(text), do: text in ["-", "?"] or String.starts_with?(text, ["- ", "? "])

  defp node(<<c, _::binary>>, _lines) when c in [?&, ?*, ?!], do: {:error, :node}
  defp node(<<c, _::binary>>, _lines) when c in [?[, ?{], do: {:error, :not_string}
  defp node(<<q, rest::binary>>, lines) when q in [?', ?"], do: quoted(rest, lines, q)
  defp node(<<c, _::binary>> = header, lines) when c in [?|, ?>], do: block(header, lines)
  defp node(first, lines), do: plain([first | lines])

  # A plain scalar: its lines without comments, folded.
  defp plain(lines) do
    text = lines |> Enum.map(&(&1 |> uncomment() |> trim())) |> fold()

    if text == "" or Regex.match?(@not_string, text),
      do: {:error, :not_string},
      else: {:ok, text}
  end

  defp blank?(line), do: skip_blanks(uncomment(line)) == ""

  # YAML blanks are a space and a tab, not every Unicode space.
  defp trim(text, where \\ :both), do: :string.trim(text, where, ~c" \t")

  defp uncomment(line) do
    case {trim(line, :leading), :binary.match(line, [" #", "\t#"])} do
      {"#" <> _, _} -> ""
      {_, {at, _}} -> binary_part(line, 0, at)
      {_, :nomatch} -> line
    end
  end

  # A quoted scalar, which can go on over the indented lines. After the
  # closing quote only blanks and comments follow.
  defp quoted(text, lines, q) do
    with {:ok, value, after_quote} <- quote_text(Enum.join([text | lines], "\n"), q, [], ""),
         true <- after_quote |> String.split("\n") |> Enum.all?(&blank?/1) do
      {:ok, value}
    else
      _ -> {:error, :invalid}
    end
  end

  # The text up to the closing quote `q`. Blanks are held in `ws` until a
  # character follows, so that the blanks before a line break are dropped;
  # a line break folds to a space, and each empty line after it to a line
  # break.
  defp quote_text(<<?', ?', rest::binary>>, ?', acc, ws),
    do: quote_text(rest, ?', [acc, ws, ?'], "")

  defp quote_text(<<q, rest::binary>>, q, acc, ws),
    do: {:ok, IO.iodata_to_binary([acc, ws]), rest}

  # An escaped line break is dropped, with the blanks after it; the empty
  # lines after it stay.
  defp quote_text(<<?\\, ?\n, rest::binary>>, ?", acc, ws) do
    {empty, rest} = empty_lines(rest, 0)
    quote_text(rest, ?", [acc, ws, String.duplicate("\n", empty)], "")
  end

  defp quote_text(<<?\\, rest::binary>>, ?", acc, ws) do
    case escape(rest) do
      {:ok, char, rest} -> quote_text(rest, ?", [acc, ws, char], "")
      :error -> :error
    end
  end

  defp quote_text(<<?\n, rest::binary>>, q, acc, _ws) do
    {empty, rest} = empty_lines(rest, 0)
    fold = if empty == 0, do: " ", else: String.duplicate("\n", empty)
    quote_text(rest, q, [acc, fold], "")
  end

  defp quote_text(<<c, rest::binary>>, q, acc, ws) when c in [?\s, ?\t],
    do: quote_text(rest, q, acc, <<ws::binary, c>>)

  defp quote_text(<<c::utf8, rest::binary>>, q, acc, ws),
    do: quote_text(rest, q, [acc, ws, <<c::utf8>>], "")

  defp quote_text(<<>>, _q, _acc, _ws), do: :error

  defp empty_lines(text, count) do
    case skip_blanks(text) do
      <<?\n, rest::binary>> -> empty_lines(rest, count + 1)
      rest -> {count, rest}
    end
  end

  defp skip_blanks(<<c, rest::binary>>) when c in [?\s, ?\t], do: skip_blanks(rest)
  defp skip_blanks(text), do: text

  defp escape(<<c, rest::binary>>) when is_map_key(@escapes, c),
    do: {:ok, <<Map.fetch!(@escapes, c)::utf8>>, rest}

  defp escape(<<c, rest::binary>>) when is_map_key(@hex, c) do
    size = Map.fetch!(@hex, c)

    with <<digits::binary-size(size), rest::binary>> <- rest,
         true <- Regex.match?(~r/\A[0-9a-fA-F]+\z/, digits),
         code = String.to_integer(digits, 16),
         true <- code < 0xD800 or code in 0xE000..0x10FFFF do
      {:ok, <<code::utf8>>, rest}
    else
      _ -> :error
    end
  end

  defp escape(_text), do: :error

  # A block scalar: the indented lines without their indentation, which is
  # the indicator or that of the first line that is not blank. A literal
  # keeps its line breaks, a folded one folds them; the chomping indicator
  # decides the line breaks at the end.
  defp block(header, lines) do
    with [_, style, digit, chomp, digit2] <- Regex.run(@block, header),
         indicator when byte_size(indicator) <= 1 <- digit <> digit2,
         indent = indent(indicator, lines),
         {:ok, body} <- unindent(lines, String.duplicate(" ", indent), []) do
      {trailing, body} = body |> Enum.reverse() |> Enum.split_while(&(&1 == ""))
      body = Enum.reverse(body)
      text = if style == "|", do: Enum.join(body, "\n"), else: fold(body)
      {:ok, chomp(text, body, chomp, length(trailing))}
    else
      _ -> {:error, :invalid}
    end
  end

  defp indent("", lines) do
    case Enum.find(lines, &(skip_blanks(&1) != "")) do
      nil -> 1
      line -> max(byte_size(line) - byte_size(String.trim_leading(line, " ")), 1)
    end
  end

  defp indent(digit, _lines), do: String.to_integer(digit)

  defp unindent([], _indent, acc), do: {:ok, Enum.reverse(acc)}

  defp unindent([line | rest], indent, acc) do
    cond do
      String.starts_with?(line, indent) ->
        unindent(rest, indent, [String.replace_prefix(line, indent, "") | acc])

      skip_blanks(line) == "" ->
        unindent(rest, indent, ["" | acc])

      true ->
        :error
    end
  end

  defp chomp(_text, [], "+", trailing), do: String.duplicate("\n", trailing)
  defp chomp(_text, [], _chomp, _trailing), do: ""
  defp chomp(text, _body, "-", _trailing), do: text
  defp chomp(text, _body, "", _trailing), do: text <> "\n"
  defp chomp(text, _body, "+", trailing), do: text <> String.duplicate("\n", trailing + 1)

  # Folds lines: a line break between two text lines is a space, and each
  # empty line is a line break. Next to a line that starts with a blank,
  # the line breaks stay. Empty lines at the end are dropped.
  defp fold(lines), do: fold(lines, nil, 0, [])

  defp fold([], _prev, _empty, acc), do: IO.iodata_to_binary(Enum.reverse(acc))
  defp fold(["" | rest], prev, empty, acc), do: fold(rest, prev, empty + 1, acc)

  defp fold([line | rest], prev, empty, acc) do
    kind = if String.starts_with?(line, [" ", "\t"]), do: :spaced, else: :text
    fold(rest, kind, 0, [line, separator(prev, kind, empty) | acc])
  end

  defp separator(nil, _kind, empty), do: String.duplicate("\n", empty)
  defp separator(:text, :text, 0), do: " "
  defp separator(:text, :text, empty), do: String.duplicate("\n", empty)
  defp separator(_prev, _kind, empty), do: String.duplicate("\n", empty + 1)
end
