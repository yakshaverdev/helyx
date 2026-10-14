defmodule Helyx.Session.Background do
  @moduledoc false
  # The places and the texts of the background runs of a session
  # (docs/features/background-bash.md). The texts are the start answer,
  # the result of its call, and the end, a user message. Both open with a
  # fixed line that names the run, so a resume can pair them in the
  # transcript (`lost/1`) with no record of its own.

  alias Helyx.Message
  alias Helyx.Session.Id

  # The most live runs of a session, counted from `Helyx.Tool.background/0`
  # to the end of the Task.
  @max_live 16

  # The start answer is short: an id, a path, a hint. The cap keeps the
  # first line whole through the cut of every later boundary of tool text
  # (`Message.cut_result/1`), which would put a notice line before it.
  @max_start_bytes 4_096

  @head ~r/\A<background id="([A-Za-z0-9_-]{12})" status="([a-z]+)">\n/

  # The same form as the result of an interrupted call
  # (docs/features/interrupted-calls.md): what stopped, what may have run,
  # and a check before a repeat.
  @lost "The session stopped while this background command ran, and its end was lost. " <>
          "The command may have run in full or in part. " <>
          "Check its effects before you run it again. " <>
          "Its output file was deleted with the session."

  # A new place for the Task `pid`, beside the places `live` (Task pid to
  # id), and the folder `dir`, made at each call: a new id, or the error
  # text for the tool.
  @spec reserve(%{pid() => String.t()}, pid(), String.t()) ::
          {:ok, String.t()} | {:error, String.t()}
  def reserve(live, pid, _dir) when is_map_key(live, pid),
    do: {:error, "a tool call can start one background run"}

  def reserve(live, _pid, _dir) when map_size(live) >= @max_live,
    do: {:error, "#{@max_live} background runs are live; one must end before another starts"}

  # The files can hold secrets, such as the output of a command: only the
  # user may read them.
  def reserve(_live, _pid, dir) do
    case with(:ok <- File.mkdir_p(dir), do: File.chmod(dir, 0o700)) do
      :ok ->
        {:ok, Id.new()}

      {:error, reason} ->
        {:error, "the background folder could not be made: #{:file.format_error(reason)}"}
    end
  end

  @spec not_a_call() :: String.t()
  def not_a_call, do: "only a tool call can run in the background"

  @spec start(String.t(), String.t()) :: String.t()
  def start(id, text), do: wrap(id, "started", cap(String.replace_invalid(text)))

  # The end from the Task's result, already through `Message.cut_result/1`.
  @spec finish(String.t(), {:ok | :error, String.t()}) :: String.t()
  def finish(id, {:ok, text}), do: wrap(id, "done", text)
  def finish(id, {:error, text}), do: wrap(id, "error", text)

  # The end of each run that has a start answer in `transcript` and no end
  # message, in start order: the session stopped while it ran.
  @spec lost([Message.t()]) :: [String.t()]
  def lost(transcript) do
    ended =
      for %Message{role: :user} = m <- transcript, {id, _} <- head(m), into: MapSet.new(), do: id

    for %Message{role: :tool_result, is_error: false} = m <- transcript,
        {id, "started"} <- head(m),
        id not in ended,
        do: wrap(id, "lost", @lost)
  end

  # The id and the status of a message that opens with the fixed line.
  # Both texts are the one text part of their message, so only the first
  # part is read.
  defp head(%Message{content: [%Message.Text{text: "<background " <> _ = text} | _]}) do
    case Regex.run(@head, text, capture: :all_but_first) do
      [id, status] -> [{id, status}]
      nil -> []
    end
  end

  defp head(%Message{}), do: []

  defp wrap(id, status, text),
    do: ~s(<background id="#{id}" status="#{status}">\n#{text}\n</background>)

  defp cap(text) when byte_size(text) <= @max_start_bytes, do: text

  defp cap(text),
    do: text |> binary_part(0, @max_start_bytes) |> String.replace_invalid("")
end
