defmodule Helyx.Coordinator do
  @moduledoc false
  # What the coordinator tools share (`docs/features/coordinator.md`): the
  # Hub of the Core of the call, the user of the calling session, the modes
  # of the product, the origin of a text that a tool sends, and the text of
  # an error for the model. A helper of `plugins/bundled`, not a plugin
  # (ADR 0005).

  alias Helyx.Session

  # The bound of an id that the model gives, the frame rule of an id on the
  # wire; a session id has 12 characters.
  @max_id_bytes 64
  @mode_keys [:model, :model_context, :tools]

  # The context of the call, its Hub, and the user of its session: the
  # user whose start or resume through Hub made the coordinator session,
  # while that user owns it (`Helyx.Hub.actor/2`, decision 3).
  def setup do
    context = Helyx.Tool.context()

    with {:ok, hub} <- hub(context.core),
         {:ok, user} <- owner(hub, context.session_id) do
      {:ok, %{context: context, hub: hub, user: user, core: context.core}}
    end
  end

  # The Hub of a Core: the application env `:coordinator_hubs` of
  # `helyx_plugins`, a map of a Core name to its Hub (decision 1).
  def hub(core) do
    case Application.get_env(:helyx_plugins, :coordinator_hubs, %{}) do
      %{^core => hub} when is_atom(hub) or is_pid(hub) -> {:ok, hub}
      %{^core => {:via, mod, _name} = hub} when is_atom(mod) -> {:ok, hub}
      _ -> {:error, "no Hub serves this server, so the coordinator tools cannot run"}
    end
  end

  defp owner(hub, session_id) do
    case Helyx.Hub.actor(hub, session_id) do
      {:ok, user} ->
        {:ok, user}

      {:error, :session_not_found} ->
        {:error, "this session acts for no user: start or resume it through the Hub"}

      {:error, reason} ->
        {:error, "the user of this session is not known: " <> text(reason)}
    end
  end

  # The options of a mode: the application env `:coordinator_modes`, a map
  # of a mode name to a keyword list of `:model`, `:model_context`, and
  # `:tools` (decision 2). Core checks the values at the start.
  def mode(name) do
    modes = Application.get_env(:helyx_plugins, :coordinator_modes, %{})

    case modes do
      %{^name => opts} ->
        if mode?(opts), do: {:ok, opts}, else: {:error, "the mode #{name} is not set up right"}

      %{} ->
        {:error, "no mode #{name}; the modes are: " <> Enum.join(mode_names(), ", ")}

      _ ->
        {:error, "the modes are not set up right"}
    end
  end

  # The names of the modes, sorted, for the error text and the system
  # prompt; none when the env is not a map.
  def mode_names do
    case Application.get_env(:helyx_plugins, :coordinator_modes, %{}) do
      %{} = modes -> modes |> Map.keys() |> Enum.filter(&is_binary/1) |> Enum.sort()
      _ -> []
    end
  end

  defp mode?(opts) do
    Keyword.keyword?(opts) and Keyword.keys(opts) -- @mode_keys == [] and
      text_or_nil?(opts[:model]) and is_atom(opts[:model_context]) and tools?(opts[:tools])
  end

  defp text_or_nil?(value), do: is_nil(value) or is_binary(value)
  defp tools?(tools), do: is_nil(tools) or (is_list(tools) and Enum.all?(tools, &is_binary/1))

  # A session id that the model gives: a string of 1 to 64 bytes.
  def id?(id), do: is_binary(id) and byte_size(id) in 1..@max_id_bytes

  def session(env, id), do: %Session{id: id, core: env.core}

  # The origin of a text that a tool sends: a product origin whose id the
  # coordinator session and the call id derive, unique per call
  # (`docs/features/message-identity.md`).
  def origin(env),
    do: [
      origin: %{
        kind: :product,
        id: Helyx.Sessions.child_id(env.context.session_id, env.context.call_id)
      }
    ]

  # The text of an error for the model.
  def text(:too_many_sessions),
    do: "you run as many sessions as you may; wait for one to end or stop one"

  def text(:too_many_records), do: "you hold as many session records as you may"

  def text(:session_not_found),
    do: "no such session runs, or you may not reach it; a session that stopped must be resumed"

  def text(:forbidden), do: "you may read this session but not write to it"
  def text(:unknown_user), do: "your user no longer exists"
  def text(:busy), do: "the Hub is busy; try again later"
  def text(:timeout), do: "the Hub did not answer in time; try again"
  def text(:failed), do: "the Hub failed"
  def text(:text_too_large), do: "the text is too large"
  def text(:invalid_utf8), do: "the text is not valid UTF-8"
  def text(:queue_full), do: "the queue of the session is full; wait for its turn to end"
  def text(:turn_running), do: "a turn runs; use steer or follow_up, or wait for its end"
  def text(:invalid_cwd), do: "the folder is not valid"
  def text(:too_many_schedules), do: "the session holds as many schedules as it may"

  def text(:too_many_event_subscriptions),
    do: "the session or you hold as many event subscriptions as you may"

  def text(:unknown_subscription), do: "no such event subscription of yours"
  def text(:bad_params), do: "a value is out of its range"
  def text(reason), do: Helyx.Reason.text(reason)
end
