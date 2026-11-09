defmodule Helyx.Tool.SessionSend do
  @moduledoc """
  The coordinator tool `session_send`: sends a text to a session that the
  user of the calling session owns, as a prompt, a steer, or a follow-up
  (`Helyx.Session.prompt/3`, `steer/3`, `follow_up/3`), after the check of
  the wire (`Helyx.Hub.authorize/4`). The text has the bound of any prompt,
  `Helyx.Session.max_text_bytes/0`. See `docs/features/coordinator.md`.
  """

  @behaviour Helyx.Tool

  alias Helyx.{Coordinator, Session}

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
        "text" => %{"type" => "string", "description" => "The text to send"},
        "disposition" => %{
          "type" => "string",
          "enum" => @dispositions,
          "description" => "prompt (the default), steer, or follow_up"
        }
      },
      "required" => ["id", "text"]
    }
  end

  @impl true
  def run(%{"id" => id, "text" => text} = args, _cwd) when is_binary(text) do
    disposition = Map.get(args, "disposition", "prompt")

    with :ok <- checked(id, text, disposition),
         {:ok, env} <- Coordinator.setup() do
      send_text(env, id, text, disposition)
    else
      {:error, text} -> {:error, "session_send: " <> text}
    end
  end

  def run(_args, _cwd), do: {:error, "session_send needs an id and a text, both strings"}

  defp checked(id, text, disposition) do
    cond do
      not Coordinator.id?(id) ->
        {:error, "the id must be a session id"}

      disposition not in @dispositions ->
        {:error, "the disposition must be prompt, steer, or follow_up"}

      # The bound of any prompt, before the check moves the record.
      byte_size(text) > Session.max_text_bytes() ->
        {:error, Coordinator.text(:text_too_large)}

      true ->
        :ok
    end
  end

  defp send_text(env, id, text, disposition) do
    session = Coordinator.session(env, id)
    params = %{"session" => id, "text" => text}

    with :ok <- Helyx.Hub.authorize(env.hub, env.user, disposition, params),
         :ok <- deliver(disposition, session, text, Coordinator.origin(env)) do
      {:ok, "sent to session #{id} as #{disposition}"}
    else
      {:error, reason} -> {:error, "session_send: " <> Coordinator.text(reason)}
    end
  end

  defp deliver("prompt", session, text, opts), do: Session.prompt(session, text, opts)
  defp deliver("steer", session, text, opts), do: Session.steer(session, text, opts)
  defp deliver("follow_up", session, text, opts), do: Session.follow_up(session, text, opts)
end
