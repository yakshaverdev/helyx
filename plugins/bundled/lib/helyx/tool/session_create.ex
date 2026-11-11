defmodule Helyx.Tool.SessionCreate do
  @moduledoc """
  The coordinator tool `session_create`: starts an independent session
  that Hub owns, for the user of the calling session, in a folder with a
  mode of the product, and sends it a first prompt. The session is not a
  child: it has no parent link and outlives the call. The start goes
  through `Helyx.Hub.start_session/3`, so the caps of the user hold. See
  `docs/features/coordinator.md`.
  """

  @behaviour Helyx.Tool

  alias Helyx.{Coordinator, Session}
  alias Helyx.Tool.Args

  @impl true
  def name, do: "session_create"

  @impl true
  def concurrent?, do: true

  @impl true
  def description do
    "Start a new session in a folder with a mode, and send it a first prompt. " <>
      "The session runs on its own after this call; use session_wait and session_read " <>
      "to follow it. Returns the id of the session."
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
        }
      },
      "required" => ["mode", "folder", "prompt"]
    }
  end

  @impl true
  def run(args, _cwd) do
    with {:ok, args} <- Args.check(args, parameters()),
         :ok <- folder(args["folder"]),
         {:ok, env} <- Coordinator.setup(),
         {:ok, mode_opts} <- Coordinator.mode(args["mode"]),
         {:ok, session} <- start(env, args["folder"], mode_opts) do
      sent(
        env,
        session,
        args["prompt"],
        "session #{session.id} started in #{args["folder"]} with the mode #{args["mode"]}"
      )
    else
      {:error, text} -> {:error, "session_create: " <> text}
    end
  end

  # A folder that the model gives: an absolute path of a folder that exists.
  defp folder(folder) do
    if Path.type(folder) == :absolute and File.dir?(folder),
      do: :ok,
      else: {:error, "the folder must be the absolute path of a folder that exists"}
  end

  # The model of the mode, else the model of the calling turn.
  defp start(env, folder, mode_opts) do
    opts = [
      cwd: folder,
      model: mode_opts[:model] || env.context.model,
      model_context: mode_opts[:model_context],
      tools: mode_opts[:tools]
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

  defp sent(_env, _session, "", started), do: {:ok, started <> "."}

  # The prompt takes the check of the wire, which moves the record.
  defp sent(env, session, prompt, started) do
    params = %{"session" => session.id, "text" => prompt}

    with :ok <- Helyx.Hub.authorize(env.hub, env.user, "prompt", params),
         :ok <- Session.prompt(session, prompt, Coordinator.origin(env)) do
      {:ok, started <> ", and it got the prompt."}
    else
      # A session that got no prompt takes no place of the cap.
      {:error, reason} ->
        _ = Helyx.Sessions.stop(session)

        {:error,
         "session_create: the prompt was not sent, so the session #{session.id} " <>
           "was stopped: " <>
           Coordinator.text(reason)}
    end
  end
end
