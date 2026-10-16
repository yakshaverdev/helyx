defmodule Helyx.Tool.Write do
  @moduledoc "Writes a file, creating parent directories. An existing regular file is replaced; another type of file is an error."

  @behaviour Helyx.Tool

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
  def run(%{"path" => path, "content" => content}, cwd)
      when is_binary(path) and is_binary(content) do
    full = Path.expand(path, cwd)

    with :ok <- regular_or_missing(full),
         :ok <- File.mkdir_p(Path.dirname(full)),
         :ok <- File.write(full, content) do
      {:ok, "Wrote #{path}"}
    else
      {:error, {:not_regular, type}} ->
        {:error, "cannot write #{path}: not a regular file (#{type})"}

      {:error, reason} ->
        {:error, "cannot write #{path}: #{:file.format_error(reason)}"}
    end
  end

  def run(_args, _cwd), do: {:error, "write needs a path and content"}

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
