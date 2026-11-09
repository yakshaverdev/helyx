defmodule Helyx.Watchdog.Mask do
  @moduledoc false
  # The values of the `:env` of `Helyx.Watchdog.start/4` out of a start
  # reason: perl's own output before the marker can quote a value of `:env`, such
  # as a folder of PERL5LIB or the LC_ALL of a locale warning. Each
  # occurrence of each value, also where two overlap, becomes `@masked`.
  # The invalid bytes go first and the cut of `Helyx.Text.cap/3` after, so
  # neither can join or leave a part of a value.
  @masked "<env>"

  def mask(text, []), do: text

  def mask(text, values) do
    text = String.replace_invalid(text, "")
    spans = values |> Enum.flat_map(&spans(text, &1, 0)) |> Enum.sort() |> merge([])
    masked(text, spans, 0)
  end

  defp spans(text, value, from) do
    case :binary.match(text, value, scope: {from, byte_size(text) - from}) do
      {at, size} -> [{at, at + size} | spans(text, value, at + 1)]
      :nomatch -> []
    end
  end

  defp merge([], acc), do: Enum.reverse(acc)

  defp merge([{from, to} | rest], [{start, stop} | acc]) when from <= stop,
    do: merge(rest, [{start, max(to, stop)} | acc])

  defp merge([span | rest], acc), do: merge(rest, [span | acc])

  defp masked(text, [], at), do: binary_part(text, at, byte_size(text) - at)

  defp masked(text, [{from, to} | rest], at),
    do: binary_part(text, at, from - at) <> @masked <> masked(text, rest, to)
end
