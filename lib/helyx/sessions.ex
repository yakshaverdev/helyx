defmodule Helyx.Sessions do
  @moduledoc """
  The server-management API: the live and the saved sessions of a Core, and
  their start, resume, and stop (`docs/features/server-management.md`).

  The server configuration is the start options of `Helyx.Core`:
  `:sessions_dir` and the default `:model`. A Core runs at most 64
  sessions; a start or a resume over the cap gives
  `{:error, :too_many_sessions}`. A resume of a session that runs in the
  Core attaches to it, also at the cap, and concurrent resumes of one id
  get one result.
  """

  alias Helyx.Session
  alias Helyx.Session.File.Scan
  alias Helyx.Session.{Id, Input}

  # The timeout of each call of `Helyx.Session` but `abort/1`.
  @call_timeout_ms 5_000

  @max_page 256
  @default_page 50

  defmodule Live do
    @moduledoc """
    One session of `Helyx.Sessions.list_live/1`. `model` is the current
    model ref. `status` is `:idle` when the session has no turn and no wait
    after a turn, else `:running`.
    """
    @enforce_keys [:id, :instance_id, :cwd, :model, :status]
    defstruct @enforce_keys

    @type t :: %__MODULE__{
            id: String.t(),
            instance_id: String.t(),
            cwd: String.t(),
            model: String.t(),
            status: :idle | :running
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
    pids = Registry.select(Helyx.Core.sessions_registry(core), [{{:_, :"$1", :_}, [], [:"$1"]}])

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
  errors of the find of an id are those of `Helyx.Session.File.Scan.find/2`.
  """
  @spec resume(Helyx.Core.name(), keyword()) :: {:ok, Session.t()} | {:error, term()}
  def resume(core, opts) do
    with dir when is_binary(dir) <- Helyx.Core.config(core, :sessions_dir),
         {:ok, opts} <- folder(dir, opts) do
      Session.resume(core, [sessions_dir: dir] ++ opts)
    else
      nil -> {:error, :not_found}
      error -> error
    end
  end

  defp folder(dir, opts) do
    case {Keyword.fetch(opts, :id), Keyword.has_key?(opts, :cwd)} do
      {{:ok, id}, false} ->
        with {:ok, _path, %{"cwd" => cwd}} <- Scan.find(dir, id), do: {:ok, [cwd: cwd] ++ opts}

      _ ->
        {:ok, opts}
    end
  end

  @doc """
  Stops a session: a running turn aborts first, as at
  `Helyx.Session.abort/1`, then the session process stops, so each
  subscriber gets its end signal, whose `Helyx.Session.end_reason/1` is
  `:stopped`, and the lock of its file is released. Returns after the
  session ended. A session that is not running gives
  `{:error, :session_not_found}`. The supervisor frees the place of the
  session in the cap when it handles the exit.
  """
  @spec stop(Session.t()) :: :ok | {:error, :session_not_found}
  def stop(%Session{} = session) do
    with :ok <- Session.abort(session),
         do: GenServer.stop(Session.Server.via(session.core, session.id), :normal, :infinity)
  catch
    # The session ended between the abort and the stop.
    :exit, {:noproc, _call} -> {:error, :session_not_found}
  end
end
