defmodule Helyx.Session.History do
  @moduledoc false
  # The tail of a snapshot and the history pages: the limit check of the
  # client options and the cut of the transcript
  # (docs/features/session-snapshot.md, "Tail", "Cut", "History").

  alias Helyx.Message

  @max_count 1_000
  @default_count 200
  @max_bytes 16 * 1024 * 1024

  @type history_page :: %{messages: [Message.t()], more: boolean(), next: String.t() | nil}

  # The option list of `Helyx.Session.subscribe/2`: none, or `tail`.
  def tail(opts), do: count(opts, :tail, nil)

  # The option list of `Helyx.Session.history/4`: none, or `limit`.
  def limit(opts), do: count(opts, :limit, @default_count)

  defp count([], _key, default), do: {:ok, default}
  defp count([{key, n}], key, _default) when n in 1..@max_count//1, do: {:ok, n}
  defp count(_opts, _key, _default), do: {:error, :invalid_limit}

  # The newest messages of `transcript`, at most `count` of them, as a page.
  def cut(transcript, count), do: cut_newest(Enum.reverse(transcript), count)

  # The page before the message `before` of the live transcript, with the
  # id of its first message as the next cursor while older messages exist.
  def page(transcript, before, count) do
    case newest_before(transcript, before, []) do
      {:ok, newest} -> {:ok, with_next(cut_newest(newest, count))}
      :error -> {:error, :unknown_message}
    end
  end

  # The messages before the one with id `before`, newest first, in one pass.
  defp newest_before([%Message{id: before} | _], before, newest), do: {:ok, newest}

  defp newest_before([message | rest], before, newest),
    do: newest_before(rest, before, [message | newest])

  defp newest_before([], _before, _newest), do: :error

  defp with_next(%{messages: [first | _], more: true} = page), do: Map.put(page, :next, first.id)
  defp with_next(page), do: Map.put(page, :next, nil)

  # `newest` is newest first. The run stops at `count` messages or before
  # the message that passes the bytes; then it starts at a user or an
  # assistant message, or it is the newest group alone.
  defp cut_newest(newest, count) do
    {run, older} = take(newest, count, @max_bytes, [])

    case Enum.split_while(run, &(&1.role == :tool_result)) do
      {_dropped, []} -> group(newest)
      # A dropped result has its call in `older`, so `older` is not empty then.
      {_dropped, messages} -> %{messages: messages, more: older != []}
    end
  end

  # `run` is oldest first.
  defp take([message | older] = newest, count, bytes, run) when count > 0 do
    size = :erlang.external_size(message)

    if size <= bytes,
      do: take(older, count - 1, bytes - size, [message | run]),
      else: {run, newest}
  end

  defp take(newest, _count, _bytes, run), do: {run, newest}

  # The last user or assistant message and the messages after it. A
  # transcript has a user or an assistant message before each tool result
  # (`Helyx.Session.Transcript.repair/1`, `Records`), so only an empty one
  # has none.
  defp group([]), do: %{messages: [], more: false}

  defp group(newest) do
    {results, [head | older]} = Enum.split_while(newest, &(&1.role == :tool_result))
    %{messages: [head | Enum.reverse(results)], more: older != []}
  end
end
