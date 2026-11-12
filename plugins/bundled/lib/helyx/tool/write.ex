defmodule Helyx.Tool.Write do
  @moduledoc "Writes a file, creating parent directories. An existing regular file is replaced; another type of file is an error. The result carries a `diff` UI block against the old file (`docs/features/diff-blocks.md`)."

  @behaviour Helyx.Tool

  alias Helyx.Tool.Args

  @impl true
  def name, do: "write"

  @impl true
  def description,
    do:
      "Write content to a file. Creates the file and its directories; replaces an existing file."

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "path" => %{
          "type" => "string",
          "description" => "File path, absolute or relative to the working directory"
        },
        "content" => %{"type" => "string"}
      },
      "required" => ["path", "content"]
    }
  end

  @impl true
  def run(args, cwd) do
    with {:ok, args} <- Args.check(args, parameters()) do
      path = args["path"]
      content = args["content"]
      full = Path.expand(path, cwd)

      with :ok <- regular_or_missing(full),
           old = old_text(full),
           :ok <- File.mkdir_p(Path.dirname(full)),
           :ok <- File.write(full, content) do
        {:ok, "Wrote #{path}", [diff(path, old, content)]}
      else
        {:error, {:not_regular, type}} ->
          {:error, "cannot write #{path}: not a regular file (#{type})"}

        {:error, reason} ->
          {:error, "cannot write #{path}: #{:file.format_error(reason)}"}
      end
    end
  end

  defp diff(path, {:ok, old}, content), do: Helyx.Diff.block(path, old, content)
  defp diff(path, {:error, reason}, _content), do: Helyx.Diff.unreadable(path, reason)

  # The old text is read before the write, so the block shows what changed.
  # A missing file is an empty old text; a file that the read refuses keeps
  # the write, and the block says why the diff is absent.
  defp old_text(full) do
    case File.stat(full) do
      {:error, :enoent} -> {:ok, ""}
      {:error, reason} -> {:error, to_string(:file.format_error(reason))}
      {:ok, _stat} -> Helyx.Text.read_file(full)
    end
  end

  # The open of a FIFO or a device blocks or has side effects, so only a
  # regular file is replaced. Another error of the stat is left to the write.
  defp regular_or_missing(full) do
    case File.stat(full) do
      {:ok, %File.Stat{type: :regular}} -> :ok
      {:ok, %File.Stat{type: type}} -> {:error, {:not_regular, type}}
      {:error, _reason} -> :ok
    end
  end
end
