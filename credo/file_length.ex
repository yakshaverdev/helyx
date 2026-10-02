defmodule Helyx.Credo.FileLength do
  use Credo.Check,
    category: :design,
    base_priority: :high,
    param_defaults: [max_lines: 400, allowed: %{}],
    explanations: [
      check: """
      A `.ex` file in a `lib/` folder has at most `max_lines` lines (#294).

      A file over the limit has an entry in `allowed`, in `.credo.exs`:
      its path, its line count, and a reason. A listed file must not grow.
      A listed file at or under the limit gets an issue too, so that its
      entry goes away. The list only shrinks.

      Split a file only where a module can own its state or its decisions.
      A line count alone is not a reason.
      """,
      params: [
        max_lines: "The most lines that a file without an entry can have.",
        allowed: "A map of path => {line count, reason} for the files over the limit."
      ]
    ]

  @doc false
  @impl true
  def run(%SourceFile{filename: path} = source_file, params) do
    if path =~ ~r"(^|/)lib/.+\.ex$" do
      ctx = Context.build(source_file, params, __MODULE__)
      max = Params.get(params, :max_lines, __MODULE__)
      allowed = Params.get(params, :allowed, __MODULE__)
      lines = source_file |> SourceFile.source() |> count_lines()

      case message(lines, max, Map.get(allowed, path)) do
        nil -> []
        message -> [format_issue(ctx, message: message, trigger: path, line_no: 1)]
      end
    else
      []
    end
  end

  # Counts lines as `wc -l` does for a file that ends with a newline.
  defp count_lines(source),
    do: source |> String.trim_trailing("\n") |> String.split("\n") |> length()

  defp message(lines, max, nil) when lines > max,
    do:
      "The file has #{lines} lines, over the limit of #{max}. Split it, or list it in .credo.exs with a reason."

  defp message(lines, max, {_count, _reason}) when lines <= max,
    do:
      "The file has #{lines} lines, at or under the limit of #{max}. Remove its entry from .credo.exs."

  defp message(lines, _max, {count, _reason}) when lines > count,
    do:
      "The file has #{lines} lines, more than the #{count} in .credo.exs. A listed file must not grow."

  defp message(_lines, _max, _entry), do: nil
end
