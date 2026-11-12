defmodule Helyx.Tool.Find do
  @moduledoc """
  Finds the files under a folder whose path matches a glob
  (`docs/features/search-tools.md`).

  The result holds the paths relative to the session folder, sorted, at most
  `limit` of them, and a count line when the walk or the limit leaves paths
  out. A search ends at #{Helyx.Search.max_entries(:find)} entries or
  #{Helyx.Search.deadline_ms(:find)} ms, and the result says so. A link to a
  folder is not entered, and a link to a file is a file.
  """

  @behaviour Helyx.Tool

  alias Helyx.Search
  alias Helyx.Tool.Args

  @impl true
  def name, do: "find"

  @impl true
  def concurrent?, do: true

  @impl true
  def description do
    "Find the files under a folder whose path matches a glob. Returns the paths relative to " <>
      "the working directory, sorted, at most `limit` of them " <>
      "(#{Search.default_find_limit()} by default), and a count line when paths are left out. " <>
      "The glob uses `*`, `**`, `?`, and a literal: `*.ex` holds at any depth, `**/*_test.exs` " <>
      "too, and `src/*.ex` only in `src`. `path` is a folder; the working directory is the " <>
      "default. The skip list is `.git`, `_build`, `deps`, `node_modules`, `target`, and " <>
      "`.elixir_ls`."
  end

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "glob" => %{
          "type" => "string",
          "maxLength" => Search.max_glob_bytes(),
          "description" =>
            "Paths to find: `*`, `**`, `?`, and a literal, for example `*.ex` or `**/*_test.exs`"
        },
        "path" => %{
          "type" => "string",
          "description" => "A folder, absolute or relative to the working directory"
        },
        "limit" => %{
          "type" => "integer",
          "minimum" => 1,
          "maximum" => Search.max_find_limit(),
          "default" => Search.default_find_limit(),
          "description" => "The most paths to show"
        }
      },
      "required" => ["glob"],
      "additionalProperties" => false
    }
  end

  @impl true
  def run(args, cwd) do
    with {:ok, args} <- Args.check(args, parameters()), do: Search.find(args, cwd)
  end
end
