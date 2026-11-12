defmodule Helyx.Tool.SessionSend do
  @moduledoc """
  The coordinator tool `session_send`: sends a text to a session that the
  user of the calling session owns, as a prompt, a steer, or a follow-up
  (`Helyx.Session.prompt/3`, `steer/3`, `follow_up/3`), after the check of
  the wire (`Helyx.Hub.authorize/4`). A session that its idle stop unloaded
  loads first through `Helyx.Hub.resume/3`, so it takes the place of the
  user and binds the starter (`docs/features/idle-unload.md`). The text has
  the bound of any prompt, `Helyx.Session.max_text_bytes/0`. See
  `docs/features/coordinator.md`.
  """

  @behaviour Helyx.Tool

  alias Helyx.{Coordinator, Session}
  alias Helyx.Tool.Args

  @dispositions ~w(prompt steer follow_up)

  @impl true
  def name, do: "session_send"

  @impl true
  def concurrent?, do: true

  @impl true
  def description do
    "Send a text to a session. prompt starts a turn when none runs; steer goes into the " <>
      "running turn; follow_up runs as its own turn after the running one."
  end

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "id" => %{"type" => "string", "description" => "The id of the session"},
        "text" => %{
          "type" => "string",
          "maxLength" => Session.max_text_bytes(),
          "description" => "The text to send"
        },
        "disposition" => %{
          "type" => "string",
          "enum" => @dispositions,
          "default" => "prompt",
          "description" => "prompt (the default), steer, or follow_up"
        }
      },
      "required" => ["id", "text"]
    }
  end

  @impl true
  def run(args, _cwd) do
    with {:ok, args} <- Args.check(args, parameters()),
         :ok <- checked(args["id"]),
         {:ok, env} <- Coordinator.setup() do
      send_text(env, args["id"], args["text"], args["disposition"])
    else
      {:error, text} -> {:error, "session_send: " <> text}
    end
  end

  defp checked(id) do
    if Coordinator.id?(id),
      do: :ok,
      else: {:error, "the id must be a session id"}
  end

  defp send_text(env, id, text, disposition) do
    params = %{"session" => id, "text" => text}

    with :ok <- Helyx.Hub.authorize(env.hub, env.user, disposition, params),
         {:ok, session} <- loaded(env, id) do
      sent(env, id, text, disposition, session)
    else
      {:error, reason} -> {:error, "session_send: " <> Coordinator.text(reason)}
    end
  end

  # The text to the loaded session; a stop in flight loads it once more
  # (`Helyx.Send`, docs/features/idle-unload.md).
  defp sent(env, id, text, disposition, session) do
    result =
      Helyx.Send.text(
        session,
        &deliver(disposition, &1, text, Coordinator.origin(env)),
        fn -> Helyx.Hub.resume(env.hub, env.user, id) end
      )

    case result do
      :ok -> {:ok, "sent to session #{id} as #{disposition}"}
      {:error, reason} -> {:error, "session_send: " <> Coordinator.text(reason)}
    end
  end

  # A session that its idle stop unloaded loads first, through the Hub, as a
  # wire client does: the place of the user's live sessions and the starter
  # (docs/features/idle-unload.md). The sender loads it again if it stops
  # while the text is in flight.
  defp loaded(env, id) do
    session = Coordinator.session(env, id)

    if Session.pid(session),
      do: {:ok, session},
      else: Helyx.Hub.resume(env.hub, env.user, id)
  end

  defp deliver("prompt", session, text, opts), do: Session.prompt(session, text, opts)
  defp deliver("steer", session, text, opts), do: Session.steer(session, text, opts)
  defp deliver("follow_up", session, text, opts), do: Session.follow_up(session, text, opts)
end
