defmodule Helyx.Tool.Read do
  @moduledoc """
  Reads a file. Long files keep the head, and the result says which absolute
  lines it shows and, when lines follow them, which offset continues the
  read; `offset` reads from a later line.

  An `offset` that is not a positive integer is an error, never a silent
  default. A missing or null `offset` is line 1. An offset after the last
  line gives an empty result.
  """

  @behaviour Helyx.Tool

  alias Helyx.Tool.Args

  @impl true
  def name, do: "read"

  @impl true
  def concurrent?, do: true

  @impl true
  def description do
    "Read a file. Returns at most #{Helyx.Text.max_lines()} lines or " <>
      "#{div(Helyx.Text.max_bytes(), 1024)} KB, starting at offset " <>
      "(a 1-based line number, default 1); a truncated result names the " <>
      "offset that continues the read, when lines follow."
  end

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "path" => %{
          "type" => "string",
          "description" => "File path, absolute or relative to the working directory"
        },
        "offset" => %{
          "type" => "integer",
          "minimum" => 1,
          "default" => 1,
          "description" => "First line to return, 1-based"
        }
      },
      "required" => ["path"]
    }
  end

  @impl true
  def run(args, cwd) do
    with {:ok, args} <- Args.check(args, parameters()) do
      path = args["path"]

      case Helyx.Text.read_file(Path.expand(path, cwd)) do
        {:ok, content} -> {:ok, Helyx.Text.truncate(content, :head, args["offset"])}
        {:error, reason} -> {:error, "cannot read #{path}: #{reason}"}
      end
    end
  end
end
