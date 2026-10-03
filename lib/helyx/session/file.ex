defmodule Helyx.Session.File do
  @moduledoc """
  The session file: append-only JSON lines, one entry per line, a tree by
  `parent_id` (ADR 0001). A session lives at
  `<dir>/<project slug>/<session id>.jsonl`. Only completed messages are
  appended. `resume/3` restores the branch of the newest leaf of the most
  recently started session for a working directory, and nothing is ever
  removed from the file.

  The format, the rules for a damaged file, and the bounds are in
  `docs/features/coding-agent.md`, section "Session file".
  """

  alias Helyx.Message
  alias Helyx.Session.File.Branch
  alias Helyx.Session.File.Codec

  @version 1

  # A resume loads the file whole into the calling process, so the file has a
  # limit. Compaction is out of scope, so a session past it starts anew.
  @max_bytes 64 * 1024 * 1024

  # The decode of a file under @max_bytes can still grow the heap by 12 to 42
  # bytes per file byte (#64). The parse runs in its own process with this
  # heap cap, so a hostile or corrupt file kills only that process. At 12
  # bytes per file byte a 64 MiB file fits (768 MiB); at 42 a file over
  # about 24 MiB (1 GiB / 42) is rejected.
  @max_heap_bytes 1024 * 1024 * 1024

  # The floor of the heap cap option: the VM rejects a cap under the minimum
  # heap of a process, and a cap of 0 words turns the cap off. It holds for a
  # minimum heap under 1 MiB; a VM started with a larger `+hms` rejects it.
  @min_heap_bytes 1024 * 1024

  # The scan for the most recent session reads this much of a file. A header
  # holds a cwd and a model ref.
  @max_header_bytes 65_536

  # The scan reads the header of this many files: the ones with the newest
  # modification time. Nothing deletes session files, so their count grows.
  @max_scanned_files 256

  @enforce_keys [:path]
  defstruct [:path, :leaf]

  @type t :: %__MODULE__{path: Path.t(), leaf: String.t() | nil}

  defmodule Resumed do
    @moduledoc """
    What `resume/3` restores. `resume_ids` holds the last resume id of
    each provider: the id and the number of messages before its entry,
    without the labels that a fork drops.
    """
    @enforce_keys [:file, :session_id, :model, :messages]
    defstruct [:file, :session_id, :model, :messages, resume_ids: %{}]

    @type t :: %__MODULE__{
            file: Helyx.Session.File.t(),
            session_id: String.t(),
            model: String.t(),
            messages: [Message.t()],
            resume_ids: %{String.t() => {String.t(), non_neg_integer()}}
          }
  end

  @typedoc "Why a session cannot be created or resumed."
  @type error ::
          :not_found
          | File.posix()
          | {:unknown_version, term()}
          | {:invalid_file, String.t()}
          | {:too_large, String.t()}
          | :not_regular
          | {:repair_failed, File.posix()}
          | {:create_failed, File.posix()}

  @doc """
  Creates the file for a new session and writes the header. `cwd` and
  `model` must be valid UTF-8; `Helyx.Session.start/2` checks both.
  """
  @spec create(Path.t(), String.t(), String.t(), String.t()) :: {:ok, t()} | {:error, error()}
  def create(dir, session_id, cwd, model) do
    project = project_dir(dir, cwd)

    # The mkdir failing is the caller's configuration, not a crash.
    case File.mkdir_p(project) do
      :ok ->
        header = %{"type" => "session", "version" => @version, "cwd" => cwd, "model" => model}
        {:ok, append(%__MODULE__{path: Path.join(project, session_id <> ".jsonl")}, header)}

      {:error, reason} ->
        {:error, {:create_failed, reason}}
    end
  rescue
    # The header write failing right after the mkdir succeeded.
    error in File.Error -> {:error, {:create_failed, error.reason}}
  end

  @doc """
  Resumes the most recently started session for a working directory.

  Returns the file handle, the session id, the current model, and the
  transcript of one branch: the entries from the header to the newest
  leaf, by `parent_id`. The newest leaf is the last entry in file order
  whose chain of parents reaches the header. The rules for a damaged file
  are in `docs/features/coding-agent.md`, "Session file": a line that does
  not decode is skipped, and an entry with no usable parent or id is on no
  branch. Only the branch is checked and decoded.

  A file over the limit of #{@max_bytes} bytes is rejected as
  `{:too_large, text}` and is not mutated. The read itself stops one byte
  past the limit, so a file that grows during the call is rejected too. A
  session file has a header line of at most #{@max_header_bytes} bytes; the
  scan for the most recent session reads no more than that of any file.

  The scan reads the header of at most #{@max_scanned_files} regular files:
  the ones with the newest modification time. An append sets that time. A
  session older than those files is not found: the result is `:not_found`
  when none of them has the working directory.

  The read and the decode run in their own process with a heap cap of
  #{@max_heap_bytes} bytes, and so do the index of the entries by id and
  the check for a fork below a resume id entry. A
  file whose decode passes the cap is rejected as `{:too_large, text}` and
  is not mutated. The transcript is copied to the caller once.

  `:max_bytes` lowers the file limit, `:max_heap_bytes` lowers the heap
  cap to no less than #{@min_heap_bytes} bytes, and `:max_scanned_files`
  lowers the file count. They exist so that a test reaches a limit with
  small input.
  """
  @spec resume(Path.t(), String.t(),
          max_bytes: pos_integer(),
          max_heap_bytes: pos_integer(),
          max_scanned_files: pos_integer()
        ) :: {:ok, Resumed.t()} | {:error, error()}
  def resume(dir, cwd, opts \\ []) do
    # A bad option is the caller's bug and raises, it is not reported as a
    # bad file.
    resume_within(
      dir,
      cwd,
      Keyword.get(opts, :max_bytes, @max_bytes),
      Keyword.get(opts, :max_heap_bytes, @max_heap_bytes),
      Keyword.get(opts, :max_scanned_files, @max_scanned_files)
    )
  end

  # The options only lower the limits, so the read count stays one the OS takes.
  defp resume_within(dir, cwd, max_bytes, max_heap_bytes, max_files)
       when max_bytes in 1..@max_bytes//1 and
              max_heap_bytes in @min_heap_bytes..@max_heap_bytes//1 and
              max_files in 1..@max_scanned_files//1 do
    with {:ok, path, header} <- most_recent(project_dir(dir, cwd), cwd, max_files),
         :ok <- check_version(header),
         {:ok, resumed, tail} <- load_bounded(path, header, max_bytes, max_heap_bytes),
         # The repair write comes last, after every check passed, so a
         # file this function rejects is never mutated.
         :ok <- repair(path, tail) do
      {:ok, resumed}
    end
  end

  # The wait has no timeout: the process reads at most max_bytes + 1 bytes
  # and dies when its heap passes the cap, so its work is bounded. It is not
  # linked, because the heap kill would take the caller with it; a caller
  # that dies first leaves it to finish that bounded work alone.
  defp load_bounded(path, header, max_bytes, max_heap_bytes) do
    heap = %{
      size: div(max_heap_bytes, :erlang.system_info(:wordsize)),
      kill: true,
      error_logger: false
    }

    {pid, ref} =
      :erlang.spawn_opt(fn -> exit({:loaded, load(path, header, max_bytes)}) end, [
        :monitor,
        {:max_heap_size, heap}
      ])

    receive do
      {:DOWN, ^ref, :process, ^pid, {:loaded, result}} ->
        result

      {:DOWN, ^ref, :process, ^pid, :killed} ->
        {:error,
         {:too_large,
          "the session file needs more than #{max_heap_bytes} bytes of memory to load; " <>
            "start a new session"}}

      # A crash that load/3 does not rescue is a bug here, as it was when the
      # parse ran in the caller.
      {:DOWN, ^ref, :process, ^pid, reason} ->
        exit(reason)
    end
  end

  defp load(path, header, max_bytes) do
    with {:ok, raw} <- read_up_to(path, max_bytes + 1),
         :ok <- check_size(byte_size(raw), max_bytes),
         {entries, tail} = parse(raw, []),
         :ok <- check_size(repaired_size(byte_size(raw), tail), max_bytes),
         {:ok, leaf, branch} <- Branch.newest(entries) do
      # The fork scan is the last use of `entries`, so the decode does not keep it alive.
      fork = Branch.last_fork(entries, branch)

      resumed = %Resumed{
        file: %__MODULE__{path: path, leaf: leaf},
        session_id: Path.basename(path, ".jsonl"),
        model: Branch.current_model(header, branch),
        messages: for(%{"type" => "message"} = entry <- branch, do: Codec.decode(entry)),
        resume_ids: Branch.resume_ids(branch, fork)
      }

      {:ok, resumed, tail}
    end
  rescue
    # The file is on-disk data anyone can edit. An entry with a shape this
    # module never writes is rejected, not raised at the caller.
    error -> {:error, {:invalid_file, Exception.message(error)}}
  end

  @doc "Appends a model change entry recording a model ref switch."
  @spec append_model_change(t(), String.t()) :: t()
  def append_model_change(%__MODULE__{} = file, model) when is_binary(model) do
    append(file, %{"type" => "model_change", "model" => model})
  end

  @doc """
  Appends a resume id entry: the id that the provider `provider_id` sent in
  a `{:resume, id, cut}` stream event. Like message text, both
  strings must be valid UTF-8 when they reach the file, and the id must pass
  `Helyx.Message.resume_id?/1`, else a resume rejects the file. The caller
  checks them where they enter the session.
  """
  @spec append_resume_id(t(), String.t(), String.t()) :: t()
  def append_resume_id(%__MODULE__{} = file, provider_id, id)
      when is_binary(provider_id) and is_binary(id) do
    # "harness_session" and "harness_session_id" are stored names: session
    # files on disk hold them, so they stay.
    append(file, %{
      "type" => "harness_session",
      "provider" => provider_id,
      "harness_session_id" => id
    })
  end

  @doc "Appends one completed message to the file."
  @spec append_message(t(), Message.t()) :: t()
  def append_message(%__MODULE__{} = file, %Message{} = message) do
    append(file, Codec.encode(message))
  end

  # Internals

  defp check_version(%{"version" => @version}), do: :ok
  defp check_version(header), do: {:error, {:unknown_version, header["version"]}}

  # The most recently started session whose header matches the working
  # directory. Two directories can share a slug, so the header decides.
  defp most_recent(project_dir, cwd, max_files) do
    candidates =
      for path <- newest(Path.wildcard(Path.join(project_dir, "*.jsonl")), max_files),
          {:ok, header} <- [read_header(path)],
          header["cwd"] == cwd do
        {header["ts"], path, header}
      end

    case Enum.max_by(candidates, &elem(&1, 0), fn -> nil end) do
      nil -> {:error, :not_found}
      {_ts, path, header} -> {:ok, path, header}
    end
  end

  # The `count` regular files with the newest modification time: one stat
  # per file and no read. The time has a resolution of one second, so the
  # path breaks a tie, and the same directory always gives the same files.
  defp newest(paths, count) do
    stats =
      for path <- paths,
          {:ok, %File.Stat{type: :regular, mtime: mtime}} <- [File.stat(path, time: :posix)] do
        {mtime, path}
      end

    stats |> Enum.sort(:desc) |> Enum.take(count) |> Enum.map(&elem(&1, 1))
  end

  # A header line over the bound is cut, does not decode, and the file is
  # not a session.
  defp read_header(path) do
    with {:ok, head} <- read_up_to(path, @max_header_bytes),
         [line | _] = String.split(head, "\n", parts: 2),
         {:ok, %{"type" => "session"} = header} <- JSON.decode(line) do
      {:ok, header}
    else
      _ -> :error
    end
  end

  # At most `bytes` from the start of a regular file. A pipe or a device
  # would block the open or never end. The fun form of File.open closes the
  # handle on every path.
  defp read_up_to(path, bytes) do
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

  # The newline that the repair appends counts, or the repair would make a
  # file that the next resume rejects.
  defp repaired_size(size, :no_newline), do: size + 1
  defp repaired_size(size, :clean), do: size

  defp check_size(size, max_bytes) when size <= max_bytes, do: :ok

  defp check_size(_size, max_bytes) do
    {:error,
     {:too_large, "the session file is over the #{max_bytes}-byte limit; start a new session"}}
  end

  # Walks the lines one at a time, so a file of many short lines never
  # becomes a list of all its lines. A line that does not decode to an entry
  # is skipped: a torn append, also one that the append of another writer
  # was glued to. Returns the entries in file order, and whether the file
  # ends in a newline, for `repair/2`.
  defp parse(raw, entries) do
    case :binary.split(raw, "\n") do
      [line, rest] -> parse(rest, add_entry(line, entries))
      [""] -> {Enum.reverse(entries), :clean}
      [line] -> {Enum.reverse(add_entry(line, entries)), :no_newline}
    end
  end

  defp add_entry(line, entries) do
    case JSON.decode(line) do
      {:ok, %{"type" => _} = entry} -> [entry | entries]
      _not_an_entry -> entries
    end
  end

  # Nothing is ever removed from the file: a truncate could cut bytes that
  # another writer appended. A last line without its newline gets one, so
  # the next entry starts on a line of its own. A whole last entry is kept;
  # a torn one stays a line that every read skips. A repair that cannot
  # write is an environment failure, not a malformed file.
  defp repair(_path, :clean), do: :ok

  defp repair(path, :no_newline) do
    case File.write(path, "\n", [:append]) do
      :ok -> :ok
      {:error, reason} -> {:error, {:repair_failed, reason}}
    end
  end

  # One entry is one append write: File.write/3 makes one binary of the
  # entry and its newline, opens the file with O_APPEND, and writes it with
  # one writev. Only a short write (a full disk, a signal) takes a second.
  defp append(%__MODULE__{path: path, leaf: leaf} = file, entry) do
    id = Helyx.Session.Id.new()

    entry =
      Map.merge(entry, %{
        "id" => id,
        "parent_id" => leaf,
        "ts" => DateTime.to_iso8601(DateTime.utc_now())
      })

    File.write!(path, [JSON.encode!(entry), "\n"], [:append])
    %{file | leaf: id}
  end

  # The slug keeps the tail of the path, the distinctive end, and stays
  # under the filesystem name limit: 100 characters are 100 bytes because
  # the regex collapses every non-ASCII byte to "-". Collisions are fine:
  # the header `cwd` decides which sessions belong to a directory.
  defp project_dir(dir, cwd) do
    Path.join(dir, cwd |> String.replace(~r/[^A-Za-z0-9]+/, "-") |> String.slice(-100, 100))
  end
end
