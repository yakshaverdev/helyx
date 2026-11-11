defmodule Helyx.Search.Glob do
  @moduledoc false
  # The glob of the `grep` and `find` tools (`docs/features/search-tools.md`):
  # `*`, `**`, `**/`, `?`, and a literal. Split from `Helyx.Search` for the
  # file length rule (AGENTS.md, "Elixir guidelines"); a helper, as that module.

  @doc """
  Whether `path` matches `glob`: `*` any run without a `/`, `**` any run, `**/`
  zero or more whole folders, `?` one character that is not a `/`, and a
  literal. A glob with no `/` matches the file name, so it holds at any depth.
  """
  @spec glob?(String.t(), String.t()) :: boolean()
  def glob?(glob, path) do
    subject = if String.contains?(glob, "/"), do: path, else: Path.basename(path)
    match(tokens(glob, "", []), subject)
  end

  defp tokens(<<>>, literal, acc), do: Enum.reverse(finish(literal, acc))

  defp tokens("**/" <> rest, literal, acc),
    do: tokens(rest, "", [:any_dirs | finish(literal, acc)])

  defp tokens("**" <> rest, literal, acc),
    do: tokens(rest, "", [:any_path | finish(literal, acc)])

  defp tokens("*" <> rest, literal, acc),
    do: tokens(rest, "", [:any_name | finish(literal, acc)])

  defp tokens("?" <> rest, literal, acc),
    do: tokens(rest, "", [:one_name | finish(literal, acc)])

  defp tokens(text, literal, acc) do
    {unit, rest} = unit(text)
    tokens(rest, literal <> unit, acc)
  end

  defp finish("", acc), do: acc
  defp finish(literal, acc), do: [{:literal, literal} | acc]

  defp match([], ""), do: true
  defp match([], _text), do: false
  defp match([:any_path | rest], text), do: any_path(rest, text)
  defp match([:any_dirs | rest], text), do: any_dirs(rest, text)
  defp match([:any_name | rest], text), do: any_name(rest, text)

  defp match([:one_name | rest], text) do
    case text do
      "" ->
        false

      _text ->
        case unit(text) do
          {"/", _tail} -> false
          {_unit, tail} -> match(rest, tail)
        end
    end
  end

  defp match([{:literal, literal} | rest], text) do
    size = byte_size(literal)

    case text do
      <<prefix::binary-size(size), tail::binary>> when prefix == literal -> match(rest, tail)
      _other -> false
    end
  end

  defp any_path(rest, text) do
    match(rest, text) or
      case text do
        "" -> false
        _text -> any_path(rest, elem(unit(text), 1))
      end
  end

  # Zero or more whole folders: the rest of the pattern at the path, or at
  # what follows each `/`.
  defp any_dirs(rest, text) do
    match(rest, text) or
      case :binary.split(text, "/") do
        [_head, tail] -> any_dirs(rest, tail)
        [_only] -> false
      end
  end

  defp any_name(rest, text) do
    match(rest, text) or
      case text do
        "" ->
          false

        _text ->
          case unit(text) do
            {"/", _tail} -> false
            {_unit, tail} -> any_name(rest, tail)
          end
      end
  end

  # One character, and one byte that is not valid UTF-8, as the name of a
  # file on another file system can have.
  defp unit(<<char::utf8, rest::binary>>), do: {<<char::utf8>>, rest}
  defp unit(<<byte, rest::binary>>), do: {<<byte>>, rest}
end
