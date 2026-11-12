defmodule Helyx.Tool.SessionCreate do
  @moduledoc """
  The coordinator tool `session_create`: starts an independent session
  that Hub owns, for the user of the calling session, in a folder with a
  mode of the product, and sends it a first prompt. The session is not a
  child: it has no parent link in Core, and its record names the calling
  session as a thread (`docs/features/coordinator.md`). It outlives the
  call. The start goes through `Helyx.Hub.start_session/3`, so the caps of
  the user hold.

  The optional `worktree` argument starts the session in a new git worktree
  on its own branch, and a checked-in setup script runs there first. See
  `docs/features/coordinator.md` and `docs/features/worktree-sessions.md`.
  """

  @behaviour Helyx.Tool

  alias Helyx.{Coordinator, Session, Worktree}
  alias Helyx.Tool.Args

  @impl true
  def name, do: "session_create"

  @impl true
  def concurrent?, do: true

  @impl true
  def description do
    "Start a new session in a folder with a mode, and send it a first prompt. " <>
      "The session runs on its own after this call; use session_wait and session_read " <>
      "to follow it. Returns the id of the session. " <>
      "With worktree, the session runs in a new git worktree on the branch helyx/<branch>."
  end

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "mode" => %{"type" => "string", "description" => "The mode of the session"},
        "folder" => %{
          "type" => "string",
          "description" => "The absolute path of the working folder of the session"
        },
        "prompt" => %{
          "type" => "string",
          "maxLength" => Session.max_text_bytes(),
          "description" => "The first prompt; empty sends none"
        },
        "worktree" => %{
          "type" => "object",
          "description" => "Start the session in a new git worktree of this folder",
          "properties" => %{
            "branch" => %{
              "type" => "string",
              "description" =>
                "The name after helyx/, at most 64 bytes of lowercase letters, " <>
                  "digits, '.', '_', '/', and '-'"
            },
            "base" => %{
              "type" => "string",
              "description" => "The commit that the worktree starts at; HEAD by default"
            }
          },
          "required" => ["branch"],
          "additionalProperties" => false
        }
      },
      "required" => ["mode", "folder", "prompt"]
    }
  end

  @impl true
  def run(args, _cwd) do
    # The checks that cost nothing come first: a call that they refuse makes
    # no worktree.
    with {:ok, args} <- Args.check(args, parameters()),
         :ok <- folder(args["folder"]),
         {:ok, env} <- Coordinator.setup(),
         {:ok, mode_opts} <- Coordinator.mode(args["mode"]),
         {:ok, worktree} <- worktree(args["worktree"], args["folder"]) do
      create_session(args, env, mode_opts, worktree)
    else
      {:error, text} -> {:error, "session_create: " <> text}
    end
  end

  # The hands release the groups of git and of the setup script through this
  # plugin: `Helyx.Worktree` holds them with `Helyx.Watchdog.start/4`.
  @impl true
  defdelegate release(handles, mode, deadline), to: Helyx.Watchdog.Group

  # A folder that the model gives: an absolute path of a folder that exists.
  defp folder(folder) do
    if Path.type(folder) == :absolute and File.dir?(folder),
      do: :ok,
      else: {:error, "the folder must be the absolute path of a folder that exists"}
  end

  defp worktree(nil, _folder), do: {:ok, nil}

  defp worktree(worktree, folder) do
    Worktree.create(folder, worktree["branch"], worktree["base"])
  end

  defp create_session(args, env, mode_opts, worktree) do
    cwd = cwd(worktree, args["folder"])

    case start(env, cwd, mode_opts) do
      {:ok, session} ->
        started = started(session, cwd, args["mode"], worktree)
        sent(env, session, args["prompt"], started, worktree)

      {:error, text} ->
        {:error, error(text, worktree)}
    end
  end

  # The same subfolder of the new worktree, when the base commit has it.
  defp cwd(nil, folder), do: folder

  defp cwd(worktree, _folder) do
    nested = Path.expand(worktree.rel, worktree.path)
    if File.dir?(nested), do: nested, else: worktree.path
  end

  # The model of the mode, else the model of the calling turn. The thread
  # link names the calling session: a thread is a coordinator concept, so it
  # lives in the Hub row and in no header (docs/features/coordinator.md).
  defp start(env, cwd, mode_opts) do
    opts = [
      cwd: cwd,
      model: mode_opts[:model] || env.context.model,
      model_context: mode_opts[:model_context],
      tools: mode_opts[:tools],
      thread_of: env.context.session_id
    ]

    # The start and its record run in a process that a kill of the call
    # does not end, so a session never runs with no record of its user.
    task =
      Task.Supervisor.async_nolink(Helyx.Core.task_supervisor(env.core), fn ->
        Helyx.Hub.start_session(env.hub, env.user, opts)
      end)

    case Task.await(task, :infinity) do
      {:ok, session} -> {:ok, session}
      {:error, reason} -> {:error, "the session did not start: " <> Coordinator.text(reason)}
    end
  end

  defp started(session, cwd, mode, nil) do
    "session #{session.id} started in #{cwd} with the mode #{mode}"
  end

  defp started(session, cwd, mode, worktree) do
    "session #{session.id} started in #{cwd} with the mode #{mode} in the worktree " <>
      "#{worktree.path} on the branch #{worktree.branch}" <>
      if(worktree.setup, do: " (setup ran)", else: "")
  end

  # A worktree that a failed call made stays: its files and its output are
  # the evidence, and the model can retry in that folder with no worktree.
  defp error(text, nil), do: "session_create: " <> text

  defp error(text, worktree) do
    "session_create: " <>
      text <>
      "; the worktree #{worktree.path} on the branch #{worktree.branch} stays"
  end

  defp sent(_env, _session, "", started, _worktree), do: {:ok, started <> "."}

  # The prompt takes the check of the wire, which moves the record.
  defp sent(env, session, prompt, started, worktree) do
    params = %{"session" => session.id, "text" => prompt}

    with :ok <- Helyx.Hub.authorize(env.hub, env.user, "prompt", params),
         :ok <- Session.prompt(session, prompt, Coordinator.origin(env)) do
      {:ok, started <> ", and it got the prompt."}
    else
      # A session that got no prompt takes no place of the cap.
      {:error, reason} ->
        _ = Helyx.Sessions.stop(session)

        {:error,
         error(
           "the prompt was not sent, so the session #{session.id} was stopped: " <>
             Coordinator.text(reason),
           worktree
         )}
    end
  end
end
