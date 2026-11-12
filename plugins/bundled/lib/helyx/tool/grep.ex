defmodule Helyx.Tool.Grep do
  @moduledoc """
  Searches the files of a folder for a regular expression
  (`docs/features/search-tools.md`).

  The result holds one line for each match, `path:line:text`, grouped by file
  in sorted path order and cut at #{Helyx.Search.max_line_bytes()} bytes for
  each line. `glob` names the files, `context` adds lines around a match, and
  `ignore_case` folds case. A file that is not valid UTF-8, or is over
  #{Helyx.Search.max_file_bytes()} bytes, is skipped and counted. A search
  ends at #{Helyx.Search.max_entries(:grep)} entries or #{Helyx.Search.deadline_ms(:grep)}
  ms, and the result says so.
  """

  @behaviour Helyx.Tool

  alias Helyx.Search
  alias Helyx.Tool.Args

  @impl true
  def name, do: "grep"

  @impl true
  def concurrent?, do: true

  @impl true
  def description do
    "Search the files of a folder for a regular expression. Returns one line for each match, " <>
      "`path:line:text`, grouped by file in sorted path order, at most `limit` matches " <>
      "(#{Search.default_grep_limit()} by default); the last line counts the matches and files " <>
      "that are not shown. `glob` filters the files by name (`*.ex`, `**/*_test.exs`), " <>
      "`path` is a file or a folder, `context` adds 0 to #{Search.max_context_lines()} lines " <>
      "around a match, and `ignore_case` folds case. Each line is cut at " <>
      "#{Search.max_line_bytes()} bytes. A file that is not valid UTF-8 or is over " <>
      "#{Search.max_file_bytes()} bytes is skipped. The skip list is `.git`, `_build`, `deps`, " <>
      "`node_modules`, `target`, and `.elixir_ls`."
  end

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "pattern" => %{
          "type" => "string",
          "maxLength" => Search.max_pattern_bytes(),
          "description" => "A regular expression, at most #{Search.max_pattern_bytes()} bytes"
        },
        "path" => %{
          "type" => "string",
          "description" => "A file or a folder, absolute or relative to the working directory"
        },
        "glob" => %{
          "type" => "string",
          "maxLength" => Search.max_glob_bytes(),
          "description" =>
            "Files to search: `*`, `**`, `?`, and a literal, for example `*.ex` or `**/*_test.exs`"
        },
        "ignore_case" => %{"type" => "boolean", "default" => false},
        "context" => %{
          "type" => "integer",
          "minimum" => 0,
          "maximum" => Search.max_context_lines(),
          "default" => 0,
          "description" => "Lines to show before and after each match"
        },
        "limit" => %{
          "type" => "integer",
          "minimum" => 1,
          "maximum" => Search.max_grep_limit(),
          "default" => Search.default_grep_limit(),
          "description" => "The most matches to show"
        }
      },
      "required" => ["pattern"],
      "additionalProperties" => false
    }
  end

  @impl true
  def run(args, cwd) do
    with {:ok, args} <- Args.check(args, parameters()), do: Search.grep(args, cwd)
  end
end
