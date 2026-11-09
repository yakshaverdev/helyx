defmodule Helyx.Tool.SessionWait do
  @moduledoc """
  The coordinator tool `session_wait`: waits for the first turn end or
  session end among running sessions that the user of the calling session
  may read, each after the check of the wire `subscribe`
  (`Helyx.Hub.authorize/4`). A session with no running turn counts as
  ended at once. The `deadline` of the call, not Core, bounds the wait;
  past it the result is an error that tells the model to wait again. See
  `docs/features/coordinator.md` for the bounds.
  """

  @behaviour Helyx.Tool

  alias Helyx.{Coordinator, Event, Session}

  # The ids of one wait, the Core cap of live sessions.
  @max_ids 64
  # The wait in seconds: the default, and the most (decision 6).
  @default_s 300
  @max_s 3_600

  @impl true
  def name, do: "session_wait"

  @impl true
  def concurrent?, do: true

  @impl true
  def description do
    "Wait until one of the sessions ends its turn or ends, and say which one and how. " <>
      "A session with no running turn answers at once. Past the deadline, call it again " <>
      "to wait more."
  end

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "ids" => %{
          "type" => "array",
          "items" => %{"type" => "string"},
          "description" => "The ids of the sessions, 1 to #{@max_ids}"
        },
        "deadline" => %{
          "type" => "integer",
          "description" =>
            "The most seconds to wait, 1 to #{@max_s}; the default is #{@default_s}"
        }
      },
      "required" => ["ids"]
    }
  end

  @impl true
  def run(%{"ids" => ids} = args, _cwd) do
    seconds = Map.get(args, "deadline", @default_s)

    with :ok <- checked(ids, seconds),
         {:ok, env} <- Coordinator.setup() do
      until = System.monotonic_time(:millisecond) + seconds * 1_000
      subscribed(env, Enum.uniq(ids), seconds, until)
    else
      {:error, text} -> {:error, "session_wait: " <> text}
    end
  end

  def run(_args, _cwd), do: {:error, "session_wait needs ids, a list of session ids"}

  defp checked(ids, seconds) do
    cond do
      not is_list(ids) or ids == [] or length(ids) > @max_ids ->
        {:error, "ids must be a list of 1 to #{@max_ids} session ids"}

      not Enum.all?(ids, &Coordinator.id?/1) ->
        {:error, "each id must be a session id"}

      not (is_integer(seconds) and seconds in 1..@max_s) ->
        {:error, "the deadline must be a whole number of seconds from 1 to #{@max_s}"}

      true ->
        :ok
    end
  end

  # Each session in turn: the check, then a subscription whose snapshot
  # tells whether a turn runs. The subscriptions end with the Task of the
  # call.
  defp subscribed(env, ids, seconds, until) do
    result =
      Enum.reduce_while(ids, {:ok, %{}}, fn id, {:ok, refs} ->
        case subscribe(env, id) do
          {:ok, ref} -> {:cont, {:ok, Map.put(refs, ref, id)}}
          {:done, text} -> {:halt, {:done, text}}
          {:error, text} -> {:halt, {:error, text}}
        end
      end)

    case result do
      {:ok, refs} -> await(env, refs, seconds, until)
      {:done, text} -> {:ok, text}
      {:error, text} -> {:error, "session_wait: " <> text}
    end
  end

  # A tail of one message keeps the snapshot small.
  defp subscribe(env, id) do
    session = Coordinator.session(env, id)

    with :ok <- Helyx.Hub.authorize(env.hub, env.user, "subscribe", %{"session" => id}),
         {:ok, snapshot, ref} <- Session.subscribe(session, tail: 1) do
      if snapshot.turn, do: {:ok, ref}, else: {:done, "session #{id}: no turn runs"}
    else
      {:error, reason} -> {:error, "session #{id}: " <> Coordinator.text(reason)}
    end
  end

  # Every event is acked, so no session ends the subscription as slow.
  # The Task of the call subscribes only to these sessions, so each event
  # is of one of them. A stream of events with no gap never fires `after`,
  # so each event checks the deadline too.
  defp await(env, refs, seconds, until) do
    receive do
      {:helyx_event, %Event{session_id: id} = event} ->
        :ok = Session.ack(Coordinator.session(env, id), event)

        cond do
          ended(event) -> ended(event)
          System.monotonic_time(:millisecond) >= until -> late(seconds)
          true -> await(env, refs, seconds, until)
        end

      {:DOWN, ref, :process, _pid, reason} when is_map_key(refs, ref) ->
        {:ok, "session #{refs[ref]} ended (#{Session.end_reason(reason)})"}

      {:helyx_end, ref, :slow} when is_map_key(refs, ref) ->
        {:error, "session_wait: the events of session #{refs[ref]} were not read in time"}
    after
      max(until - System.monotonic_time(:millisecond), 0) -> late(seconds)
    end
  end

  defp late(seconds),
    do:
      {:error,
       "session_wait: no session ended its turn within #{seconds} s; " <>
         "call session_wait again to wait more"}

  defp ended(%Event{type: :turn_end, session_id: id, data: %{outcome: :error, error: error}}),
    do: {:ok, "session #{id}: the turn failed: #{error}"}

  defp ended(%Event{type: :turn_end, session_id: id, data: %{outcome: outcome}}),
    do: {:ok, "session #{id}: the turn ended (#{outcome})"}

  defp ended(_event), do: nil
end
