defmodule Helyx.Tool.WebFetch.Text do
  @moduledoc false
  # The text of an HTML page, for `Helyx.Tool.WebFetch`
  # (`docs/features/web-fetch.md`). A scanner, not a parser: it keeps the
  # text and the link targets, turns a block tag and `br` into a new line,
  # and drops the elements that hold no text for the model. It builds no
  # tree, so a tag that never closes costs one step and no memory. The
  # result is never longer than the page that it reads.

  # The elements that are dropped with their content. A skip ends at the
  # first close tag of the same name, so a `script` that holds `</div>`
  # holds it to its own end.
  # `head` is not one of them: a page may leave out its close tag, and the
  # skip would then take the whole body. Its `title` is a line of the text.
  @skip ~w(noscript script style svg)

  @closing for name <- @skip,
               into: %{},
               do: {name, Regex.compile!("</\\s*" <> name <> "\\b", "i")}

  # The elements that start a new line: a block, and `br`.
  @block ~w(address article aside blockquote br dd details div dl dt fieldset
            figcaption figure footer form h1 h2 h3 h4 h5 h6 header hr li main nav ol
            p pre section summary table tbody td tfoot th thead title tr ul)

  # The entities that a page writes for a character, and the numeric form
  # `&#39;` or `&#x27;`. Another entity is kept as the text it is.
  @named %{
    "amp" => "&",
    "apos" => "'",
    "gt" => ">",
    "lt" => "<",
    "nbsp" => " ",
    "quot" => "\""
  }

  # The most bytes between the `&` and the `;` that an entity may hold:
  # `&#x10FFFF;` has 8, and a leading zero takes one more.
  @entity_bytes 10

  @spaces ~r/[ \t\r\f\v]+/

  @doc "The text of an HTML page."
  @spec to_text(binary()) :: String.t()
  def to_text(html) when is_binary(html) do
    html |> scan([], nil) |> Enum.reverse() |> IO.iodata_to_binary() |> tidy()
  end

  # `out` holds the tokens, newest first; `link` is nil, or the `href` of the
  # open anchor and whether it has text. Every step reads the head of the
  # rest, so the scan is one loop whatever the page holds.
  defp scan(<<>>, out, _link), do: out

  defp scan(<<"<!--", rest::binary>>, out, link), do: scan(comment(rest), out, link)
  defp scan(<<"<", rest::binary>>, out, link), do: tag(rest, out, link)

  defp scan(bin, out, link) do
    {text, rest} = span(bin)
    scan(rest, [decode(text) | out], note_text(text, link))
  end

  defp span(bin) do
    case :binary.match(bin, "<") do
      :nomatch -> {bin, <<>>}
      {pos, 1} -> {binary_part(bin, 0, pos), binary_part(bin, pos, byte_size(bin) - pos)}
    end
  end

  defp comment(rest) do
    case :binary.match(rest, "-->") do
      :nomatch -> <<>>
      {pos, 3} -> binary_part(rest, pos + 3, byte_size(rest) - pos - 3)
    end
  end

  defp tag(<<"/", rest::binary>>, out, link), do: close(rest, out, link)
  defp tag(<<"!", rest::binary>>, out, link), do: scan(past_gt(rest), out, link)
  defp tag(<<"?", rest::binary>>, out, link), do: scan(past_gt(rest), out, link)

  defp tag(rest, out, link) do
    {name, rest} = name(rest)
    {href, rest} = attributes(rest, nil)

    cond do
      name in @skip -> scan(skip(name, rest), out, link)
      name == "a" -> scan(rest, new_line(out, name), anchor(href, link))
      true -> scan(rest, new_line(out, name), link)
    end
  end

  # An anchor with no target keeps the text as it is, and the one around it,
  # if any.
  defp anchor(nil, link), do: link
  defp anchor(href, _link), do: %{href: href, text: false}

  defp close(rest, out, link) do
    {name, rest} = name(rest)
    rest = past_gt(rest)

    cond do
      name == "a" and link != nil ->
        out = if link.text, do: [[" (", decode(link.href), ")"] | out], else: out
        scan(rest, out, nil)

      name in @block ->
        scan(rest, ["\n" | out], link)

      true ->
        scan(rest, out, link)
    end
  end

  defp new_line(out, name) when name in @block, do: ["\n" | out]
  defp new_line(out, _name), do: out

  defp note_text(_text, nil), do: nil

  defp note_text(text, link),
    do: if(String.trim(text) == "", do: link, else: %{link | text: true})

  defp skip(name, rest) do
    case Regex.run(@closing[name], rest, return: :index) do
      [{pos, _length} | _] -> past_gt(binary_part(rest, pos, byte_size(rest) - pos))
      nil -> <<>>
    end
  end

  defp past_gt(bin) do
    case :binary.match(bin, ">") do
      :nomatch -> <<>>
      {pos, 1} -> binary_part(bin, pos + 1, byte_size(bin) - pos - 1)
    end
  end

  # The tag name ends at a space, a `/`, a `>`, or the end. It is lowercased
  # so that `<P>` and `</p>` are one element.
  defp name(rest), do: name(rest, [])

  defp name(<<c, rest::binary>>, acc)
       when c in ?a..?z or c in ?A..?Z or c in ?0..?9 or c in [?_, ?-, ?:],
       do: name(rest, [acc, <<c>>])

  defp name(rest, acc), do: {String.downcase(IO.iodata_to_binary(acc)), rest}

  # The attributes of a start tag, read only for the `href` of an anchor.
  defp attributes(<<>>, href), do: {href, <<>>}
  defp attributes(<<">", rest::binary>>, href), do: {href, rest}
  defp attributes(<<"/", ">", rest::binary>>, href), do: {href, rest}

  defp attributes(<<c, rest::binary>>, href) when c in [?\s, ?\t, ?\n, ?\r],
    do: attributes(rest, href)

  defp attributes(rest, href) do
    {name, rest} = attribute_name(rest, [])

    case skip_space(rest) do
      <<"=", rest::binary>> ->
        {value, rest} = rest |> skip_space() |> attribute_value()
        attributes(rest, if(name == "href", do: value, else: href))

      rest ->
        attributes(rest, href)
    end
  end

  defp attribute_name(<<c, rest::binary>>, acc) when c in [?\s, ?\t, ?\n, ?\r, ?=, ?/, ?>],
    do: {IO.iodata_to_binary(acc), <<c, rest::binary>>}

  defp attribute_name(<<c, rest::binary>>, acc), do: attribute_name(rest, [acc, <<c>>])
  defp attribute_name(<<>>, acc), do: {IO.iodata_to_binary(acc), <<>>}

  defp skip_space(<<c, rest::binary>>) when c in [?\s, ?\t, ?\n, ?\r], do: skip_space(rest)
  defp skip_space(rest), do: rest

  defp attribute_value(<<quote, rest::binary>>) when quote in [?", ?'] do
    case :binary.match(rest, <<quote>>) do
      :nomatch ->
        {rest, <<>>}

      {pos, 1} ->
        {binary_part(rest, 0, pos), binary_part(rest, pos + 1, byte_size(rest) - pos - 1)}
    end
  end

  defp attribute_value(rest) do
    case :binary.match(rest, [">", " ", "\t", "\n", "\r"]) do
      :nomatch -> {rest, <<>>}
      {pos, _length} -> {binary_part(rest, 0, pos), binary_part(rest, pos, byte_size(rest) - pos)}
    end
  end

  defp decode(text) do
    if :binary.match(text, "&") == :nomatch, do: text, else: decode(text, [])
  end

  defp decode(<<>>, acc), do: Enum.reverse(acc)

  defp decode(text, acc) do
    case :binary.match(text, "&") do
      :nomatch ->
        Enum.reverse([text | acc])

      {pos, 1} ->
        prefix = binary_part(text, 0, pos)
        rest = binary_part(text, pos, byte_size(text) - pos)
        {value, rest} = entity(rest)
        decode(rest, [value, prefix | acc])
    end
  end

  defp entity(<<"&", rest::binary>>) do
    case :binary.match(rest, ";", scope: {0, min(byte_size(rest), @entity_bytes)}) do
      :nomatch ->
        {"&", rest}

      {pos, 1} ->
        name = binary_part(rest, 0, pos)
        after_semi = binary_part(rest, pos + 1, byte_size(rest) - pos - 1)

        case char(name) do
          nil -> {"&" <> name <> ";", after_semi}
          char -> {char, after_semi}
        end
    end
  end

  defp char("#x" <> hex), do: code(hex, 16)
  defp char("#X" <> hex), do: code(hex, 16)
  defp char("#" <> decimal), do: code(decimal, 10)
  defp char(name), do: Map.get(@named, name)

  # A code point of a surrogate pair or above the last character is not a
  # character, so the entity stays as text.
  defp code(digits, base) do
    case Integer.parse(digits, base) do
      {code, ""} when code > 0 and code <= 0x10FFFF and code not in 0xD800..0xDFFF ->
        <<code::utf8>>

      _other ->
        nil
    end
  end

  # One line per line: spaces inside it are one space, and its ends are
  # trimmed. A run of blank lines becomes one, and the text has none at
  # its ends.
  defp tidy(text) do
    text
    |> String.split("\n")
    |> Enum.map(&line/1)
    |> collapse([], true)
    |> Enum.drop_while(&(&1 == ""))
    |> Enum.reverse()
    |> Enum.join("\n")
  end

  defp line(line), do: line |> String.replace(@spaces, " ") |> String.trim()

  defp collapse([], acc, _blank?), do: acc
  defp collapse(["" | rest], acc, true), do: collapse(rest, acc, true)
  defp collapse(["" | rest], acc, false), do: collapse(rest, ["" | acc], true)
  defp collapse([line | rest], acc, _blank?), do: collapse(rest, [line | acc], false)
end
