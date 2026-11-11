defmodule Helyx.Credo.FileLength do
  use Credo.Check,
    category: :design,
    base_priority: :high,
    param_defaults: [max_lines: 400, allowed: %{}],
    explanations: [
      check: """
      A `.ex` file in a `lib/` folder has at most `max_lines` lines of code
      (#294).

      A line inside a `@moduledoc` or `@doc` string, a comment line, and a
      blank line do not count. The check reads the doc lines from the AST
      and the rest of the file line by line.

      A file over the limit has an entry in `allowed`, in `.credo.exs`:
      its path, its line count, and a reason. A listed file must not grow.
      A listed file at or under the limit gets an issue too, so that its
      entry goes away, and so does a listed file under its count, so that
      the count goes down. The list only shrinks.

      Split a file only where a module can own its state or its decisions.
      A line count alone is not a reason.
      """,
      params: [
        max_lines: "The most lines of code that a file without an entry can have.",
        allowed: "A map of path => {line count, reason} for the files over the limit."
      ]
    ]

  @doc_lines [:doc, :moduledoc]

  @doc false
  @impl true
  def run(%SourceFile{filename: path} = source_file, params) do
    if path =~ ~r"(^|/)lib/.+\.ex$" do
      ctx = Context.build(source_file, params, __MODULE__)
      max = Params.get(params, :max_lines, __MODULE__)
      allowed = Params.get(params, :allowed, __MODULE__)
      lines = code_lines(source_file)

      case message(lines, max, Map.get(allowed, path)) do
        nil -> []
        message -> [format_issue(ctx, message: message, trigger: path, line_no: 1)]
      end
    else
      []
    end
  end

  defp code_lines(source_file) do
    docs = source_file |> SourceFile.ast() |> doc_lines() |> MapSet.new()

    source_file
    |> SourceFile.lines()
    |> Enum.count(fn {number, line} ->
      text = String.trim_leading(line)
      text != "" and not String.starts_with?(text, "#") and not MapSet.member?(docs, number)
    end)
  end

  # A `@doc` or `@moduledoc` with a string value spans from its first line to
  # the line where its expression ends, as the parser records it with
  # `token_metadata: true`. An interpolated string is a `:<<>>` node.
  defp doc_lines(ast) do
    {_ast, lines} =
      Macro.prewalk(ast, [], fn
        {:@, meta, [{name, _, [value]}]} = node, acc when name in @doc_lines ->
          if doc_string?(value) do
            last = get_in(meta, [:end_of_expression, :line]) || meta[:line]
            {node, Enum.to_list(meta[:line]..last//1) ++ acc}
          else
            {node, acc}
          end

        node, acc ->
          {node, acc}
      end)

    lines
  end

  defp doc_string?(value), do: is_binary(value) or match?({:<<>>, _, _}, value)

  defp message(lines, max, nil) when lines > max,
    do:
      "The file has #{lines} lines of code, over the limit of #{max}. Split it, or list it in .credo.exs with a reason."

  defp message(lines, max, {_count, _reason}) when lines <= max,
    do:
      "The file has #{lines} lines of code, at or under the limit of #{max}. Remove its entry from .credo.exs."

  defp message(lines, _max, {count, _reason}) when lines > count,
    do:
      "The file has #{lines} lines of code, more than the #{count} in .credo.exs. A listed file must not grow."

  defp message(lines, _max, {count, _reason}) when lines < count,
    do:
      "The file has #{lines} lines of code, fewer than the #{count} in .credo.exs. Lower its entry to #{lines}."

  defp message(_lines, _max, _entry), do: nil
end
