defmodule Helyx.TUI.Markdown do
  @moduledoc """
  The Markdown of an assistant reply as screen rows (#487): headings, bullet
  and numbered items, bold, italic, inline code, fenced code, and links as
  their text and address. A row is a list of `{text, tags}`. The text of a
  row is a row of `Helyx.TUI.Wrap.line_rows/2`, so the width rule holds. Pure;
  it needs nothing from `ex_ratatui` (ADR 0005). The rules are in
  `docs/features/coding-agent.md`, "TUI".
  """

  alias Helyx.TUI.Wrap

  @type tag :: :bold | :italic | :underlined | :code
  @type segment :: {String.t(), [tag()]}

  @fence ~r/^ {0,3}(`{3,}|~{3,})(.*)$/
  @fence_end ~r/^ {0,3}(`{3,}|~{3,}) *$/
  @heading ~r/^ {0,3}\#{1,6}(?: +(.*))?$/
  @item ~r/^( *)([-*+]|\d{1,9}[.)]) +(.*)$/
  @code_split ~r/`+/
  # A backslash escape comes first, so an escaped sign is never a delimiter.
  # No class of the link takes a bracket, so a scan for a link stops at the
  # next bracket and the split stays linear.
  @inline_split ~r/\\[[:punct:]]|\[[^\[\]]*\]\([^()\[\] ]*\)|\*+|_+/
  @link ~r/^\[(.*)\]\((.*)\)$/
  @signs ["*", "_", "`", "[", "\\"]
  @word ~r/^[[:alnum:]]/u

  @doc "The rows of `text` at `width` columns, each a list of styled segments."
  @spec rows(String.t(), integer()) :: [[segment()]]
  def rows(text, width) do
    text
    |> Wrap.sanitize()
    |> String.split("\n")
    |> blocks([])
    |> Enum.flat_map(&block_rows(&1, width))
    |> Enum.map(&whole/1)
  end

  # A fence with no closing line is plain text from its line to the end.
  defp blocks([], acc), do: Enum.reverse(acc)

  defp blocks([line | rest], acc) do
    with true <- sign?(line, ~c"`~"),
         [_, run, info] <- Regex.run(@fence, line),
         false <- String.starts_with?(run, "`") and String.contains?(info, "`") do
      case Enum.split_while(rest, &(not closes?(&1, run))) do
        {code, [_close | rest]} -> blocks(rest, Enum.reverse(Enum.map(code, &{:code, &1}), acc))
        {_open, []} -> Enum.reverse(acc, Enum.map([line | rest], &{:plain, &1}))
      end
    else
      _ -> blocks(rest, [{:markdown, line} | acc])
    end
  end

  defp closes?(line, run) do
    case sign?(line, ~c"`~") && Regex.run(@fence_end, line) do
      [_, close] ->
        binary_part(close, 0, 1) == binary_part(run, 0, 1) and byte_size(close) >= byte_size(run)

      _no ->
        false
    end
  end

  # Most lines start with a letter: the first sign after the indent decides
  # whether a block rule can match, so such a line runs no block regex.
  defp sign?(line, signs) do
    case String.trim_leading(line, " ") do
      <<sign, _rest::binary>> -> sign in signs
      "" -> false
    end
  end

  defp block_rows({:plain, line}, width), do: layout([{line, []}], "", width)
  defp block_rows({:code, line}, width), do: layout([{line, [:code]}], "  ", width)

  defp block_rows({:markdown, line}, width) do
    cond do
      heading = sign?(line, ~c"#") && Regex.run(@heading, line) ->
        layout(inline(Enum.at(heading, 1, ""), [:bold]), "", width)

      item = sign?(line, ~c"-*+0123456789") && Regex.run(@item, line) ->
        [_, indent, marker, content] = item
        marker = if marker in ["-", "*", "+"], do: "•", else: marker
        layout(inline(content, []), indent <> marker <> " ", width)

      true ->
        layout(inline(line, []), "", width)
    end
  end

  # A prefix starts the first row and its width in spaces starts the rows
  # after it. A row with a glyph wider than the rest of the width gets no
  # prefix, so that it stays within the width when the glyph does. A prefix
  # as wide as the width wraps as text.
  defp layout(segments, "", width) do
    plain = Enum.map_join(segments, &elem(&1, 0))
    align(segments, Wrap.line_rows(plain, width))
  end

  defp layout(segments, prefix, width) do
    case width - Wrap.columns(prefix) do
      inner when inner < 1 ->
        layout([{prefix, []} | segments], "", width)

      inner ->
        hang = String.duplicate(" ", width - inner)

        segments
        |> layout("", inner)
        |> Enum.with_index(fn
          row, 0 -> start(row, prefix, width)
          row, _index -> start(row, hang, width)
        end)
    end
  end

  # The whole row counts: a mark at the start of the row joins the last
  # space of the prefix into one grapheme.
  defp start(row, start, width) do
    shown = start <> Enum.map_join(row, &elem(&1, 0))

    if byte_size(shown) <= width or Wrap.columns(shown) <= width,
      do: [{start, []} | row],
      else: row
  end

  # The wrap only drops spaces, so each row is the segments in order with
  # some spaces left out. A segment can end inside a row or a grapheme.
  defp align(segments, rows) do
    {lines, _rest} = Enum.map_reduce(rows, segments, &take(&1, &2, []))
    lines
  end

  defp take("", segments, []), do: {[{"", []}], segments}
  defp take("", segments, acc), do: {Enum.reverse(acc), segments}
  defp take(row, [{"", _tags} | segments], acc), do: take(row, segments, acc)

  defp take(row, [{text, tags} | segments], acc) do
    case :binary.longest_common_prefix([row, text]) do
      0 ->
        " " <> text = text
        take(row, [{text, tags} | segments], acc)

      n ->
        <<shown::binary-size(n), text::binary>> = text
        <<_::binary-size(n), row::binary>> = row
        take(row, [{text, tags} | segments], [{shown, tags} | acc])
    end
  end

  # Code spans first, then escapes, links and emphasis signs, which pair as
  # a stack, so a line costs time linear in its length.
  defp inline(text, base) do
    # Fast path: a line with no sign is one segment.
    case :binary.match(text, @signs) do
      :nomatch -> [{text, base}]
      _sign -> parse(text, base)
    end
  end

  defp parse(text, base) do
    text
    |> code_spans()
    |> Enum.flat_map(&tokens/1)
    |> flank()
    |> pair()
    |> emit(base)
    |> merge()
  end

  # A run of backticks opens a code span when a later run has its size. The
  # pass from the end marks those runs, so no run scans the line ahead. A
  # backslash before a run escapes it outside a code span, not inside one.
  # Even parts are text and odd parts are runs, so a text part comes before
  # each run.
  defp code_spans(text) do
    {parts, _sizes} =
      @code_split
      |> Regex.split(text, include_captures: true)
      |> Enum.with_index()
      |> List.foldr({[], MapSet.new()}, fn
        {run, index}, {parts, sizes} when rem(index, 2) == 1 ->
          {[{:run, run, MapSet.member?(sizes, run)} | parts], MapSet.put(sizes, run)}

        {part, _index}, {parts, sizes} ->
          {[{:text, part} | parts], sizes}
      end)

    spans(parts, [])
  end

  defp spans([], acc), do: Enum.reverse(acc)

  defp spans([{:run, run, pairs?} | rest], [{:text, before} | acc]) do
    cond do
      escaped?(before) ->
        spans(rest, [{:text, before <> run} | acc])

      pairs? ->
        {code, [_close | rest]} = Enum.split_while(rest, &(not match?({:run, ^run, _}, &1)))
        spans(rest, [{:code, Enum.map_join(code, &elem(&1, 1))}, {:text, before} | acc])

      true ->
        spans(rest, [{:text, run}, {:text, before} | acc])
    end
  end

  defp spans([text | rest], acc), do: spans(rest, [text | acc])

  defp escaped?(text),
    do: rem(byte_size(text) - byte_size(String.trim_trailing(text, "\\")), 2) == 1

  defp tokens({:code, _text} = code), do: [code]

  defp tokens({:text, text}) do
    @inline_split
    |> Regex.split(text, include_captures: true)
    |> Enum.with_index()
    |> Enum.flat_map(fn
      {"", _index} ->
        []

      {part, index} when rem(index, 2) == 0 ->
        [{:text, part}]

      {<<"\\", sign::binary>>, _index} ->
        [{:text, sign}]

      {"[" <> _ = link, _index} ->
        [_link, label, url] = Regex.run(@link, link)
        [{:link, label, url}]

      {run, _index} ->
        [{:run, run}]
    end)
  end

  # A sign opens when no space follows it and closes when no space comes
  # before it; `_` also not inside a word. Three signs are both styles, in
  # the order that nests; more stay text.
  defp flank([]), do: []

  defp flank(tokens) do
    [[nil | tokens], tokens, tl(tokens) ++ [nil]]
    |> Enum.zip()
    |> Enum.flat_map(fn
      {before, {:run, run}, next} -> delimiters(run, side(before, :last), side(next, :first))
      {_before, token, _next} -> [token]
    end)
  end

  defp delimiters(run, before, next) do
    sign = binary_part(run, 0, 1)
    {open?, close?} = flanks(sign, before, next)
    italic = {:delimiter, {sign, :italic}, sign, open?, close?}
    bold = {:delimiter, {sign, :bold}, sign <> sign, open?, close?}

    case byte_size(run) do
      1 -> [italic]
      2 -> [bold]
      3 when close? and not open? -> [italic, bold]
      3 -> [bold, italic]
      _more -> [{:text, run}]
    end
  end

  # `_` opens or closes only at a word edge.
  defp flanks("*", before, next), do: {next != :space, before != :space}

  defp flanks("_", before, next),
    do: {next != :space and before != :word, before != :space and next != :word}

  defp side(nil, _end), do: :space
  defp side({:text, text}, :last), do: char_kind(String.last(text))
  defp side({:text, text}, :first), do: char_kind(String.first(text))
  defp side(_token, _end), do: :punct

  defp char_kind(" "), do: :space
  defp char_kind(<<byte>>) when byte in ?a..?z or byte in ?A..?Z or byte in ?0..?9, do: :word
  defp char_kind(<<byte>>) when byte < 0x80, do: :punct
  defp char_kind(char), do: if(String.match?(char, @word), do: :word, else: :punct)

  # A closer pairs with the nearest opener of its kind on the stack; the
  # openers above it stay text. Each opener goes on and off the stack once.
  defp pair(tokens) do
    {roles, _stack, _open} =
      tokens |> Enum.with_index() |> Enum.reduce({%{}, [], %{}}, &pair_step/2)

    {tokens, roles}
  end

  defp pair_step({{:delimiter, kind, _text, open?, close?}, index}, {roles, stack, open}) do
    cond do
      close? and Map.get(open, kind, 0) > 0 -> close(kind, index, roles, stack, open)
      open? -> {roles, [{kind, index} | stack], Map.update(open, kind, 1, &(&1 + 1))}
      true -> {roles, stack, open}
    end
  end

  defp pair_step(_token, state), do: state

  defp close(kind, index, roles, [{kind, opener} | stack], open),
    do: {Map.merge(roles, %{opener => :open, index => :close}), stack, dec(open, kind)}

  defp close(kind, index, roles, [{other, _opener} | stack], open),
    do: close(kind, index, roles, stack, dec(open, other))

  defp dec(open, kind), do: Map.update!(open, kind, &(&1 - 1))

  defp emit({tokens, roles}, base) do
    {segments, _active} =
      tokens
      |> Enum.with_index()
      |> Enum.flat_map_reduce(%{bold: 0, italic: 0}, fn {token, index}, active ->
        segment(token, Map.get(roles, index), active, base)
      end)

    segments
  end

  defp segment({:delimiter, {_sign, tag}, _text, _open?, _close?}, :open, active, _base),
    do: {[], Map.update!(active, tag, &(&1 + 1))}

  defp segment({:delimiter, {_sign, tag}, _text, _open?, _close?}, :close, active, _base),
    do: {[], Map.update!(active, tag, &(&1 - 1))}

  defp segment({:delimiter, _kind, text, _open?, _close?}, nil, active, base),
    do: {[{text, tags(base, active, [])}], active}

  defp segment({:text, text}, nil, active, base), do: {[{text, tags(base, active, [])}], active}

  defp segment({:code, text}, nil, active, base),
    do: {[{text, tags(base, active, [:code])}], active}

  defp segment({:link, label, url}, nil, active, base) when url in ["", label],
    do: {[{label, tags(base, active, [:underlined])}], active}

  defp segment({:link, label, url}, nil, active, base),
    do:
      {[{label, tags(base, active, [:underlined])}, {" (#{url})", tags(base, active, [])}],
       active}

  defp tags(base, %{bold: bold, italic: italic}, extra) do
    Enum.uniq(
      base ++
        if(bold > 0, do: [:bold], else: []) ++ if(italic > 0, do: [:italic], else: []) ++ extra
    )
  end

  defp merge([{a, tags}, {b, tags} | rest]), do: merge([{a <> b, tags} | rest])
  defp merge([segment | rest]), do: [segment | merge(rest)]
  defp merge([]), do: []

  # A segment boundary inside a grapheme moves to the end of the grapheme,
  # so each grapheme has one style. It runs on the finished row, prefix
  # included. One pass: `owed` is the bytes that the piece before took from
  # this segment, and the rest of the row always starts at a grapheme.
  defp whole([_segment] = row), do: row

  defp whole(row), do: cut(row, Enum.map_join(row, &elem(&1, 0)), 0, [])

  defp cut([], _line, _owed, acc), do: Enum.reverse(acc)

  defp cut([{text, tags} | segments], line, owed, acc) do
    case byte_size(text) - owed do
      need when need <= 0 ->
        cut(segments, line, -need, acc)

      need ->
        size = grapheme_end(line, need)
        <<piece::binary-size(size), line::binary>> = line
        cut(segments, line, size - need, [{piece, tags} | acc])
    end
  end

  # The first grapheme end at or after `need` bytes. Fast path: two ASCII
  # bytes are two graphemes (CR LF cannot occur after `Wrap.sanitize/1`).
  defp grapheme_end(line, need) do
    case line do
      <<_::binary-size(need - 1), last, next, _::binary>> when last < 0x80 and next < 0x80 -> need
      <<_::binary-size(need)>> -> need
      _ -> walk(line, need, 0)
    end
  end

  defp walk(_line, need, size) when size >= need, do: size

  defp walk(line, need, size) do
    {grapheme, line} = String.next_grapheme_size(line)
    walk(line, need, size + grapheme)
  end
end
