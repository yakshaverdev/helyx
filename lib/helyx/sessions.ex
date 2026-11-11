defmodule Helyx.Sessions do
  @moduledoc """
  The server-management API: the live and the saved sessions of a Core, and
  their start, resume, and stop (`docs/features/server-management.md`).

  The server configuration is the start options of `Helyx.Core`:
  `:sessions_dir` and the default `:model`. A Core runs at most 64
  sessions; a start or a resume over the cap gives
  `{:error, :too_many_sessions}`. A resume of a session that runs in the
  Core attaches to it, also at the cap, and concurrent resumes of one id
  get one result; an attach with other `:provider_opts` than the running
  session's gives `{:error, :provider_opts_differ}`.

  `watch/2` follows every session of the Core without a subscription to
  each: the feed sends the `Live` of a session at its open and at each
  change of status or model, and the events of the types that the watcher
  names (`docs/features/session-feed.md`).
  """

  alias Helyx.Session
  alias Helyx.Session.File, as: SessionFile
  alias Helyx.Session.File.{Edit, Scan}
  alias Helyx.Session.{Id, Input}

  # The timeout of each call of `Helyx.Session` but `abort/1`.
  @call_timeout_ms 5_000

  @max_page 256
  @default_page 50

  # The deadline of `remove_message/3` up to its rename: a base for the
  # small file and the margin for load, then one ms for each 1,000 bytes of
  # each of the three passes over the file (the read, the copy, and its
  # write), as the open of a session counts its load
  # (`docs/features/session-edit.md`, "Bounds").
  @remove_base_ms 25_000
  @remove_passes 3

  defmodule Live do
    @moduledoc """
    One session of `Helyx.Sessions.list_live/1`, and the notice of a start,
    a resume, or a change of status or model that
    `Helyx.Sessions.watch/2` sends. `model` is the current model ref.
    `status` is `:idle` when the session has no turn and no wait after a
    turn, else `:running`. `parent` is the link of a child to the tool call
    that started it (`docs/features/agent-tool.md`), or nil.
    """
    @enforce_keys [:id, :instance_id, :cwd, :model, :status, :parent]
    defstruct @enforce_keys

    @type parent :: %{session_id: String.t(), call_id: String.t()} | nil

    @type t :: %__MODULE__{
            id: String.t(),
            instance_id: String.t(),
            cwd: String.t(),
            model: String.t(),
            status: :idle | :running,
            parent: parent()
          }
  end

  @doc """
  The sessions that run in `core`, at most 64, in no order. Each session
  answers a call; the calls run in parallel under one deadline of
  #{@call_timeout_ms} ms, and a session that does not answer in time, such
  as one in its open or its stop, is left out. A Core that is not running
  has none.
  """
  @spec list_live(Helyx.Core.name()) :: [Live.t()]
  def list_live(core) do
    # The Registry also holds `{:edit, id}` keys of file edits; a session key
    # is a binary.
    pids =
      Registry.select(Helyx.Core.sessions_registry(core), [
        {{:"$1", :"$2", :_}, [{:is_binary, :"$1"}], [:"$2"]}
      ])

    stream =
      Task.Supervisor.async_stream(Helyx.Core.task_supervisor(core), pids, &live/1,
        max_concurrency: max(length(pids), 1),
        timeout: :infinity
      )

    for {:ok, %Live{} = live} <- stream, do: live
  rescue
    # The Registry is gone with its Core, and so are the sessions.
    ArgumentError -> []
  end

  # A late answer goes to the Task, which ended.
  defp live(pid) do
    GenServer.call(pid, :live, @call_timeout_ms)
  catch
    :exit, _reason -> nil
  end

  @doc """
  Registers the calling process as a watcher of `core`: it gets the `Live`
  of every session of the Core at its open and at each change of status or
  model, and the events whose type is in `types`. A second `watch/2` by the
  same process replaces the first, and `unwatch/1` ends the notices.

  Messages, each from the session process:

    * `{:helyx_feed, session_pid, %Helyx.Sessions.Live{}}`
    * `{:helyx_feed, session_pid, %Helyx.Event{}}` for a named type

  Per session the order is the send order: the first `Live` of an instance
  comes before every event of it, and a `Live` with a new status comes before
  the events of that status. Notices of two sessions have no order. No
  notice tells of a stop: monitor `session_pid`, whose `:DOWN` reason
  `Helyx.Session.end_reason/1` maps.

  Returns the counter of the notices that the feed dropped, which
  `dropped/1` reads. A watcher whose mailbox is at
  `max_feed_queue/0` loses its notices, and the count says how many: read
  `list_live/1` again to repair the view. A `core` that is not running
  raises `ArgumentError`.
  """
  @spec watch(Helyx.Core.name(), [Helyx.Event.type()]) ::
          {:ok, :counters.counters_ref()} | {:error, :invalid_types}
  def watch(core, types) when is_list(types) do
    if Enum.all?(types, &(&1 in Helyx.Event.types())) do
      :ok = unwatch(core)
      dropped = :counters.new(1, [:write_concurrency])
      registry = Helyx.Core.feed_registry(core)

      for key <- Enum.uniq([:live | types]),
          do: {:ok, _} = Registry.register(registry, key, dropped)

      {:ok, dropped}
    else
      {:error, :invalid_types}
    end
  end

  def watch(_core, _types), do: {:error, :invalid_types}

  @doc "Ends the notices of the calling process to the feed of `core`."
  @spec unwatch(Helyx.Core.name()) :: :ok
  def unwatch(core) do
    registry = Helyx.Core.feed_registry(core)
    Enum.each(Registry.keys(registry, self()), &Registry.unregister(registry, &1))
  end

  @doc "The number of notices that the feed dropped for the watch of `ref`."
  @spec dropped(:counters.counters_ref()) :: non_neg_integer()
  def dropped(ref), do: :counters.get(ref, 1)

  @doc "The mailbox length of a watcher at which the feed drops its notices."
  @spec max_feed_queue() :: pos_integer()
  defdelegate max_feed_queue, to: Helyx.Session.Server.Feed, as: :max_queue

  @doc """
  One page of the saved sessions of the `:sessions_dir` of `core`, newest
  first by the modification time of the file, then by id. `:cwd` is a
  folder, or absent for every folder. `:limit` is from 1 to #{@max_page},
  default #{@default_page}. `:after` is the `next` of the page before: the
  page holds the sessions after it in this order, so a session saved
  between two pages moves no item. `next` is nil on the last page. The
  items and their bounds are those of `Helyx.Session.File.Scan.list/2`.
  """
  @spec list_saved(Helyx.Core.name(), keyword()) ::
          {:ok, [Scan.Summary.t()], String.t() | nil}
          | {:error, :invalid_cwd | :invalid_limit | :invalid_cursor}
  def list_saved(core, opts) do
    with {:ok, scope} <- scope(opts),
         {:ok, limit} <- limit(Keyword.get(opts, :limit, @default_page)),
         {:ok, cursor} <- cursor(Keyword.fetch(opts, :after)) do
      {page, rest} =
        core
        |> saved(scope)
        |> Enum.sort_by(&key/1, :desc)
        |> Enum.drop_while(&(cursor && key(&1) >= cursor))
        |> Enum.split(limit)

      {:ok, page, if(rest != [], do: next(List.last(page)))}
    end
  end

  defp saved(core, scope) do
    case Helyx.Core.config(core, :sessions_dir) do
      nil -> []
      dir -> Scan.list(dir, scope)
    end
  end

  defp scope(opts) do
    case Keyword.fetch(opts, :cwd) do
      :error -> {:ok, :all}
      {:ok, cwd} -> Input.cwd(cwd)
    end
  end

  defp limit(limit) when is_integer(limit) and limit in 1..@max_page, do: {:ok, limit}
  defp limit(_limit), do: {:error, :invalid_limit}

  defp key(%Scan.Summary{mtime: mtime, id: id}), do: {mtime, id}

  defp next(summary), do: "#{summary.mtime}:#{summary.id}"

  defp cursor(:error), do: {:ok, nil}

  defp cursor({:ok, cursor}) when is_binary(cursor) do
    with [mtime, id] <- String.split(cursor, ":", parts: 2),
         {mtime, ""} <- Integer.parse(mtime),
         true <- Id.valid?(id) do
      {:ok, {mtime, id}}
    else
      _ -> {:error, :invalid_cursor}
    end
  end

  defp cursor(_cursor), do: {:error, :invalid_cursor}

  @doc """
  The id of the session that `start/2` gives with `parent: %{session_id:
  session_id, call_id: call_id}`: derived from the link, so a client shows
  the child of a call before the call ends (`docs/features/agent-tool.md`).
  """
  @spec child_id(String.t(), String.t()) :: String.t()
  def child_id(session_id, call_id) when is_binary(session_id) and is_binary(call_id),
    do: Helyx.Session.Id.child(session_id, call_id)

  @doc """
  Starts a session as `Helyx.Session.start/2` does, with the `:sessions_dir`
  of `core`, and its default `:model` when `opts` names none. With neither
  model the error is `{:invalid_model_ref, ""}`.
  """
  @spec start(Helyx.Core.name(), keyword()) :: {:ok, Session.t()} | {:error, term()}
  def start(core, opts) do
    model = Keyword.get(opts, :model) || Helyx.Core.config(core, :model) || ""

    Session.start(
      core,
      Keyword.merge(opts, model: model, sessions_dir: Helyx.Core.config(core, :sessions_dir))
    )
  end

  @doc """
  Resumes a session as `Helyx.Session.resume/2` does, from the
  `:sessions_dir` of `core`: the session `:id`, in the folder that its
  header names when `opts` names no `:cwd`, or the newest session of
  `:cwd`. A Core with no `:sessions_dir` gives `{:error, :not_found}`. The
  errors of the find of an id are those of `Helyx.Session.File.Scan.find/2`,
  and `:invalid_cwd` for a header folder that a start would reject. They
  come after the tool checks.
  """
  @spec resume(Helyx.Core.name(), keyword()) :: {:ok, Session.t()} | {:error, term()}
  def resume(core, opts) do
    case Helyx.Core.config(core, :sessions_dir) do
      nil -> {:error, :not_found}
      dir -> Session.resume(core, [sessions_dir: dir] ++ opts)
    end
  end

  @doc """
  Deletes the saved session `id` from the `:sessions_dir` of `core`: its
  file and the copy that a failed `remove_message/3` left.

  Errors, each with no change: `:not_found` for an id with no file (or a
  Core with no `:sessions_dir`), `:invalid_id`, `:duplicate_id`, and
  `:running` when a session of the id runs in `core`, or another edit of
  the id runs; the caller stops the session first. `:not_regular` for a
  path that is a symlink or not a file, `{:edit_failed, text}` when a
  remove fails, and a POSIX reason of the stat of the file. The one
  exception, where the file may or may not have changed: `:unknown`, an
  end of the work with no result, such as at a stop of the Core.

  It does not remove what is kept outside the file
  (`docs/features/session-edit.md`, "What the calls do not remove").
  """
  @spec delete(Helyx.Core.name(), String.t()) ::
          :ok
          | {:error,
             :not_found
             | :invalid_id
             | :duplicate_id
             | :running
             | :not_regular
             | :unknown
             | {:edit_failed, String.t()}
             | File.posix()}
  def delete(core, id) when is_binary(id) do
    with {:ok, dir} <- sessions_dir(core),
         {:ok, path} <- Scan.locate(dir, id) do
      Edit.run(core, nil, fn nil -> Edit.delete(core, id, path) end)
    end
  end

  @doc """
  Removes the message `message_id` from the saved session `id` of the
  `:sessions_dir` of `core`, and returns the ids of every message that it
  removed, in their order, message ids only. The transcript keeps complete
  tool call and result pairs: a removed assistant message takes the tool
  results right after it, and a removed tool result takes that assistant
  message and its other results. The `hook` entries that name a call id
  of the removed messages go too, by the call id alone. After the call the
  file holds no byte of the removed messages, is one chain, and a resume,
  and its `Helyx.Memory` sync, gives the other messages in their order.

  Errors, each with no change of the file: those of `delete/2`, the read
  errors of a resume of the file (such as `{:invalid_file, text}`),
  `:message_not_found` for an id that is no message of the file, and
  `:timeout` past the deadline, 25,000 ms plus 3 ms for each 1,000 bytes
  of the file: the deadline ends before the rename, and only a kill of the
  deadline gives `:timeout`. The exception of `delete/2` holds for the
  rename.

  It does not remove what is kept outside the file
  (`docs/features/session-edit.md`, "What the calls do not remove").
  """
  @spec remove_message(Helyx.Core.name(), String.t(), String.t()) ::
          {:ok, [String.t()]}
          | {:error,
             :not_found
             | :invalid_id
             | :duplicate_id
             | :running
             | :message_not_found
             | :timeout
             | :unknown
             | {:edit_failed, String.t()}
             | SessionFile.error()}
  def remove_message(core, id, message_id) when is_binary(id) and is_binary(message_id) do
    with {:ok, dir} <- sessions_dir(core),
         {:ok, path, %{"cwd" => cwd}} <- Scan.find(dir, id),
         {:ok, size} <- size(path) do
      budget = @remove_base_ms + div(size * @remove_passes, 1_000)
      Edit.run(core, budget, &Edit.remove_message({core, id, path}, cwd, message_id, &1))
    end
  end

  # A delete can remove the file after the find.
  defp size(path) do
    case File.stat(path) do
      {:ok, %File.Stat{size: size}} -> {:ok, size}
      {:error, :enoent} -> {:error, :not_found}
      {:error, _reason} = error -> error
    end
  end

  defp sessions_dir(core) do
    case Helyx.Core.config(core, :sessions_dir) do
      nil -> {:error, :not_found}
      dir -> {:ok, dir}
    end
  end

  @doc """
  Stops a session: a running turn aborts first, as at
  `Helyx.Session.abort/1`, then the session process stops, so each
  subscriber gets its end signal, whose `Helyx.Session.end_reason/1` is
  `:stopped`. Returns after the session ended: `:ok` when every handle of
  the session was released, and
  `{:error, {:not_released, handles}}` when a release failed or timed
  out, with the handles still held, or `:unknown` when the stop got no
  answer of the hands or another end of the session, such as a second stop
  or a Core stop, came first (`docs/features/session-lifecycle.md`,
  "Session stop"). A child process that left its process group can
  survive any stop. A session that is not running at the call gives
  `{:error, :session_not_found}`. The supervisor frees the place of the
  session in the cap when it handles the exit.

  With the pid of a session process, the stop acts on that process only,
  never on a later instance of its id, and a process that is gone gives
  `{:error, {:not_released, :unknown}}` (`docs/features/agent-tool.md`).
  """
  @spec stop(Session.t() | pid()) ::
          :ok | {:error, :session_not_found | {:not_released, [term()] | :unknown}}
  def stop(%Session{} = session) do
    case Session.pid(session) do
      nil -> {:error, :session_not_found}
      pid -> stop(pid)
    end
  end

  def stop(pid) when is_pid(pid) do
    ref = Process.monitor(pid)
    report = stop_pid(pid)

    # `terminate/2` replies; the session ends after it.
    receive do
      {:DOWN, ^ref, :process, _pid, _reason} -> report
    end
  end

  # The abort and the stop go to the one pid that ran at the call.
  defp stop_pid(pid) do
    :ok = GenServer.call(pid, :abort, :infinity)
    GenServer.call(pid, :stop, :infinity)
  catch
    # Another end came first: the session ended with no report.
    :exit, {_reason, {GenServer, :call, _args}} -> {:error, {:not_released, :unknown}}
  end
end
