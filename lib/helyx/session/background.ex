defmodule Helyx.Session.Background do
  @moduledoc false
  # The places and the texts of the background runs of a session
  # (docs/features/background-bash.md). The texts are the start answer,
  # the result of its call, and the end, a user message. Both open with a
  # fixed line that names the run, so a resume can pair them in the
  # transcript (`lost/1`) with no record of its own.

  alias Helyx.Message
  alias Helyx.Session.Id

  # The places of the runs of a session, in the hands. A live run is a Task
  # whose entry in the hands has a place, from `Helyx.Tool.background/0` to
  # its end. `waiting` holds the ids of the ends that no turn took yet: an
  # end outlives its Task. Both count in `@max_places`, so the places bound
  # the live runs and the waiting ends together (#587).
  defstruct waiting: []

  @type t :: %__MODULE__{waiting: [String.t()]}

  @max_places 16

  # The start answer is short: an id, a path, a hint. The cap keeps the
  # first line whole through the cut of every later boundary of tool text
  # (`Message.cut_result/1`), which would put a notice line before it. The
  # cap counts bytes before the UTF-8 repair of that cut, which makes each
  # kept byte at most 3 bytes: 12,288 bytes after it.
  @max_start_bytes 4_096

  @head ~r/\A<background id="([A-Za-z0-9_-]{12})" status="([a-z]+)">\n/

  # The same form as the result of an interrupted call
  # (docs/features/interrupted-calls.md): what stopped, what may have run,
  # and a check before a repeat.
  @lost "The session stopped while this background command ran, and its end was lost. " <>
          "The command may have run in full or in part. " <>
          "Check its effects before you run it again. " <>
          "Its output file was deleted with the session."

  # A new place, with `live` runs, and the folder `dir`, made at each call:
  # a new id, or the error text for the tool. The hands keep the id in the
  # entry of the Task, so a second call of the Task gives a new id in the
  # same place.
  @spec reserve(t(), non_neg_integer(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def reserve(%__MODULE__{waiting: waiting}, live, _dir)
      when live + length(waiting) >= @max_places,
      do:
        {:error,
         "#{@max_places} background runs are live or have an end that no turn took; " <>
           "a turn must take an end before another run starts"}

  # The files can hold secrets, such as the output of a command: only the
  # user may read them.
  def reserve(%__MODULE__{}, _live, dir) do
    case with(:ok <- File.mkdir_p(dir), do: File.chmod(dir, 0o700)) do
      :ok ->
        {:ok, Id.new()}

      {:error, reason} ->
        {:error, "the background folder could not be made: #{:file.format_error(reason)}"}
    end
  end

  # The Task with the call id `call_id` ended. A run that gave its start
  # answer keeps its place until a turn takes its end (`taken/2`); the
  # place of any other Task left with its entry.
  @spec ended(t(), term()) :: t()
  def ended(%__MODULE__{} = places, {:background, id}),
    do: %{places | waiting: [id | places.waiting]}

  def ended(%__MODULE__{} = places, _call_id), do: places

  # A turn took the end of the run `id`. The id of a lost run, from an
  # earlier session, has no place here and frees nothing.
  @spec taken(t(), String.t()) :: t()
  def taken(%__MODULE__{} = places, id), do: %{places | waiting: List.delete(places.waiting, id)}

  # The id of a start answer or an end, which open with the fixed line.
  @spec id(String.t()) :: String.t()
  def id(text) do
    [{id, _status}] = parse(text)
    id
  end

  @spec start(String.t(), String.t()) :: String.t()
  def start(id, text), do: wrap(id, "started", binary_slice(text, 0, @max_start_bytes))

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
  defp head(%Message{content: [%Message.Text{text: "<background " <> _ = text} | _]}),
    do: parse(text)

  defp head(%Message{}), do: []

  defp parse(text) do
    case Regex.run(@head, text, capture: :all_but_first) do
      [id, status] -> [{id, status}]
      nil -> []
    end
  end

  defp wrap(id, status, text),
    do: ~s(<background id="#{id}" status="#{status}">\n#{text}\n</background>)
end
