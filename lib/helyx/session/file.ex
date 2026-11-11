defmodule Helyx.Session.File do
  @moduledoc """
  The session file: append-only JSON lines, one entry per line, one chain
  by `parent_id` (ADR 0001). A session lives at
  `<dir>/<project slug>/<session id>.jsonl`, a session with a parent link
  at `<dir>/.children/<session id>.jsonl` (`path/4`). Only completed
  messages are appended. `pick/3` picks the file of a session, `resume_picked/3`
  restores its chain; only `Helyx.Sessions.delete/2` and `remove_message/3` remove bytes.

  The format, the rules for a damaged file, and the bounds are in
  `docs/features/coding-agent.md`, section "Session file".
  """

  alias Helyx.Message
  alias Helyx.Session.File.{Codec, Reader, Scan}
  alias Helyx.Session.Input

  # The most bytes of one line. The largest entry that a session writes is
  # an assistant message: 8 MiB of content (`Helyx.Session.Turn`), at most
  # 6 bytes of JSON for each byte (`\u0001`), is 48 MiB, plus the framing
  # of its 1,024 blocks and its other fields.
  @max_entry_bytes 64 * 1024 * 1024

  # The heap cap of the decode of one line, above the largest decode that
  # a session-written entry needs (row "Session file on resume").
  @max_heap_bytes 1024 * 1024 * 1024

  # The most bytes of the text of one system prompt entry (turn-record.md).
  @max_system_bytes 262_144

  # `system_hash`: the SHA-256 of the last system prompt written, nil for
  # nil, or `:unset` before the first (docs/features/turn-record.md).
  @enforce_keys [:path]
  defstruct [:path, :leaf, system_hash: :unset]

  @type t :: %__MODULE__{
          path: Path.t(),
          leaf: String.t() | nil,
          system_hash: binary() | nil | :unset
        }

  defmodule Resumed do
    @moduledoc """
    What `resume_picked/3` restores. `resume_ids` holds the last resume id of each
    provider: the id and the number of assistant messages before its entry, and the
    number at the last compaction of that provider after it, if any
    (`Helyx.Session.Transcript.label/0`). `summary` is the last `Helyx.Summary`, or
    nil. `compacted` is the last compaction or summary: the id of the
    message before it that its entry names, and its `tokens_after`, or nil
    (`Helyx.Session.Totals.of/2`).
    `activated` holds the names of the last `tools_change` entry (`mcp-client.md`).
    """
    @enforce_keys [:file, :model, :messages]
    defstruct [:file, :model, :messages, :summary, :compacted, resume_ids: %{}, activated: []]

    @type t :: %__MODULE__{
            file: Helyx.Session.File.t(),
            model: String.t(),
            messages: [Message.t()],
            summary: Helyx.Summary.t() | nil,
            compacted: Helyx.Session.Totals.compaction() | nil,
            resume_ids: %{String.t() => Helyx.Session.Transcript.label()},
            activated: [String.t()]
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
  `model` must be valid UTF-8, and `parent` nil or a checked link of the
  session to a tool call; `Helyx.Session.start/2` checks them. The create
  is exclusive: a file that exists, such as a child of a link that started
  one before (`Helyx.Sessions.child_id/2`), gives
  `{:error, {:create_failed, :eexist}}` and is not written.
  """
  @spec create(Path.t(), String.t(), String.t(), String.t(), map() | nil) ::
          {:ok, t()} | {:error, error()}
  def create(dir, session_id, cwd, model, parent \\ nil) do
    path = path(dir, cwd, session_id, parent)

    with :ok <- mkdir(dir, cwd, parent),
         :ok <- new_file(path) do
      {:ok, append(%__MODULE__{path: path}, Scan.header(cwd, model, parent))}
    end
  rescue
    # The header write failing right after the mkdir succeeded.
    error in File.Error -> {:error, {:create_failed, error.reason}}
  end

  # A derived id can name the file of an earlier child.
  defp new_file(path) do
    case File.open(path, [:write, :exclusive]) do
      {:ok, io} -> File.close(io)
      {:error, reason} -> {:error, {:create_failed, reason}}
    end
  end

  @doc """
  Makes the sessions folder `dir`, the project folder of `cwd` in it, and
  with a parent link the folder of the children in that (`path/4`). A
  sessions folder that this call makes gets mode 0700 (#683); one that
  exists keeps its mode (`coding-agent.md`, row "sessions folder mode").
  """
  @spec mkdir(Path.t(), String.t(), map() | nil) :: :ok | {:error, {:create_failed, File.posix()}}
  def mkdir(dir, cwd, parent \\ nil) do
    with :ok <- mkdir(dir),
         {:error, reason} <- File.mkdir_p(Scan.folder(dir, cwd, parent)),
         do: {:error, {:create_failed, reason}}
  end

  @doc "Makes the sessions folder `dir` alone, with the mode rule of `mkdir/3`."
  @spec mkdir(Path.t()) :: :ok | {:error, {:create_failed, File.posix()}}
  def mkdir(dir) do
    # The folder that `dir` names, with no `.`, `..`, or `/` at its end, so
    # that the result of one mkdir tells a new folder (#683). `absname`
    # first keeps a leading `~` a name, as the other file calls read it.
    sessions = dir |> Path.absname() |> Path.expand()

    # The mkdir failing is the caller's configuration, not a crash.
    with :ok <- File.mkdir_p(Path.dirname(sessions)),
         :ok <- restrict(sessions, File.mkdir(sessions)) do
      :ok
    else
      {:error, reason} -> {:error, {:create_failed, reason}}
    end
  end

  # A folder left with its umask mode would pass for one that existed at the
  # next start, so a failed chmod tries to remove the folder it made.
  defp restrict(dir, :ok) do
    with {:error, _reason} = error <- File.chmod(dir, 0o700) do
      _ = File.rmdir(dir)
      error
    end
  end

  defp restrict(_dir, {:error, :eexist}), do: :ok
  defp restrict(_dir, error), do: error

  @doc """
  The path of the file that `create/5` writes for the session `session_id`
  of `cwd`; a session with a parent link is in the folder of children,
  whatever its cwd, out of the scan of the list (`Helyx.Session.File.Scan`).
  """
  @spec path(Path.t(), String.t(), String.t(), map() | nil) :: Path.t()
  def path(dir, cwd, session_id, parent \\ nil),
    do: Path.join(Scan.folder(dir, cwd, parent), session_id <> ".jsonl")

  @doc """
  Reads the session file at `path`, a result of `pick/3` for `cwd`.

  Returns the file handle, the current model, and the transcript: the
  entries in file order, chained by `parent_id`. The rules for a damaged file are in
  `docs/features/coding-agent.md`, "Session file": a line that does not
  decode is skipped, and an entry that does not continue the chain is
  `{:invalid_file, text}` with its line number. The read uses its own
  header: a header that names another directory is `:not_found`.

  The read takes one line at a time, so the file has no size limit: the
  resume holds the transcript, and the bytes of the file that its texts
  share. A line over #{@max_entry_bytes} bytes, or one whose decode needs
  a heap over #{@max_heap_bytes} bytes, is no entry that a session writes:
  it is rejected as `{:too_large, text}`, and the file is not mutated.

  `:max_entry_bytes` lowers the line limit, and `:max_heap_bytes` the heap
  cap, so that a test reaches a limit with small input; they are not checked.
  """
  @spec resume_picked(Path.t(), String.t(),
          max_entry_bytes: pos_integer(),
          max_heap_bytes: pos_integer()
        ) :: {:ok, Resumed.t()} | {:error, error()}
  def resume_picked(path, cwd, opts \\ []) do
    with {:ok, resumed, tail, _limits} <- read_picked(path, cwd, opts),
         # The repair write comes last, after every check passed, so a
         # file this function rejects is never mutated.
         :ok <- repair(path, tail) do
      {:ok, resumed}
    end
  end

  @doc """
  The session file to resume and its folder, with no read past the
  header: the session of `:id`, or the most recently started session of
  `cwd` that has a message. The scan and its bounds are in
  `Helyx.Session.File.Scan`; `:max_scanned_files` lowers its file count
  for a test. A session of the id whose header names another directory is
  `:not_found`. With `:id` and a nil `cwd`, the folder is the one that the
  header names, checked as `Helyx.Session.start/2` checks a `:cwd`; a nil
  `cwd` needs `:id`.
  `Helyx.Session.resume/2` takes the lock of this file before
  `resume_picked/3`, which reads the header again.
  """
  @spec pick(Path.t(), String.t() | nil, keyword()) ::
          {:ok, Path.t(), String.t()} | {:error, error() | :invalid_cwd}
  def pick(dir, cwd, opts) do
    case Keyword.fetch(opts, :id) do
      :error ->
        with {:ok, path, _header} <- Scan.most_recent(dir, cwd, opts), do: {:ok, path, cwd}

      {:ok, id} ->
        with {:ok, path, header} <- Scan.find(dir, id), do: match_cwd(path, header["cwd"], cwd)
    end
  end

  # `Scan.find/2` gives a header with a string cwd.
  defp match_cwd(path, found, cwd) when found == cwd and is_binary(found), do: {:ok, path, cwd}

  # The header is disk input.
  defp match_cwd(path, found, nil) when is_binary(found) do
    with {:ok, found} <- Input.cwd(found), do: {:ok, path, found}
  end

  defp match_cwd(_path, found, _cwd) when is_binary(found), do: {:error, :not_found}

  @doc false
  # The read of `resume_picked/3` with no repair write, and its limits.
  def read_picked(path, cwd, opts) do
    entry = Keyword.get(opts, :max_entry_bytes, @max_entry_bytes)
    heap = Keyword.get(opts, :max_heap_bytes, @max_heap_bytes)
    limits = %Reader.Limits{entry: entry, heap: heap}

    with {:ok, read, tail} <- Scan.with_regular(path, &Reader.read(&1, cwd, limits)) do
      resumed = %Resumed{
        file: %__MODULE__{path: path, leaf: read.leaf},
        model: read.model,
        messages: read.messages,
        summary: read.summary,
        compacted: read.compacted,
        resume_ids: read.resume_ids,
        activated: read.activated
      }

      {:ok, resumed, tail, limits}
    end
  rescue
    # The file is on-disk data anyone can edit. An entry with a shape this
    # module never writes is rejected, not raised at the caller.
    error -> {:error, {:invalid_file, Exception.message(error)}}
  end

  @doc "Appends a model change entry recording a model ref switch."
  @spec append_model_change(t(), String.t()) :: t()
  def append_model_change(%__MODULE__{} = file, model) when is_binary(model),
    do: append(file, %{"type" => "model_change", "model" => model})

  @doc "Appends a tools change entry: the activated tool names (`mcp-client.md`)."
  @spec append_tools_change(t(), [String.t()]) :: t()
  def append_tools_change(%__MODULE__{} = file, names) when is_list(names),
    do: append(file, %{"type" => "tools_change", "activated" => names})

  @doc """
  Appends a resume id entry: the id that the provider `provider_id` sent in
  a `{:resume_id, id, cut}` stream event. Both strings must be valid UTF-8,
  and the id must pass `Helyx.Message.resume_id?/1`, else a resume does not
  use it; the caller checks them where they enter the session.
  """
  @spec append_resume_id(t(), String.t(), String.t()) :: t()
  def append_resume_id(%__MODULE__{} = file, provider_id, id)
      when is_binary(provider_id) and is_binary(id) do
    append(file, %{
      "type" => "resume_id",
      "provider" => provider_id,
      "resume_id" => id
    })
  end

  @doc """
  Appends a compaction entry: the provider `provider_id` compacted its own
  history (`docs/features/harness-compaction.md`). A resume adds no message
  for it, and reads it for the resume id of that provider. `last_id` is the
  id of the last transcript message before it, or nil
  (`docs/features/session-snapshot.md`, "State fields").
  """
  @spec append_compaction(
          t(),
          String.t(),
          :manual | :auto,
          integer() | nil,
          integer() | nil,
          String.t() | nil
        ) :: t()
  def append_compaction(%__MODULE__{} = file, provider_id, trigger, before, after_, last_id)
      when is_binary(provider_id) and trigger in [:manual, :auto] do
    append(file, %{
      "type" => "compaction",
      "provider" => provider_id,
      "trigger" => Atom.to_string(trigger),
      "tokens_before" => before,
      "tokens_after" => after_,
      "last_id" => last_id
    })
  end

  @doc """
  Appends a summary entry (`docs/features/summary-compaction.md`): a
  resume adds no message for it, and takes the last one as the summary.
  `last_id` is as in `append_compaction/6`.
  """
  @spec append_summary(t(), Helyx.Summary.t(), String.t() | nil) :: t()
  def append_summary(%__MODULE__{} = file, %Helyx.Summary{} = summary, last_id) do
    append(file, %{
      "type" => "summary",
      "summary" => summary.text,
      "first_kept_id" => summary.first_kept_id,
      "tokens_before" => summary.tokens_before,
      "last_id" => last_id
    })
  end

  @doc """
  Appends a system prompt entry (`docs/features/turn-record.md`): the
  system prompt of the next provider call, or nil, and `bytes`, the size
  of the whole text, unless it is the last prompt that this file holds:
  then the file is returned as it is. A text over #{@max_system_bytes} bytes is stored cut
  to its first #{@max_system_bytes} bytes, on a character boundary. The
  text is valid UTF-8 (`Helyx.Session.Stream.prepare/4` checks it).
  """
  @spec append_system_prompt(t(), String.t() | nil) :: t()
  def append_system_prompt(%__MODULE__{system_hash: last} = file, system)
      when is_binary(system) or is_nil(system) do
    case system && :crypto.hash(:sha256, system) do
      ^last ->
        file

      hash ->
        entry = %{
          "type" => "system_prompt",
          "system" => cap_system(system),
          "bytes" => if(system, do: byte_size(system), else: 0)
        }

        %{append(file, entry) | system_hash: hash}
    end
  end

  @doc "The most bytes of the text of one system prompt entry: #{@max_system_bytes}."
  @spec max_system_bytes() :: pos_integer()
  def max_system_bytes, do: @max_system_bytes

  # The text is valid, so only a character that the cut splits is invalid.
  defp cap_system(system) when is_nil(system) or byte_size(system) <= @max_system_bytes,
    do: system

  defp cap_system(system),
    do: system |> binary_part(0, @max_system_bytes) |> String.replace_invalid("")

  @doc """
  Appends one completed message to the file. Its entry id is the id of the
  message, which must have one; a resume reads it back as the message id.
  """
  @spec append_message(t(), Message.t()) :: t()
  def append_message(%__MODULE__{} = file, %Message{} = message),
    do: append(file, Codec.encode(message))

  # The repair never truncates: that could cut bytes that another writer
  # appended. A last line without its newline gets one, so the next entry
  # starts on its own line: a whole last entry is kept, a torn one stays a
  # line that every read skips. A failed write is the environment's fault.
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
  @doc false
  def append(%__MODULE__{path: path, leaf: leaf} = file, entry) do
    # A message entry has the message id (`Codec.encode/1`).
    id = Map.get_lazy(entry, "id", &Helyx.Session.Id.new/0)

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
