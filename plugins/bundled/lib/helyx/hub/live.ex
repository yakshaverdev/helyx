defmodule Helyx.Hub.Live do
  @moduledoc false
  # The live set and the reserved places of a Hub (`docs/features/hub.md`,
  # decision 14), in the state of the Hub process.
  #
  # `live`: monitor ref => `{session id, pid, status}`, where `status` is the
  # `"idle"` or `"running"` of the last `Live` that the feed sent for that
  # process, or `"stopped"` for a session with no entry (`status/2`). It holds
  # every session of the Core: the feed sends one at the open of the process,
  # and the seed reads the sessions that ran before Hub started. `reserved`:
  # caller pid => place, with a monitor of the caller and a timer; a place
  # ends at `result`, at `release`, at the `:DOWN` of its caller, or
  # @place_ms after its `check`. `starters`: session id => the user whose
  # start or resume through Hub made or attached to the entry, for whom the
  # coordinator tools act (`docs/features/coordinator.md`, decision 3); a
  # seeded entry has none.

  alias Helyx.Hub.Rules

  # The life of a reserved place (Bounds).
  @place_ms 60_000

  def init(state), do: Map.merge(state, %{live: %{}, reserved: %{}, starters: %{}})

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

  # Whether a start of a user who is not the default owner is in flight: its
  # reserved place names no session id, so a `Live` of a session with no row
  # cannot be told from it (`docs/features/live-records.md`).
  def start_in_flight?(%{reserved: reserved}),
    do: Enum.any?(reserved, fn {_caller, place} -> place.record? end)

  defp record_room(_state, _user, _places, false), do: :ok

  defp record_room(%{store: mod, db: db}, user, places, true) do
    with {:ok, n} <- mod.count_records(db, user) do
      if n + Enum.count(places, & &1.record?) < Rules.max_records(),
        do: :ok,
        else: {:error, :too_many_records}
    end
  end

  # The entries of the live set whose record names the user as owner: one
  # query for the ids of the set, at most 64.
  defp live_of(%{live: live, store: mod, db: db} = state, user) do
    ids = for {_ref, {id, _pid, _status}} <- live, do: id

    with {:ok, rows} <- mod.records(db, ids) do
      {:ok,
       Enum.count(ids, fn id ->
         Map.get(rows, id, %{owner: state.default_owner_id}).owner == user
       end)}
    end
  end

  # The `result` of a start or a resume: the place of the caller ends and
  # the session enters the live set. A `Live` of the session may have come
  # first, so its status stays.
  def started(state, caller, session_id, pid, user) when is_pid(pid) do
    status = status_of(state, pid) || "idle"
    state = state |> release(caller) |> watch(session_id, pid, status)
    %{state | starters: Map.put(state.starters, session_id, user)}
  end

  def started(state, caller, _session_id, nil, _user), do: release(state, caller)

  # The status of the live entry of a process, or nil.
  defp status_of(%{live: live}, pid) do
    Enum.find_value(live, fn {_ref, {_id, entry, status}} ->
      if entry == pid, do: status
    end)
  end

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

  def running?(%{live: live}, session_id),
    do: Enum.any?(live, fn {_ref, {id, _pid, _status}} -> id == session_id end)

  # Every live session id, at most the 64 of the Core cap.
  def ids(%{live: live}), do: Enum.map(live, fn {_ref, {id, _pid, _status}} -> id end)

  # The session id of an entry of the live set, or nil.
  def watched(%{live: live}, ref) do
    case Map.fetch(live, ref) do
      {:ok, {id, _pid, _status}} -> id
      :error -> nil
    end
  end

  # The derived status of a session's record: `"waiting"` while it has an
  # open ask, else the status of its live entry, else `"stopped"`. Never
  # stored (hub.md, decision 8; live-records.md).
  def status(state, session_id) do
    if waiting?(state, session_id), do: "waiting", else: live_status(state, session_id)
  end

  defp live_status(%{live: live}, session_id) do
    Enum.find_value(live, "stopped", &entry_status(&1, session_id))
  end

  defp entry_status({_ref, {id, _pid, status}}, id), do: status
  defp entry_status(_entry, _id), do: nil

  defp waiting?(state, session_id) do
    case Map.get(state, :asks, %{}) do
      %{^session_id => set} -> MapSet.size(set) > 0
      _none -> false
    end
  end

  # A `:DOWN` of a session of the live set or of the caller of a place.
  def down(state, ref, pid) do
    case Map.pop(state.live, ref) do
      {nil, _live} ->
        expired(state, pid, ref)

      {{id, _pid, _status}, live} ->
        %{state | live: live, starters: Map.delete(state.starters, id)}
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

  # One entry for each session: a new process of a session replaces the entry
  # of an old one whose `:DOWN` has not come yet, and drops its starter. An
  # entry that already holds this pid takes the new status, so a status
  # change of the feed moves the record, and keeps the starter that
  # `started/5` gives it, also when the Live of its start came first.
  def watch(state, session_id, pid, status) do
    case live_ref(state.live, pid) do
      nil ->
        replace(state, session_id, pid, status)

      ref ->
        {id, ^pid, _old_status} = Map.fetch!(state.live, ref)
        %{state | live: Map.put(state.live, ref, {id, pid, status})}
    end
  end

  defp live_ref(live, pid) do
    Enum.find_value(live, fn {ref, {_id, entry, _status}} ->
      if entry == pid, do: ref
    end)
  end

  defp replace(state, session_id, pid, status) do
    {old, live} =
      Map.split_with(state.live, fn {_ref, {id, _pid, _status}} -> id == session_id end)

    Enum.each(Map.keys(old), &Process.demonitor(&1, [:flush]))

    %{
      state
      | live: Map.put(live, Process.monitor(pid), {session_id, pid, status}),
        starters: Map.delete(state.starters, session_id)
    }
  end
end
