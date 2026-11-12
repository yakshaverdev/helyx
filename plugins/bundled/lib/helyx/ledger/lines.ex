defmodule Helyx.Ledger.Lines do
  @moduledoc false
  # The bounded line reader of one session file. It reads in chunks and
  # decodes each line with the limits of a session resume, so every file that
  # resumes is read whole. A line over a limit is counted and skipped; a
  # partial line over the line limit ends the read of the file.

  alias Helyx.Session.File.Reader

  @chunk_bytes 1_048_576

  # The limits of a session resume, so every file that resumes is read whole.
  @max_line_bytes 64 * 1024 * 1024
  @max_heap_bytes 1024 * 1024 * 1024

  @doc false
  @spec fold(Path.t(), acc, (term(), acc -> acc), keyword()) ::
          {:ok, acc} | {:error, File.posix()}
        when acc: var
  def fold(path, acc, fun, opts \\ []) do
    max_line = Keyword.get(opts, :max_line_bytes, @max_line_bytes)
    limits = %Reader.Limits{entry: max_line, heap: @max_heap_bytes}

    case File.open(path, [:read, :binary, :raw]) do
      {:ok, io} ->
        try do
          read(io, "", acc, fun, limits, max_line, 1)
        after
          File.close(io)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp read(io, buffer, acc, fun, limits, max_line, n) do
    case :binary.split(buffer, "\n") do
      [line, rest] ->
        acc = fold_line(line, n, acc, fun, limits)
        read(io, rest, acc, fun, limits, max_line, n + 1)

      [partial] ->
        if byte_size(partial) > max_line do
          {:ok, fun.({:skip, :too_large}, acc)}
        else
          more(io, partial, acc, fun, limits, max_line, n)
        end
    end
  end

  defp more(io, partial, acc, fun, limits, max_line, n) do
    case :file.read(io, @chunk_bytes) do
      {:ok, chunk} -> read(io, partial <> chunk, acc, fun, limits, max_line, n)
      :eof when partial == "" -> {:ok, acc}
      :eof -> {:ok, fold_line(partial, n, acc, fun, limits)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp fold_line(line, n, acc, fun, limits) do
    case Reader.entry(line, n, limits) do
      {:ok, entry} -> fun.({:entry, entry}, acc)
      :none -> fun.({:skip, :torn}, acc)
      {:error, {:too_large, _text}} -> fun.({:skip, :too_large}, acc)
    end
  end
end
