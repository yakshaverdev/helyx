defmodule Helyx.Tool.MCP.Lines do
  @moduledoc false
  # The JSON-RPC lines of an MCP server's stdout. Only the new chunk is
  # searched for a line end; the part of a line before it waits as
  # iodata, so a long line costs its length once. A line, finished or not,
  # over 16 MiB is `:too_long`, as in `Helyx.HarnessIO`: past it the client
  # cannot tell which request the line answers.

  @max_bytes 16 * 1024 * 1024

  def max_bytes, do: @max_bytes

  def new, do: {[], 0}

  # The finished lines and the buffer of the part after them.
  def add({parts, size}, data) do
    case :binary.split(data, "\n", [:global]) do
      [part] ->
        size = size + byte_size(part)
        if size > @max_bytes, do: :too_long, else: {[], {[parts, part], size}}

      [first | more] ->
        {lines, [rest]} = Enum.split(more, -1)
        lines = [IO.iodata_to_binary([parts, first]) | lines]

        if byte_size(rest) > @max_bytes or Enum.any?(lines, &(byte_size(&1) > @max_bytes)),
          do: :too_long,
          else: {lines, {rest, byte_size(rest)}}
    end
  end
end
