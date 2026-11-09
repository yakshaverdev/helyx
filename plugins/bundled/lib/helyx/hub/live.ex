defmodule Helyx.Hub.Live do
  @moduledoc false
  # The live set and the reserved places of a Hub (`docs/features/hub.md`,
  # decision 14), in the state of the Hub process.
  #
  # `live`: monitor ref => session id, the session processes that a start or
  # resume through Hub made or attached to, and every live session of the
  # Core at the start of Hub. `reserved`: caller pid => place, a start or a
  # resume that `check` passed and whose `result` has not come, with a
  # monitor of the caller and a timer. A place ends at `result` (which adds
  # the session to the live set), at `release`, at the `:DOWN` of its
  # caller, or @place_ms after its `check`. `starters`: session id => the
  # user whose start or resume through Hub made or attached to the entry of
  # the session; the coordinator tools act for that user only
  # (`docs/features/coordinator.md`, decision 3). A seeded entry has none.

  alias Helyx.Hub.Rules

  # The life of a reserved place (Bounds).
  @place_ms 60_000

  def init(state), do: Map.merge(state, %{live: %{}, reserved: %{}, starters: %{}})

  # The sessions of the Core when Hub starts, `{session id, pid}`, read by a
  # process of `Helyx.Hub.Server` before the Hub takes any call.
  def seed(state, sessions),
    do: Enum.reduce(sessions, state, fn {id, pid}, s -> watch(s, id, pid) end)

  # A place for `caller` of `user`: a place among the live sessions of the
  # user, and for a start of a user who is not the default owner, a place
  # among its records too. A caller holds one place at a time.
  def reserve(state, user, caller, record?) do
    state = release(state, caller)
    places = for {_caller, %{user: ^user} = place} <- state.reserved, do: place

    with :ok <- room(state, user, places),
         :ok <- record_room(state, user, places, record?) do
      monitor = Process.monitor(caller)
      timer = Process.send_after(self(), {:place_expired, caller, monitor}, @place_ms)
      place = %{user: user, record?: record?, monitor: monitor, timer: timer}
      {:ok, %{state | reserved: Map.put(state.reserved, caller, place)}}
    end
  end

  defp room(state, user, places) do
    with {:ok, live} <- live_of(state, user) do
      if live + length(places) < state.max_live, do: :ok, else: {:error, :too_many_sessions}
    end
  end

  defp record_room(_state, _user, _places, false), do: :ok

  defp record_room(%{store: mod, db: db}, user, places, true) do
    with {:ok, n} <- mod.count_records(db, user) do
      if n + Enum.count(places, & &1.record?) < Rules.max_records(),
        do: :ok,
        else: {:error, :too_many_records}
    end
  end

  # The entries of the live set whose record, stored or derived, names the
  # user as owner: one query for the ids of the set, at most 64.
  defp live_of(%{live: live, store: mod, db: db} = state, user) do
    ids = Map.values(live)

    with {:ok, rows} <- mod.records(db, ids) do
      {:ok,
       Enum.count(ids, fn id ->
         Map.get(rows, id, %{owner: state.default_owner_id}).owner == user
       end)}
    end
  end

  # The `result` of a start or a resume: the place of the caller ends and
  # the session enters the live set.
  def started(state, caller, session_id, pid, user) when is_pid(pid) do
    state = state |> release(caller) |> watch(session_id, pid)
    %{state | starters: Map.put(state.starters, session_id, user)}
  end

  def started(state, caller, _session_id, nil, _user), do: release(state, caller)

  # The user of the start or resume through Hub of the running entry of a
  # session, or nil.
  def starter(state, session_id), do: Map.get(state.starters, session_id)

  def release(state, caller) do
    case Map.pop(state.reserved, caller) do
      {nil, _reserved} ->
        state

      {place, reserved} ->
        Process.demonitor(place.monitor, [:flush])
        Process.cancel_timer(place.timer)
        %{state | reserved: reserved}
    end
  end

  def running?(%{live: live}, session_id), do: session_id in Map.values(live)

  # A `:DOWN` of a session of the live set or of the caller of a place.
  def down(state, ref, pid) do
    case Map.pop(state.live, ref) do
      {nil, _live} -> expired(state, pid, ref)
      {id, live} -> %{state | live: live, starters: Map.delete(state.starters, id)}
    end
  end

  # The end of the place of `caller` whose monitor is `monitor`; the timer
  # or `:DOWN` of a place that ended before it changes nothing.
  def expired(state, caller, monitor) do
    case state.reserved do
      %{^caller => %{monitor: ^monitor}} -> release(state, caller)
      _ -> state
    end
  end

  # One entry for each session: a new process of the session replaces the
  # entry of an old one whose `:DOWN` has not come yet.
  # A new entry has no starter until `started/5` gives one.
  defp watch(state, session_id, pid) do
    {old, live} = Map.split_with(state.live, fn {_ref, id} -> id == session_id end)
    Enum.each(Map.keys(old), &Process.demonitor(&1, [:flush]))

    %{
      state
      | live: Map.put(live, Process.monitor(pid), session_id),
        starters: Map.delete(state.starters, session_id)
    }
  end
end
