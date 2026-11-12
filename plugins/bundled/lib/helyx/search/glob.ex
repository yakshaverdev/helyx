defmodule Helyx.Search.Glob do
  @moduledoc false
  # The glob of the `grep` and `find` tools (`docs/features/search-tools.md`):
  # `*`, `**`, `**/`, `?`, and a literal. Split from `Helyx.Search` for the
  # file length rule (AGENTS.md, "Elixir guidelines"); a helper, as that module.
  #
  # The match is linear in the path: it keeps the set of live positions in the
  # token list and steps it one unit of the subject at a time, so a glob with
  # many `*` costs a few set operations for each token and each unit, with no
  # backtracking.

  # `match?/2` here matches a path, not a pattern.
  import Kernel, except: [match?: 2]

  @enforce_keys [:subject, :tokens]
  defstruct [:subject, :tokens]

  @typedoc "A glob compiled once for a search."
  @type t :: %__MODULE__{subject: :basename | :path, tokens: tuple()}

  @doc """
  Whether `path` matches `glob`: `*` any run without a `/`, `**` any run, `**/`
  zero or more whole folders, `?` one character that is not a `/`, and a
  literal. A glob with no `/` matches the file name, so it holds at any depth.
  """
  @spec glob?(String.t(), String.t()) :: boolean()
  def glob?(glob, path), do: glob |> compile() |> match?(path)

  @doc """
  Compiles `glob` for a search: the subject that it matches (the file name, or
  the path when the glob holds a `/`) and its tokens.
  """
  @spec compile(String.t()) :: t()
  def compile(glob) do
    %__MODULE__{
      subject: if(String.contains?(glob, "/"), do: :path, else: :basename),
      tokens: glob |> tokens("", []) |> List.to_tuple()
    }
  end

  @doc "Whether `path` matches the compiled `glob`."
  @spec match?(t(), String.t()) :: boolean()
  def match?(%__MODULE__{subject: subject, tokens: tokens}, path) do
    text = if subject == :path, do: path, else: Path.basename(path)
    live = close(0, :start, tokens, MapSet.new())
    text |> steps(tokens, live) |> at_end?(tokens)
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

  # One token for each unit of the literal, so that a step consumes one unit.
  defp finish("", acc), do: acc

  defp finish(literal, acc) do
    {unit, rest} = unit(literal)
    finish(rest, [{:literal, unit} | acc])
  end

  # A position is an index in the token list and, for `:any_dirs`, whether it
  # is at the start of a folder name or inside one. Closure adds the position
  # after a token that can match nothing.
  defp close(pos, dir, tokens, set) do
    set = MapSet.put(set, {pos, dir})

    if pos < tuple_size(tokens) and empty?(elem(tokens, pos), dir),
      do: close(pos + 1, :start, tokens, set),
      else: set
  end

  defp empty?(:any_name, _dir), do: true
  defp empty?(:any_path, _dir), do: true
  defp empty?(:any_dirs, :start), do: true
  defp empty?(_token, _dir), do: false

  defp steps("", _tokens, live), do: live

  defp steps(text, tokens, live) do
    {unit, rest} = unit(text)

    next =
      Enum.reduce(live, MapSet.new(), fn state, set -> step(state, unit, tokens, set) end)

    if MapSet.size(next) == 0, do: next, else: steps(rest, tokens, next)
  end

  defp step({pos, dir}, unit, tokens, set) do
    if pos < tuple_size(tokens) do
      case elem(tokens, pos) do
        {:literal, literal} when literal == unit -> close(pos + 1, :start, tokens, set)
        :one_name when unit != "/" -> close(pos + 1, :start, tokens, set)
        :any_name when unit != "/" -> close(pos, :start, tokens, set)
        :any_path -> close(pos, :start, tokens, set)
        :any_dirs -> close(pos, dirs(dir, unit), tokens, set)
        _other -> set
      end
    else
      set
    end
  end

  defp dirs(_dir, "/"), do: :start
  defp dirs(_dir, _unit), do: :inside

  defp at_end?(live, tokens), do: MapSet.member?(live, {tuple_size(tokens), :start})

  # One character, and one byte that is not valid UTF-8, as the name of a
  # file on another file system can have.
  defp unit(<<char::utf8, rest::binary>>), do: {<<char::utf8>>, rest}
  defp unit(<<byte, rest::binary>>), do: {<<byte>>, rest}
end
