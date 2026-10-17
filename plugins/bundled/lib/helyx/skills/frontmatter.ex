defmodule Helyx.Skills.Frontmatter do
  @moduledoc false
  # The reader of a `SKILL.md` frontmatter: the YAML between two `---`
  # lines, of which it reads only the top-level keys `name` and
  # `description`. It fails closed: it accepts a strict subset of YAML and
  # rejects any other text with the number of its line, so it is never
  # wider than YAML. The value of every other key is not read, except that
  # its quotes and brackets must close. The time is linear in the bytes.
  # The subset is in docs/features/skills.md.

  @keys ["name", "description"]
  @frontmatter ~r/\A---[ \t]*\r?\n((?:.*?\r?\n)?)---[ \t]*(?:\r?\n|\z)/s
  # A key line: the key, and the value without the blanks before it.
  @key ~r/\A([A-Za-z0-9_][A-Za-z0-9_-]*):(?: [ \t]*|\z)(.*)\z/
  # Every character but a tab, a line feed, and the printable characters
  # of YAML 1.2 without the line breaks of YAML 1.1 (U+0085, U+2028,
  # U+2029) and U+FEFF.
  @control ~r/[^\t\n\x{20}-\x{7E}\x{A0}-\x{2027}\x{202A}-\x{D7FF}\x{E000}-\x{FEFE}\x{FF00}-\x{FFFD}\x{10000}-\x{10FFFF}]/u
  # The text after a closing quote or a block header: blanks or a comment.
  @tail "(?:[ \\t]*|[ \\t]+#.*)"
  @after_quote ~r/\A#{@tail}\z/
  @block ~r/\A([|>])([-+]?)#{@tail}\z/
  # A plain value that starts with a YAML indicator is out, also `-`, `?`,
  # and `:`: YamlElixir rejects some of those that YAML 1.2 reads.
  @indicator ~r/\A[-?:@`%,\]}]/
  @colon ~r/:(?:[ \t]|\z)/
  @comment ~r/\A *(?:#|\z)/
  # The plain scalars that the YAML 1.2 core schema reads as a null, a
  # boolean, or a number, and any that starts as a number does: YamlElixir
  # reads `+`, `0x`, and `+0x1` as numbers too.
  @not_string ~r/\A(?:~|null|Null|NULL|true|True|TRUE|false|False|FALSE|[-+]?\.(?:inf|Inf|INF)|\.(?:nan|NaN|NAN)|[-+]?(?:0[xo][0-9a-fA-F]*|[0-9][0-9a-fA-F._xoeE+-]*|\.[0-9][0-9._eE+-]*)?)\z/
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
  # `content`, or the error of its first line outside the subset.
  @spec read(String.t()) :: {:ok, %{String.t() => String.t()}} | {:error, String.t()}
  def read(content) do
    case Regex.run(@frontmatter, strip_bom(content)) do
      [_, yaml] ->
        lines = yaml |> String.split(["\r\n", "\n"]) |> Enum.drop(-1)
        with {:ok, values} <- lines(Enum.with_index(lines, 2), nil, %{}), do: missing(values)

      nil ->
        {:error, "no frontmatter between two --- lines"}
    end
  end

  defp strip_bom(<<0xFEFF::utf8, rest::binary>>), do: rest
  defp strip_bom(content), do: content

  defp missing(values) do
    case Enum.reject(@keys, &Map.has_key?(values, &1)) do
      [] -> {:ok, values}
      [key | _] -> {:error, "the frontmatter has no #{key} string"}
    end
  end

  defp error(n, why), do: {:error, "line #{n}: #{why}"}

  # One pass over the numbered lines. The open key is `{:read, key, n,
  # value, lines}` for `name` and `description`, `{:skip, key, n, scan}`
  # for another key, or nil.
  defp lines([], open, values), do: close(open, values)

  defp lines([{line, n} | rest], open, values) do
    case {kind(line), open} do
      {:indented, nil} ->
        error(n, "an indented line with no key above it")

      {kind, _open} when kind in [:blank, :indented] ->
        lines(rest, add(open, line, n), values)

      # A comment at column 0 ends `name` or `description`. In another key
      # it must not be inside a quote or a bracket.
      {:comment, {:skip, _key, _n, _scan}} ->
        with {:ok, values} <- close(open, values), do: lines(rest, open, values)

      {:comment, _open} ->
        with {:ok, values} <- close(open, values), do: lines(rest, nil, values)

      {{:key, key, value}, _open} ->
        with {:ok, values} <- close(open, values),
             {:ok, open} <- open(key, value, n, values),
             do: lines(rest, open, values)

      {{:out, why}, _open} ->
        error(n, why)
    end
  end

  defp kind(line) do
    if Regex.match?(@control, line),
      do: {:out, "a control character"},
      else: kind(line, String.trim_leading(line, " "))
  end

  # `text` is `line` without its leading spaces. YamlElixir rejects some
  # lines with a tab after the indentation that YAML 1.2 reads.
  defp kind(_line, ""), do: :blank

  defp kind(line, "\t" <> _ = text) when line != text,
    do: {:out, "a tab after the indentation"}

  defp kind(line, text) when line != text, do: :indented
  defp kind("#" <> _, _text), do: :comment

  defp kind(line, _text) do
    case Regex.run(@key, line) do
      [_, key, value] -> {:key, key, value}
      nil -> {:out, "not a key line, a comment, or a blank line"}
    end
  end

  defp open(key, value, n, values) when key in @keys do
    if Map.has_key?(values, key),
      do: error(n, "the key #{key} is there twice"),
      else: {:ok, {:read, key, n, value, []}}
  end

  # The lines of a block scalar are text: no quote or bracket opens there.
  defp open(key, <<c, _::binary>>, n, _values) when c in [?|, ?>],
    do: {:ok, {:skip, key, n, :block}}

  defp open(key, value, n, _values) do
    case scan(value, :blank, {:plain, 0}) do
      {:plain, 0} -> {:ok, {:skip, key, n, {:plain, 0}}}
      _open -> error(n, "the value of #{key} does not close on its line")
    end
  end

  defp add({:read, key, n, value, lines}, line, m),
    do: {:read, key, n, value, [{line, m} | lines]}

  defp add({:skip, _key, _n, :block} = open, _line, _m), do: open
  defp add({:skip, key, n, scan}, line, _m), do: {:skip, key, n, scan(line, :blank, scan)}
  defp add(nil, _line, _m), do: nil

  defp close(nil, values), do: {:ok, values}

  defp close({:skip, _key, _n, scan}, values) when scan in [:block, {:plain, 0}],
    do: {:ok, values}

  defp close({:skip, key, n, _scan}, _values),
    do: error(n, "a quote or a bracket in the value of #{key} does not close")

  defp close({:read, key, n, value, lines}, values) do
    case value(value, Enum.reverse(lines)) do
      {:ok, text} -> {:ok, Map.put(values, key, text)}
      {:error, {m, why}} -> error(m, "the #{key} #{why}")
      {:error, why} -> error(n, "the #{key} #{why}")
    end
  end

  # The state of the quotes and brackets of another key after `text`:
  # `{:plain | :single | :double, depth}`, or :error for a bracket that
  # closes none. A quote opens only where a YAML scalar can start, and a
  # bracket counts anywhere outside a quote, so the scan can find an open
  # value where YAML has none, but never the reverse. `prev` is :blank
  # after a blank or at the line start, :start after a flow indicator, and
  # :text after any other character.
  defp scan(_text, _prev, :error), do: :error
  defp scan(<<>>, _prev, state), do: state
  defp scan(<<?#, _::binary>>, :blank, {:plain, _} = state), do: state

  defp scan(<<q, rest::binary>>, prev, {:plain, depth}) when q in [?', ?"] and prev != :text,
    do: scan(rest, :text, {if(q == ?', do: :single, else: :double), depth})

  defp scan(<<c, rest::binary>>, _prev, {:plain, depth}) when c in [?[, ?{],
    do: scan(rest, :start, {:plain, depth + 1})

  defp scan(<<c, _::binary>>, _prev, {:plain, 0}) when c in [?], ?}], do: :error

  defp scan(<<c, rest::binary>>, _prev, {:plain, depth}) when c in [?], ?}],
    do: scan(rest, :text, {:plain, depth - 1})

  defp scan(<<c, rest::binary>>, _prev, {:plain, _} = state) when c in [?\s, ?\t],
    do: scan(rest, :blank, state)

  defp scan(<<c, rest::binary>>, _prev, {:plain, _} = state) when c in [?,, ?:],
    do: scan(rest, :start, state)

  defp scan(<<?', ?', rest::binary>>, prev, {:single, _} = state), do: scan(rest, prev, state)
  defp scan(<<?', rest::binary>>, _prev, {:single, depth}), do: scan(rest, :text, {:plain, depth})
  defp scan(<<?\\, _, rest::binary>>, prev, {:double, _} = state), do: scan(rest, prev, state)
  defp scan(<<?", rest::binary>>, _prev, {:double, depth}), do: scan(rest, :text, {:plain, depth})
  defp scan(<<_, rest::binary>>, _prev, state), do: scan(rest, :text, state)

  # The value of `name` or `description`: a plain or a quoted scalar on the
  # key line, or a block scalar on the indented lines after it.
  defp value("", lines), do: empty(lines)
  defp value("#" <> _comment, lines), do: empty(lines)

  defp value(<<c, _::binary>>, _lines) when c in [?&, ?*, ?!],
    do: {:error, "uses an anchor, an alias, or a tag"}

  defp value(<<c, _::binary>>, _lines) when c in [?[, ?{], do: {:error, "is no string"}
  defp value(<<c, _::binary>> = header, lines) when c in [?|, ?>], do: block(header, lines)

  defp value(<<q, rest::binary>>, lines) when q in [?', ?"] do
    with {:ok, text, after_quote} <- quoted(rest, q, []) do
      cond do
        not Regex.match?(@after_quote, after_quote) ->
          {:error, "has text after its closing quote"}

        not comments?(lines) ->
          {:error, "goes on to the next line"}

        true ->
          {:ok, text}
      end
    end
  end

  defp value(value, lines) do
    text = value |> uncomment() |> trim_trailing()

    cond do
      Regex.match?(@indicator, text) ->
        {:error, "starts with a YAML indicator"}

      Regex.match?(@colon, text) ->
        {:error, "has a colon before a blank"}

      Regex.match?(@not_string, text) ->
        {:error, "is no string"}

      not comments?(lines) ->
        {:error, "goes on to the next line"}

      true ->
        {:ok, text}
    end
  end

  defp empty(lines),
    do: {:error, if(comments?(lines), do: "is no string", else: "goes on to the next line")}

  # True when each line is blank or a comment.
  defp comments?(lines), do: Enum.all?(lines, fn {line, _n} -> Regex.match?(@comment, line) end)

  defp uncomment(text) do
    case :binary.match(text, [" #", "\t#"]) do
      {at, _} -> binary_part(text, 0, at)
      :nomatch -> text
    end
  end

  defp blank?(line), do: String.trim_leading(line, " ") == ""

  # YAML blanks are a space and a tab, not every Unicode space. The trim
  # goes by byte, not by grapheme: a space before a combining mark is a
  # blank too. A regex can take quadratic time on a long run of blanks.
  defp trim_trailing(text), do: binary_part(text, 0, text_end(text, byte_size(text)))

  defp text_end(text, n) when n > 0 and binary_part(text, n - 1, 1) in [" ", "\t"],
    do: text_end(text, n - 1)

  defp text_end(_text, n), do: n

  # A quoted scalar that closes on its line: its text and the text after
  # the closing quote.
  defp quoted(<<?', ?', rest::binary>>, ?', acc), do: quoted(rest, ?', [acc, ?'])
  defp quoted(<<q, rest::binary>>, q, acc), do: {:ok, IO.iodata_to_binary(acc), rest}

  defp quoted(<<?\\, rest::binary>>, ?", acc) do
    case escape(rest) do
      {:ok, char, rest} -> quoted(rest, ?", [acc, char])
      :error -> {:error, "has an escape that YAML does not have"}
    end
  end

  defp quoted(<<c::utf8, rest::binary>>, q, acc), do: quoted(rest, q, [acc, <<c::utf8>>])
  defp quoted(<<>>, _q, _acc), do: {:error, "has a quote that does not close on its line"}

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

  # A block scalar: indented lines with no tab, at least one with text,
  # each line with text indented at least as far as the first one, and no
  # line of only spaces longer than that indentation. A literal keeps its
  # line breaks, a folded one folds them; the chomping indicator decides
  # the line breaks at the end.
  defp block(header, lines) do
    # A folded block with keep chomping is out: YamlElixir does not read its
    # last line breaks as YAML 1.2 does.
    with [_, style, chomp] <-
           Regex.run(@block, header) || {:error, "has a block header that Helyx does not read"},
         true <- [style, chomp] != [">", "+"] || {:error, "is a folded block with keep chomping"},
         :ok <- no_tab(lines),
         {:ok, prefix} <- indent(lines),
         {:ok, reversed} <- unindent(lines, prefix, []) do
      {trailing, reversed} = Enum.split_while(reversed, &(&1 == ""))
      body = Enum.reverse(reversed)
      text = if style == "|", do: Enum.join(body, "\n"), else: fold(body)
      {:ok, chomp(text, chomp, length(trailing))}
    end
  end

  defp no_tab(lines) do
    case Enum.find(lines, fn {line, _n} -> String.contains?(line, "\t") end) do
      nil -> :ok
      {_line, n} -> {:error, {n, "has a tab in its block"}}
    end
  end

  # The indentation of the first line with text, as a prefix of spaces.
  defp indent(lines) do
    case Enum.find(lines, fn {line, _n} -> not blank?(line) end) do
      nil ->
        {:error, "is a block with no text line"}

      {line, _n} ->
        {:ok, binary_part(line, 0, byte_size(line) - byte_size(String.trim_leading(line, " ")))}
    end
  end

  # The lines without their indentation, in reverse order.
  defp unindent([], _prefix, acc), do: {:ok, acc}

  defp unindent([{line, n} | rest], prefix, acc) do
    cond do
      not blank?(line) and String.starts_with?(line, prefix) ->
        unindent(rest, prefix, [binary_slice(line, byte_size(prefix)..-1//1) | acc])

      not blank?(line) ->
        {:error, {n, "has a line indented less than its first line"}}

      byte_size(line) > byte_size(prefix) ->
        {:error, {n, "has a line of spaces longer than its indentation"}}

      true ->
        unindent(rest, prefix, ["" | acc])
    end
  end

  defp chomp(text, "-", _trailing), do: text
  defp chomp(text, "", _trailing), do: text <> "\n"
  defp chomp(text, "+", trailing), do: text <> String.duplicate("\n", trailing + 1)

  # Folds lines: a line break between two text lines is a space, and each
  # empty line is a line break. Next to a line that starts with a space,
  # the line breaks stay.
  defp fold(lines), do: fold(lines, nil, 0, [])

  defp fold([], _prev, _empty, acc), do: IO.iodata_to_binary(Enum.reverse(acc))
  defp fold(["" | rest], prev, empty, acc), do: fold(rest, prev, empty + 1, acc)

  defp fold([line | rest], prev, empty, acc) do
    kind = if String.starts_with?(line, " "), do: :spaced, else: :text
    fold(rest, kind, 0, [line, separator(prev, kind, empty) | acc])
  end

  defp separator(nil, _kind, empty), do: String.duplicate("\n", empty)
  defp separator(:text, :text, 0), do: " "
  defp separator(:text, :text, empty), do: String.duplicate("\n", empty)
  defp separator(_prev, _kind, empty), do: String.duplicate("\n", empty + 1)
end
