defmodule Helyx.Session.File do
  @moduledoc """
  The session file: append-only JSON lines, one entry per line, one chain
  by `parent_id` (ADR 0001). A session lives at
  `<dir>/<project slug>/<session id>.jsonl`. Only completed messages are
  appended. `resume/3` restores the chain of a session, and nothing is ever
  removed from the file. `Helyx.Session.File.Scan` picks the file.

  The format, the rules for a damaged file, and the bounds are in
  `docs/features/coding-agent.md`, section "Session file".
  """

  alias Helyx.Message
  alias Helyx.Session.File.Codec
  alias Helyx.Session.File.Reader
  alias Helyx.Session.File.Scan

  # A resume loads the file whole into the calling process, so the file has a
  # limit. Compaction does not shrink the transcript, so the resume of a
  # session past it fails, and the user starts a new session.
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

  @enforce_keys [:path]
  defstruct [:path, :leaf]

  @type t :: %__MODULE__{path: Path.t(), leaf: String.t() | nil}

  defmodule Resumed do
    @moduledoc """
    What `resume/3` restores. `resume_ids` holds the last resume id of
    each provider: the id and the number of assistant messages before its entry,
    and the number at the last compaction of that provider after it, if
    any (`Helyx.Session.Transcript.label/0`).
    """
    @enforce_keys [:file, :session_id, :model, :messages]
    defstruct [:file, :session_id, :model, :messages, resume_ids: %{}]

    @type t :: %__MODULE__{
            file: Helyx.Session.File.t(),
            session_id: String.t(),
            model: String.t(),
            messages: [Message.t()],
            resume_ids: %{String.t() => Helyx.Session.Transcript.label()}
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
          | :invalid_id
          | :duplicate_id

  @doc """
  Creates the file for a new session and writes the header. `cwd` and
  `model` must be valid UTF-8; `Helyx.Session.start/2` checks both.
  """
  @spec create(Path.t(), String.t(), String.t(), String.t()) :: {:ok, t()} | {:error, error()}
  def create(dir, session_id, cwd, model) do
    path = path(dir, cwd, session_id)

    # The mkdir failing is the caller's configuration, not a crash.
    case File.mkdir_p(Path.dirname(path)) do
      :ok ->
        {:ok, append(%__MODULE__{path: path}, Scan.header(cwd, model))}

      {:error, reason} ->
        {:error, {:create_failed, reason}}
    end
  rescue
    # The header write failing right after the mkdir succeeded.
    error in File.Error -> {:error, {:create_failed, error.reason}}
  end

  @doc "The path of the file that `create/4` writes for the session `session_id` of `cwd`."
  @spec path(Path.t(), String.t(), String.t()) :: Path.t()
  def path(dir, cwd, session_id),
    do: Path.join(Scan.project_dir(dir, cwd), session_id <> ".jsonl")

  @doc """
  Resumes the most recently started session for a working directory that
  has a message, or with `:id` the session of that id. The scan that picks
  the file and its bounds are in `Helyx.Session.File.Scan`. A session of
  the id whose header names another directory is `:not_found`.

  Returns the file handle, the session id, the current model, and the
  transcript: the entries in file order, each the child of the entry
  before it by `parent_id`. The rules for a damaged file are in
  `docs/features/coding-agent.md`, "Session file": a line that does not
  decode is skipped, and an entry that does not continue the chain is
  `{:invalid_file, text}` with its line number. The read uses its own
  header: a header that names another directory is `:not_found`.

  A file over the limit of #{@max_bytes} bytes is rejected as
  `{:too_large, text}` and is not mutated. The read itself stops one byte
  past the limit, so a file that grows during the call is rejected too.

  The read and the decode run in their own process with a heap cap of
  #{@max_heap_bytes} bytes. A file whose decode passes the cap is rejected
  as `{:too_large, text}` and is not mutated. The transcript is copied to
  the caller once.

  `:max_bytes` lowers the file limit, `:max_heap_bytes` lowers the heap
  cap to no less than #{@min_heap_bytes} bytes, and `:max_scanned_files`
  lowers the file count of the scan. They exist so that a test reaches a
  limit with small input.
  """
  @spec resume(Path.t(), String.t(),
          id: String.t(),
          max_bytes: pos_integer(),
          max_heap_bytes: pos_integer(),
          max_scanned_files: pos_integer()
        ) :: {:ok, Resumed.t()} | {:error, error()}
  def resume(dir, cwd, opts \\ []) do
    with {:ok, path} <- pick(dir, cwd, opts), do: resume_picked(path, cwd, opts)
  end

  @doc """
  The read of `resume/3` after its pick: `path` is a result of `pick/3`
  for `cwd`, and the options and errors are those of `resume/3`.
  """
  @spec resume_picked(Path.t(), String.t(),
          max_bytes: pos_integer(),
          max_heap_bytes: pos_integer()
        ) :: {:ok, Resumed.t()} | {:error, error()}
  def resume_picked(path, cwd, opts \\ []) do
    # A bad option is the caller's bug and raises, it is not reported as a
    # bad file.
    resume_within(
      path,
      cwd,
      Keyword.get(opts, :max_bytes, @max_bytes),
      Keyword.get(opts, :max_heap_bytes, @max_heap_bytes)
    )
  end

  # The options only lower the limits, so the read count stays one the OS takes.
  defp resume_within(path, cwd, max_bytes, max_heap_bytes)
       when max_bytes in 1..@max_bytes//1 and
              max_heap_bytes in @min_heap_bytes..@max_heap_bytes//1 do
    with {:ok, resumed, tail} <- load_bounded(path, cwd, max_bytes, max_heap_bytes),
         # The repair write comes last, after every check passed, so a
         # file this function rejects is never mutated.
         :ok <- repair(path, tail) do
      {:ok, resumed}
    end
  end

  @doc """
  The file that `resume/3` would read, with no read past the header: the
  session of `:id`, or the newest of `cwd`. The errors are those of the
  pick in `resume/3`. `Helyx.Session.resume/2` takes the lock of this
  file before `resume_picked/3`, which reads the header again.
  """
  @spec pick(Path.t(), String.t(), keyword()) :: {:ok, Path.t()} | {:error, error()}
  def pick(dir, cwd, opts) do
    case Keyword.fetch(opts, :id) do
      :error ->
        with {:ok, path, _header} <- Scan.most_recent(dir, cwd, opts), do: {:ok, path}

      {:ok, id} ->
        case Scan.find(dir, id) do
          {:ok, path, %{"cwd" => ^cwd}} -> {:ok, path}
          {:ok, _path, _header} -> {:error, :not_found}
          {:error, _reason} = error -> error
        end
    end
  end

  # The wait has no timeout: the process reads at most max_bytes + 1 bytes
  # and dies when its heap passes the cap, so its work is bounded. It is not
  # linked, because the heap kill would take the caller with it; a caller
  # that dies first leaves it to finish that bounded work alone.
  defp load_bounded(path, cwd, max_bytes, max_heap_bytes) do
    heap = %{
      size: div(max_heap_bytes, :erlang.system_info(:wordsize)),
      kill: true,
      error_logger: false
    }

    {pid, ref} =
      :erlang.spawn_opt(fn -> exit({:loaded, load(path, cwd, max_bytes)}) end, [
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

  defp load(path, cwd, max_bytes) do
    with {:ok, raw} <- Scan.read_up_to(path, max_bytes + 1),
         :ok <- check_size(byte_size(raw), max_bytes),
         {:ok, read, tail} <- Reader.read(raw, cwd),
         :ok <- check_size(repaired_size(byte_size(raw), tail), max_bytes) do
      resumed = %Resumed{
        file: %__MODULE__{path: path, leaf: read.leaf},
        session_id: Path.basename(path, ".jsonl"),
        model: read.model,
        messages: read.messages,
        resume_ids: read.resume_ids
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
  a `{:resume_id, id, cut}` stream event. Like message text, both
  strings must be valid UTF-8 when they reach the file, and the id must pass
  `Helyx.Message.resume_id?/1`, else a resume does not use it. The caller
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

  @doc """
  Appends a compaction entry: the provider `provider_id` compacted its own
  history (`docs/features/harness-compaction.md`). A resume adds no message
  for it, and reads it for the resume id of that provider.
  """
  @spec append_compaction(t(), String.t(), :manual | :auto, integer() | nil, integer() | nil) ::
          t()
  def append_compaction(%__MODULE__{} = file, provider_id, trigger, before, after_)
      when is_binary(provider_id) and trigger in [:manual, :auto] do
    append(file, %{
      "type" => "compaction",
      "provider" => provider_id,
      "trigger" => Atom.to_string(trigger),
      "tokens_before" => before,
      "tokens_after" => after_
    })
  end

  @doc "Appends one completed message to the file."
  @spec append_message(t(), Message.t()) :: t()
  def append_message(%__MODULE__{} = file, %Message{} = message) do
    append(file, Codec.encode(message))
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
end
