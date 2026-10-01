defmodule Helyx.Session.File do
  @moduledoc """
  The session file: append-only JSON lines, one entry per line, per ADR 0001.

  A session lives at `<dir>/<project slug>/<session id>.jsonl`, where the
  slug is derived from the working directory. Every entry has an `id`, a
  `parent_id`, a `ts`, and a `type`. The first entry is the header, `type`
  `"session"`, and carries the format version, the working directory, and
  the model. Only completed messages are appended, never streamed partials.

  The file is a tree (ADR 0001). Two writers that append to one file, two
  Cores that resumed one session, make two branches: each entry's
  `parent_id` is the leaf of its own writer. Each entry and its newline go
  to the file in one append write, so on a local filesystem the entries of
  two writers do not interleave.

  `resume/3` picks the most recently started session for a working
  directory and restores the branch of its newest leaf. Nothing is ever
  removed from the file: a line that does not decode is skipped, and a
  last line without its newline gets one before anything else is appended.
  Answering open tool calls is the session's job, not the file's.
  """

  alias Helyx.Message

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

  @no_header "the first entry is not a header"

  @enforce_keys [:path]
  defstruct [:path, :leaf]

  @type t :: %__MODULE__{path: Path.t(), leaf: String.t() | nil}

  defmodule Resumed do
    @moduledoc """
    What `resume/3` restores: the file, the session id, the model, the
    transcript, and the last harness session of each harness provider: its
    id and the number of messages before its entry. A fork of the file at
    or below a harness session entry drops every label at or above the
    fork, so each of those harnesses starts fresh (#282).
    """
    @enforce_keys [:file, :session_id, :model, :messages]
    defstruct [:file, :session_id, :model, :messages, harness_sessions: %{}]

    @type t :: %__MODULE__{
            file: Helyx.Session.File.t(),
            session_id: String.t(),
            model: String.t(),
            messages: [Message.t()],
            harness_sessions: %{String.t() => {String.t(), non_neg_integer()}}
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
  the check for a fork below a harness session entry. A
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
         {:ok, leaf, branch} <- newest_branch(entries),
         :ok <- check_entries(branch) do
      # `entries` is not used after this, so the decode does not keep it alive.
      fork = last_fork(entries, branch)

      resumed = %Resumed{
        file: %__MODULE__{path: path, leaf: leaf},
        session_id: Path.basename(path, ".jsonl"),
        model: current_model(header, branch),
        messages: for(%{"type" => "message"} = entry <- branch, do: decode_message(entry)),
        harness_sessions: harness_sessions(branch, fork)
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
  Appends a harness session entry: the id that the external program of the
  harness provider `provider_id` issued for its harness session. Like message text, both
  strings must be valid UTF-8 when they reach the file, and the id must pass
  `Helyx.Message.harness_id?/1`, else a resume rejects the file. The caller
  checks them where they enter the session.
  """
  @spec append_harness_session(t(), String.t(), String.t()) :: t()
  def append_harness_session(%__MODULE__{} = file, provider_id, id)
      when is_binary(provider_id) and is_binary(id) do
    append(file, %{
      "type" => "harness_session",
      "provider" => provider_id,
      "harness_session_id" => id
    })
  end

  @doc "Appends one completed message to the file."
  @spec append_message(t(), Message.t()) :: t()
  def append_message(%__MODULE__{} = file, %Message{} = message) do
    append(file, encode_message(message))
  end

  # Internals

  defp encode_message(%Message{role: role} = message) do
    encoded =
      %{
        "type" => "message",
        "role" => Atom.to_string(role),
        "content" => Enum.map(message.content, &encode_block/1),
        "model" => message.model,
        "stop_reason" => encode_stop_reason(message.stop_reason),
        "tool_call_id" => message.tool_call_id,
        "tool_name" => message.tool_name,
        "usage" => map_size(message.usage) > 0 && message.usage
      }
      |> Map.reject(fn {_key, value} -> value in [nil, false] end)

    if role == :tool_result, do: Map.put(encoded, "is_error", message.is_error), else: encoded
  end

  defp encode_block(%Message.Text{text: text}), do: %{"type" => "text", "text" => text}

  defp encode_block(%Message.Thinking{thinking: thinking, signature: nil}),
    do: %{"type" => "thinking", "thinking" => thinking}

  defp encode_block(%Message.Thinking{thinking: thinking, signature: signature}),
    do: %{"type" => "thinking", "thinking" => thinking, "signature" => signature}

  defp encode_block(%Message.ToolCall{id: id, name: name, arguments: arguments}) do
    %{"type" => "tool_call", "id" => id, "name" => name, "arguments" => arguments}
  end

  defp encode_block(%Message.Image{mime_type: mime_type, data: data}) do
    %{"type" => "image", "mime_type" => mime_type, "data" => data}
  end

  # A bad value of a field that core needs (role, content, tool_call_id,
  # tool_name, is_error) misses its decode clause; the rescue in resume/3
  # turns that into a rejected file. The model, the stop reason, and the
  # usage are optional: a bad one decodes as a missing one, so it does not
  # lose the chat.
  defp decode_message(entry) do
    %Message{
      role: decode_role(entry["role"]),
      content: Enum.map(entry["content"], &decode_block/1),
      model: decode_model(entry["model"]),
      stop_reason: decode_stop_reason(entry["stop_reason"]),
      tool_call_id: optional_string(entry["tool_call_id"]),
      tool_name: optional_string(entry["tool_name"]),
      is_error: decode_is_error(entry["is_error"]),
      usage: decode_usage(entry["usage"])
    }
  end

  defp decode_role("user"), do: :user
  defp decode_role("assistant"), do: :assistant
  defp decode_role("tool_result"), do: :tool_result

  # The clauses are built at compile time from `Message.stop_reasons/0`, so
  # the atoms are interned in this module: a fresh VM that has loaded no
  # provider still decodes a saved file. A stop reason outside the set has
  # no encode clause, so the writer raises an error instead of appending an
  # entry that a later resume would read as no stop reason. On decode, any
  # value outside the set, false too, is no stop reason.
  defp encode_stop_reason(nil), do: nil

  for reason <- Message.stop_reasons() do
    defp decode_stop_reason(unquote(Atom.to_string(reason))), do: unquote(reason)
    defp encode_stop_reason(unquote(reason)), do: unquote(Atom.to_string(reason))
  end

  defp decode_stop_reason(_value), do: nil

  defp optional_string(nil), do: nil
  defp optional_string(value) when is_binary(value), do: value

  defp decode_is_error(nil), do: false
  defp decode_is_error(value) when is_boolean(value), do: value

  defp decode_model(value) when is_binary(value), do: value
  defp decode_model(_value), do: nil

  defp decode_usage(value) when is_map(value), do: Message.cap_integers(value)
  defp decode_usage(_value), do: %{}

  defp decode_block(%{"type" => "text", "text" => text}) when is_binary(text),
    do: %Message.Text{text: text}

  defp decode_block(%{"type" => "thinking", "thinking" => thinking, "signature" => signature})
       when is_binary(thinking) and is_binary(signature),
       do: %Message.Thinking{thinking: thinking, signature: signature}

  defp decode_block(%{"type" => "thinking", "thinking" => thinking} = block)
       when is_binary(thinking) and not is_map_key(block, "signature"),
       do: %Message.Thinking{thinking: thinking}

  defp decode_block(%{"type" => "tool_call", "id" => id, "name" => name, "arguments" => args})
       when is_binary(id) and is_binary(name) and is_map(args) do
    # A file from before #79, or a file that a person changed, can hold an
    # integer over the digit limit. Each later provider request would pay the
    # quadratic JSON encode for it.
    %Message.ToolCall{id: id, name: name, arguments: Message.cap_integers(args)}
  end

  defp decode_block(%{"type" => "image", "mime_type" => mime_type, "data" => data})
       when is_binary(mime_type) and is_binary(data) do
    %Message.Image{mime_type: mime_type, data: data}
  end

  defp check_version(%{"version" => @version}), do: :ok
  defp check_version(header), do: {:error, {:unknown_version, header["version"]}}

  # The writer only produces a header on line one, then messages, model
  # changes, and harness sessions, every one with an id, every model field a
  # string. Anything else on the branch is on-disk corruption, never
  # silently dropped, and never laundered by a later entry that overrides
  # it. An entry on no branch is never read, so its shape is not checked.
  # The harness fields are an optional label: harness_sessions/2 drops a
  # bad one. newest_branch/1 put on the branch only entries with a string
  # id.
  defp check_entries([%{"type" => "session", "model" => model} | rest]) when is_binary(model) do
    case Enum.find(rest, &(not valid_entry?(&1))) do
      nil -> :ok
      bad -> {:error, {:invalid_file, "entry the writer never produces: #{inspect(bad["type"])}"}}
    end
  end

  defp check_entries(_branch), do: {:error, {:invalid_file, @no_header}}

  defp valid_entry?(%{"type" => "message"}), do: true
  defp valid_entry?(%{"type" => "model_change", "model" => model}), do: is_binary(model)
  defp valid_entry?(%{"type" => "harness_session"}), do: true
  defp valid_entry?(_entry), do: false

  # The branch of the newest leaf, header first. The index holds each entry
  # in file order, so a parent is always an earlier entry, the walk from a
  # leaf ends at the header, and a cycle cannot form. The header is the root
  # whatever its own parent_id says: the walk stops at its id. A value in
  # the index is a rooted entry, :unrooted, or {:shared, entry}: an id that
  # a later entry repeats. Before the repeat a child can only mean the
  # first entry, so the branch through it stands; after it, a child cannot
  # tell the two apart and is on no branch, as is the repeat itself.
  #
  # The leaf is the newest rooted entry whose id is not shared: the next
  # append names the leaf as its parent, so a shared leaf would put all new
  # work on no branch. When the header id is shared and no other entry can
  # be the leaf, no entry can take a child, and the file is refused.
  defp newest_branch([%{"id" => root} = header | rest] = entries) when is_binary(root) do
    index = Enum.reduce(rest, %{root => header}, &index_entry/2)

    case Enum.find(Enum.reverse(entries), &match?(%{}, Map.get(index, &1["id"]))) do
      %{"id" => leaf} -> {:ok, leaf, walk(index, root, leaf, [])}
      nil -> {:error, {:invalid_file, "a repeat of the header id leaves no entry to resume"}}
    end
  end

  defp newest_branch(_entries), do: {:error, {:invalid_file, @no_header}}

  # An entry with no string id has no identity: no entry can name it as
  # its parent, so it is on no branch.
  defp index_entry(%{"id" => id}, index) when is_map_key(index, id),
    do: Map.update!(index, id, &shared/1)

  defp index_entry(%{"id" => id} = entry, index) when is_binary(id) do
    parent = entry["parent_id"]

    case index do
      %{^parent => %{}} -> Map.put(index, id, entry)
      _unrooted -> Map.put(index, id, :unrooted)
    end
  end

  defp index_entry(_entry, acc), do: acc

  defp shared(%{} = entry), do: {:shared, entry}
  defp shared(other), do: other

  defp walk(index, root, root, branch), do: [entry_at(index, root) | branch]

  defp walk(index, root, id, branch) do
    entry = entry_at(index, id)
    walk(index, root, entry["parent_id"], [entry | branch])
  end

  defp entry_at(index, id) do
    case Map.fetch!(index, id) do
      {:shared, entry} -> entry
      entry -> entry
    end
  end

  # The last model change wins, else the header's model. Both are strings:
  # check_entries validated every entry before this runs.
  defp current_model(header, entries) do
    Enum.reduce(entries, header["model"], fn
      %{"type" => "model_change"} = entry, _acc -> entry["model"]
      _entry, acc -> acc
    end)
  end

  # The last harness session entry of each provider wins: a lost harness
  # session is followed by a new entry for the same provider. Each keeps the
  # number of messages before it, so the session can tell whether the
  # harness session has made a message since. The label is optional: with
  # none, the provider starts a fresh harness session. A bad id removes the
  # label of its provider, so an earlier, stale label does not come back. An
  # entry with no usable provider removes every label, because the reader
  # cannot know which one it replaced. A fork at the branch entry with the
  # id `fork` removes every label at or above it (#282): the other branch
  # holds those labels too and may have continued their harness sessions.
  defp harness_sessions(entries, fork) do
    {sessions, _count} =
      Enum.reduce(entries, {%{}, 0}, fn entry, acc ->
        {sessions, count} = harness_entry(entry, acc)
        if entry["id"] == fork, do: {%{}, count}, else: {sessions, count}
      end)

    sessions
  end

  defp harness_entry(%{"type" => "message"}, {sessions, count}), do: {sessions, count + 1}

  defp harness_entry(
         %{"type" => "harness_session", "provider" => provider} = entry,
         {sessions, count}
       )
       when is_binary(provider) do
    if Message.harness_id?(entry["harness_session_id"]),
      do: {Map.put(sessions, provider, {entry["harness_session_id"], count}), count},
      else: {Map.delete(sessions, provider), count}
  end

  defp harness_entry(%{"type" => "harness_session"}, {_sessions, count}), do: {%{}, count}
  defp harness_entry(_entry, acc), do: acc

  # The id of the last branch entry, from the first harness session entry
  # down, that an entry of the file off the branch names as its parent, or
  # nil. Every such entry counts, also one on no branch: a fork the reader
  # cannot follow may still be another writer's work, and a wrong fork
  # costs one replay. A branch with no harness session entry has no label
  # to drop, so it builds nothing.
  defp last_fork(entries, branch),
    do: fork_in(entries, Enum.drop_while(branch, &(&1["type"] != "harness_session")))

  defp fork_in(_entries, []), do: nil

  # The branch child of a labelled entry is itself labelled, so an entry off
  # the branch is one whose id is not among these.
  defp fork_in(entries, labelled) do
    ids = MapSet.new(labelled, & &1["id"])

    forks =
      for %{"parent_id" => parent} = entry <- entries,
          MapSet.member?(ids, parent),
          not MapSet.member?(ids, entry["id"]),
          into: MapSet.new(),
          do: parent

    Enum.find_value(Enum.reverse(labelled), fn %{"id" => id} ->
      if MapSet.member?(forks, id), do: id
    end)
  end

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
