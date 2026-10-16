defmodule Helyx.Session.File.Scan do
  # A session file has a header line of at most this many bytes. A scan
  # reads no more than this of a file: the head.
  @max_header_bytes 65_536

  # A scan reads the head of this many files: the ones with the newest
  # modification time. Nothing deletes session files, so their count grows.
  @max_scanned_files 256

  # The version of the header that this build writes and reads.
  @version 1

  @moduledoc """
  The place and the header of a session file, and the choice of a file in a
  sessions directory: the list of the sessions (`list/2`), the file of an id
  (`find/2`), and the newest session of a folder for
  `Helyx.Session.File.pick/3`. A session lives at
  `<dir>/<project slug>/<session id>.jsonl`; `Helyx.Session.File` owns the
  entries after the header.

  A scan reads the first #{@max_header_bytes} bytes (the head), and one
  byte more, of at most #{@max_scanned_files} regular files: the ones with
  the newest modification time. An append sets that time. A file whose head
  is the whole file and has no message is empty: the list and the newest
  session leave it out. The rules are in
  `docs/features/session-list.md`.
  """

  alias Helyx.Session.Id

  defmodule Summary do
    @moduledoc """
    One session of `Helyx.Session.File.Scan.list/2`. `mtime` is the POSIX
    time of the last change of the file. `model` is the model of the
    header. `prompt` is the text of the first message in the head when that
    message is a user message, else `""`. The texts come from the file: a
    client cleans them before it shows them.
    """
    @enforce_keys [:id, :cwd, :model, :mtime, :prompt]
    defstruct @enforce_keys

    @type t :: %__MODULE__{
            id: String.t(),
            cwd: String.t(),
            model: String.t(),
            mtime: integer(),
            prompt: String.t()
          }
  end

  @doc """
  The sessions of the folder `cwd`, or of every folder with `:all`, newest
  first by modification time. A file is left out when it is empty, when its
  name is not a session id, or when its header does not parse, has an
  unknown version, or has no string `cwd` and `model`.
  """
  @spec list(Path.t(), Path.t() | :all) :: [Summary.t()]
  def list(dir, scope) do
    for {mtime, path, %{"cwd" => cwd, "model" => model}, prompt} <-
          sessions(dir, scope, @max_scanned_files) do
      %Summary{id: id(path), cwd: cwd, model: model, mtime: mtime, prompt: prompt}
    end
  end

  @doc """
  The file of the session `id` and its header, under the project folders of
  `dir`. The id must have the format of a session id; it is checked before
  any path is built. Two files with the id give `:duplicate_id`; only a copy
  by hand makes them. The header has a string `cwd`.
  """
  @spec find(Path.t(), String.t()) ::
          {:ok, Path.t(), map()}
          | {:error, :invalid_id | :not_found | :duplicate_id | {:invalid_file, String.t()}}
  def find(dir, id) do
    if Id.valid?(id), do: find_valid(dir, id), else: {:error, :invalid_id}
  end

  defp find_valid(dir, id) do
    case Path.wildcard(Path.join([dir, "*", id <> ".jsonl"])) do
      [] ->
        {:error, :not_found}

      [path] ->
        case head(path) do
          {:ok, header, _prompt} -> {:ok, path, header}
          :error -> {:error, {:invalid_file, "the file does not start with a session header"}}
        end

      _paths ->
        {:error, :duplicate_id}
    end
  end

  @doc false
  # The most recently started session of `cwd` that `list/2` would list:
  # not empty, a session id as file name, a known version, and a string
  # `model`. The option `:max_scanned_files` lowers the file count for a
  # test. It is not checked.
  def most_recent(dir, cwd, opts) do
    max_files = Keyword.get(opts, :max_scanned_files, @max_scanned_files)

    case Enum.max_by(sessions(dir, cwd, max_files), fn {_, _, h, _} -> h["ts"] end, fn -> nil end) do
      nil -> {:error, :not_found}
      {_mtime, path, header, _prompt} -> {:ok, path, header}
    end
  end

  # The files of the scan whose name is a session id, that are not empty,
  # and whose header has a known version, a string `model`, and names
  # `scope`, newest first. Two directories can share a slug, so the header
  # decides.
  defp sessions(dir, scope, max_files) do
    pattern =
      if scope == :all,
        do: Path.join([dir, "*", "*.jsonl"]),
        else: Path.join(project_dir(dir, scope), "*.jsonl")

    for {mtime, path} <- newest(Path.wildcard(pattern), max_files),
        Id.valid?(id(path)),
        {:ok, header, prompt} when prompt != :empty <- [head(path)],
        is_binary(header["model"]) and check_version(header) == :ok,
        scope in [:all, header["cwd"]] do
      {mtime, path, header, prompt}
    end
  end

  defp id(path), do: Path.basename(path, ".jsonl")

  # The `count` regular files with the newest modification time, newest
  # first: one stat per file and no read. The time has a resolution of one
  # second, so the path breaks a tie, and the same directory always gives
  # the same files.
  defp newest(paths, count) do
    stats =
      for path <- paths,
          {:ok, %File.Stat{type: :regular, mtime: mtime}} <- [File.stat(path, time: :posix)] do
        {mtime, path}
      end

    stats |> Enum.sort(:desc) |> Enum.take(count)
  end

  # The header and the first prompt, or `:empty` for the prompt. A header
  # line over the bound is cut, does not decode, and the file is not a
  # session; so is a header with no string `cwd`. The read takes one byte
  # past the head: a read of at most the head is the whole file.
  defp head(path) do
    with {:ok, data} <- read_up_to(path, @max_header_bytes + 1),
         whole? = byte_size(data) <= @max_header_bytes,
         head = binary_part(data, 0, min(byte_size(data), @max_header_bytes)),
         [line | rest] = :binary.split(head, "\n"),
         {:ok, %{"type" => "session", "cwd" => cwd} = header} when is_binary(cwd) <-
           JSON.decode(line) do
      # `rest` is the rest of the head, or nothing. A lazy walk: the head
      # as a list of 65,535 short lines is about 4 MiB of heap.
      lines = Stream.flat_map(rest, &String.splitter(&1, "\n"))
      {:ok, header, prompt(Enum.find_value(lines, &message/1), whole?)}
    else
      _ -> :error
    end
  end

  # A head that is the whole file and has no message is empty. A last line
  # that the bound cut does not decode and is skipped.
  defp prompt(nil, true), do: :empty
  defp prompt(nil, false), do: ""

  defp prompt(%{"role" => "user", "content" => content}, _whole?) when is_list(content),
    do: Enum.join(for(%{"type" => "text", "text" => t} when is_binary(t) <- content, do: t), " ")

  defp prompt(_message, _whole?), do: ""

  defp message(line) do
    case JSON.decode(line) do
      {:ok, %{"type" => "message"} = entry} -> entry
      _ -> nil
    end
  end

  @doc false
  # The header line of a new session.
  def header(cwd, model),
    do: %{"type" => "session", "version" => @version, "cwd" => cwd, "model" => model}

  @doc false
  def check_version(%{"version" => @version}), do: :ok
  def check_version(header), do: {:error, {:unknown_version, header["version"]}}

  @doc false
  # At most `bytes` from the start of a regular file. A pipe or a device
  # would block the open or never end. The fun form of File.open closes the
  # handle on every path.
  def read_up_to(path, bytes) do
    with {:ok, %File.Stat{type: :regular}} <- File.stat(path),
         {:ok, data} when is_binary(data) <-
           File.open(path, [:read, :binary], &IO.binread(&1, bytes)) do
      {:ok, data}
    else
      {:ok, %File.Stat{}} -> {:error, :not_regular}
      {:ok, :eof} -> {:ok, ""}
      {:ok, {:error, _reason} = error} -> error
      {:error, _reason} = error -> error
    end
  end

  @doc false
  # The slug keeps the tail of the path, the distinctive end, and stays
  # under the filesystem name limit: 100 characters are 100 bytes because
  # the regex collapses every non-ASCII byte to "-". Collisions are fine:
  # the header `cwd` decides which sessions belong to a directory.
  def project_dir(dir, cwd) do
    Path.join(dir, cwd |> String.replace(~r/[^A-Za-z0-9]+/, "-") |> String.slice(-100, 100))
  end
end
