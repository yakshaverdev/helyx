defmodule Helyx.Hub.RecordFeed do
  @moduledoc false
  # The records feed of a user (`docs/features/live-records.md`), in the state
  # of the Hub process.
  #
  # `records`: monitor ref => `%{pid, user, pending, dropped}`, one entry for
  # each records subscription of a connection. `pending` holds the ids of the
  # changes that wait for the process to drain, so many changes of one record
  # become one, the newest, and `dropped` says that the process passed the
  # bound, or a store read failed, and gets the full list at the next poll.
  #
  # `silent`: the session ids whose first record row was written while a start
  # of another user was in flight, so no client of the default owner was told
  # of it. Its removal goes to no client of that owner (`docs/features/
  # live-records.md`, "A start of another user").
  #
  # `asks`: session id => the ids of its open asks, from the `:ask` and
  # `:ask_end` notices of the feed, and the seed of the session snapshots.

  alias Helyx.Hub.{Live, Records}
  alias Helyx.Transport.WebSocket.Bounds

  # The rows of the first reply, the live records beside them, the waiting
  # changes of one subscriber, and the subscriptions of a Hub
  # (live-records.md, "Bounds").
  def page, do: Bounds.get("record_page")
  def max_live, do: Bounds.get("record_live")
  def max_pending, do: Bounds.get("record_pending")
  def max_subscribers, do: Bounds.get("record_subscribers")

  @doc "The most records of one reply: the page and the live records beside it."
  def max_reply, do: page() + max_live()

  def init(state), do: Map.merge(state, %{records: %{}, asks: %{}, silent: MapSet.new()})

  # One subscriber, with a monitor of its process. At most the 64 connections
  # of the transport, one records subscription each.
  def subscribe(state, user, pid) when is_pid(pid) do
    if map_size(state.records) < max_subscribers() do
      ref = Process.monitor(pid)
      sub = %{pid: pid, user: user, pending: %{}, dropped: false}
      {:ok, %{state | records: Map.put(state.records, ref, sub)}}
    else
      {:error, :busy}
    end
  end

  def down(state, ref), do: %{state | records: Map.delete(state.records, ref)}

  # The first reply or a full list: the page of the order, and every live
  # record of the user that the page cuts, so a live record is never left out.
  # `more` is true when the user owns more than the page. The reply holds at
  # most `max_reply/0` records.
  #
  # A row is visible to the user when the store names the user as its owner and
  # no start of another user is in flight for it (`silent`). The live frames and
  # every full list ask the same rule here, so a silent row is in no list.
  def list(state, user) do
    %{store: mod, db: db} = state

    # The silent rows are skipped, so read that many more of the page.
    taken = page() + 1 + MapSet.size(state.silent)

    with {:ok, newest} <- mod.owned(db, user, taken),
         {:ok, live} <- mod.rows(db, Live.ids(state)) do
      newest = Enum.reject(newest, &silent?(state, &1))

      live_rows =
        live
        |> Enum.filter(&(&1.owner == user and not silent?(state, &1)))
        |> Enum.uniq_by(& &1.session_id)

      live_ids = MapSet.new(live_rows, & &1.session_id)

      rows =
        (newest ++ live_rows)
        |> Enum.uniq_by(& &1.session_id)
        |> order(state)

      {prefix, _rest} = Enum.split(rows, page())
      prefix_ids = MapSet.new(prefix, & &1.session_id)

      extras =
        Enum.filter(rows, fn row ->
          MapSet.member?(live_ids, row.session_id) and
            not MapSet.member?(prefix_ids, row.session_id)
        end)

      with {:ok, views} <- Records.views(prefix ++ extras, user, state) do
        {:ok, Enum.map(views, &Records.wire/1), length(newest) > page()}
      end
    end
  end

  defp silent?(state, row), do: MapSet.member?(state.silent, row.session_id)

  # Waiting first, then `active_at` newest first, then the session id.
  defp order(rows, state) do
    Enum.sort_by(rows, fn row ->
      {Live.status(state, row.session_id) != "waiting", -row.active_at, row.session_id}
    end)
  end

  # Whether a session has a row now, for the kind of its change (`:unknown`
  # with no subscriber, which needs no kind).
  def row?(%{records: records}, _session_id) when map_size(records) == 0, do: :unknown

  def row?(state, session_id) do
    case state.store.record(state.db, session_id) do
      {:ok, _row} -> :present
      _missing_or_failed -> :absent
    end
  end

  # The owner of a record now, or nil when it has none or no subscriber of the
  # feed needs the answer.
  def owner(%{records: records}, _session_id) when map_size(records) == 0, do: nil

  def owner(state, session_id) do
    case state.store.record(state.db, session_id) do
      {:ok, row} -> row.owner
      _missing_or_failed -> nil
    end
  end

  # A row whose first notice goes to no client: a `Live` of a session with no
  # row, while a start of another user is in flight.
  def silent(%{records: records} = state, _session_id) when map_size(records) == 0, do: state

  def silent(state, session_id), do: %{state | silent: MapSet.put(state.silent, session_id)}

  # The session ended: its silent mark and its change wait for no one.
  def forget(state, session_id), do: %{state | silent: MapSet.delete(state.silent, session_id)}

  # A change of a record that has a row. A user owns its rows only, so a
  # record of another user reaches none of its clients. A failed read marks
  # every subscriber, and the next poll sends the full list.
  def changed(%{records: records} = state, _session_id, _kind) when map_size(records) == 0,
    do: state

  def changed(state, session_id, kind) do
    case state.store.record(state.db, session_id) do
      {:ok, row} ->
        case Records.view(row, row.owner, state) do
          {:ok, view} -> send_row(state, row.owner, change(kind, view))
          _failed -> failed(state)
        end

      {:error, :not_found} ->
        state

      _failed ->
        failed(state)
    end
  end

  # A start of a user who is not the default owner moves the owner of the row
  # that the feed may have written: the new owner gets the record, and the
  # owner before it gets the removal, unless that row was silent. No other
  # user is told of the id.
  def moved(%{records: records} = state, _session_id, _prior_owner) when map_size(records) == 0,
    do: state

  def moved(state, session_id, prior_owner) do
    with {:ok, row} <- state.store.record(state.db, session_id),
         {:ok, view} <- Records.view(row, row.owner, state) do
      moved_change(state, row, change("changed", view), prior_owner)
    else
      _missing_or_failed -> failed(state)
    end
  end

  defp moved_change(state, row, changed, prior_owner) do
    if MapSet.member?(state.silent, row.session_id) do
      state |> forget(row.session_id) |> send_row(row.owner, changed)
    else
      state = send_row(state, row.owner, changed)

      if prior_owner != nil and prior_owner != row.owner,
        do: send_row(state, prior_owner, change("removed", row.session_id)),
        else: state
    end
  end

  # A record that is gone: the subscribers of the owner that it had drop it.
  # A client that never held it is not told of the id.
  def removed(%{records: records} = state, _session_id, _owner) when map_size(records) == 0,
    do: state

  def removed(state, session_id, owner) do
    silent? = MapSet.member?(state.silent, session_id)
    state = forget(state, session_id)

    if owner != nil and not silent?,
      do: send_row(state, owner, change("removed", session_id)),
      else: state
  end

  # A new list for the subscribers of `user`, after a scan wrote rows that a
  # client was not told of one by one.
  def refresh(%{records: records} = state, _user) when map_size(records) == 0, do: state

  def refresh(state, user) do
    case list(state, user) do
      {:ok, views, more} ->
        Enum.reduce(state.records, state, fn
          {ref, %{user: ^user}}, state -> send_full(state, ref, views, more)
          {_ref, _other}, state -> state
        end)

      _failed ->
        failed_for(state, user)
    end
  end

  # A store read failed: every subscriber gets the full list at the next poll,
  # so no change is lost.
  def failed(state) do
    Enum.reduce(state.records, state, fn {ref, _sub}, state -> drop(state, ref) end)
  end

  defp failed_for(state, user) do
    Enum.reduce(state.records, state, fn
      {ref, %{user: ^user}}, state -> drop(state, ref)
      {_ref, _other}, state -> state
    end)
  end

  # -- The open asks ---------------------------------------------------------

  def ask(state, session_id, ask_id) do
    set = state.asks |> Map.get(session_id, MapSet.new()) |> MapSet.put(ask_id)
    %{state | asks: Map.put(state.asks, session_id, set)}
  end

  def ask_end(state, session_id, ask_id) do
    set = Map.get(state.asks, session_id, MapSet.new()) |> MapSet.delete(ask_id)
    %{state | asks: put_set(state.asks, session_id, set)}
  end

  # The `:DOWN` of a session: its asks end with it.
  def clear_asks(state, session_id), do: %{state | asks: Map.delete(state.asks, session_id)}

  # `seeds`: `{session id, {:ok, [ask id]}}` for each live session of a
  # snapshot, or `:error` for a session whose snapshot read failed and keeps
  # its old set. A notice that waits in the mailbox is applied after the seed,
  # and an add or a remove of an id is idempotent.
  def seed(state, seeds) do
    Enum.reduce(seeds, state, fn
      {_session_id, :error}, state ->
        state

      {session_id, {:ok, ask_ids}}, state ->
        %{state | asks: put_set(state.asks, session_id, MapSet.new(ask_ids))}
    end)
  end

  # Drops the sets of sessions that no longer run, after a seed and the live
  # set that it read: a notice that the feed dropped leaves no state behind
  # (`docs/features/live-records.md`, "Bounds").
  def prune(state) do
    live = MapSet.new(Live.ids(state))

    %{
      state
      | asks:
          Map.filter(state.asks, fn {session_id, _set} -> MapSet.member?(live, session_id) end)
    }
  end

  # The poll of the Hub: a subscriber that passed the bound gets the full
  # list, and the changes that wait for a drained subscriber go, one for each
  # record, with the newest value.
  def repaired(state) do
    Enum.reduce(state.records, state, fn {ref, sub}, state ->
      cond do
        sub.dropped -> resend_full(state, ref)
        map_size(sub.pending) > 0 -> flush(state, ref)
        true -> state
      end
    end)
  end

  defp resend_full(state, ref) do
    sub = Map.fetch!(state.records, ref)

    case list(state, sub.user) do
      {:ok, views, more} -> send_full(state, ref, views, more)
      _failed -> state
    end
  end

  defp flush(state, ref) do
    sub = Map.fetch!(state.records, ref)

    Enum.reduce_while(Map.keys(sub.pending), state, fn session_id, state ->
      flush_one(state, ref, session_id)
    end)
  end

  defp flush_one(state, ref, session_id) do
    sub = Map.fetch!(state.records, ref)

    cond do
      not Map.has_key?(sub.pending, session_id) ->
        {:cont, state}

      mailbox(sub.pid) >= max_pending() ->
        {:halt, drop(state, ref)}

      true ->
        state = put_sub(state, ref, %{sub | pending: Map.delete(sub.pending, session_id)})
        {:cont, flush_change(state, ref, sub, session_id)}
    end
  end

  defp flush_change(state, ref, sub, session_id) do
    case current(state, session_id, sub.user) do
      {:ok, change} ->
        send(sub.pid, {:record_change, change})
        state

      :error ->
        drop(state, ref)
    end
  end

  # The newest value of a record for a subscriber: its record, or its removal
  # when it is gone or no longer the user's.
  defp current(state, session_id, user) do
    case state.store.record(state.db, session_id) do
      {:ok, %{owner: ^user} = row} ->
        case Records.view(row, user, state) do
          {:ok, view} -> {:ok, change("changed", view)}
          _failed -> :error
        end

      {:ok, _other} ->
        {:ok, change("removed", session_id)}

      {:error, :not_found} ->
        {:ok, change("removed", session_id)}

      _failed ->
        :error
    end
  end

  defp change("removed", session_id), do: %{"kind" => "removed", "session" => session_id}
  defp change(kind, view), do: %{"kind" => kind, "record" => Records.wire(view)}

  defp send_row(state, user, change) do
    state = forget(state, change_id(change))

    Enum.reduce(state.records, state, fn
      {ref, %{user: ^user}}, state -> send_change(state, ref, change_id(change), change)
      {_ref, _other}, state -> state
    end)
  end

  defp change_id(%{"record" => %{"session" => session_id}}), do: session_id
  defp change_id(%{"session" => session_id}), do: session_id

  # A change goes at once when the process drained, waits as one id when
  # another message waits, and is dropped for the full list when the process
  # passed the bound.
  defp send_change(state, ref, session_id, change) do
    sub = Map.fetch!(state.records, ref)

    cond do
      sub.dropped ->
        state

      Map.has_key?(sub.pending, session_id) ->
        state

      mailbox(sub.pid) >= max_pending() or map_size(sub.pending) >= max_pending() ->
        drop(state, ref)

      mailbox(sub.pid) > 0 ->
        put_sub(state, ref, %{sub | pending: Map.put(sub.pending, session_id, true)})

      true ->
        send(sub.pid, {:record_change, change})
        state
    end
  end

  defp send_full(state, ref, views, more) do
    sub = Map.fetch!(state.records, ref)

    if mailbox(sub.pid) >= max_pending() do
      drop(state, ref)
    else
      send(sub.pid, {:records_full, views, more})
      put_sub(state, ref, %{sub | dropped: false, pending: %{}})
    end
  end

  defp drop(state, ref) do
    sub = Map.fetch!(state.records, ref)
    put_sub(state, ref, %{sub | dropped: true, pending: %{}})
  end

  @spec put_sub(map(), reference(), map()) :: map()
  defp put_sub(state, ref, sub), do: %{state | records: Map.put(state.records, ref, sub)}

  defp mailbox(pid) do
    case Process.info(pid, :message_queue_len) do
      {:message_queue_len, n} -> n
      nil -> max_pending()
    end
  end

  defp put_set(sets, session_id, set) do
    if MapSet.size(set) == 0,
      do: Map.delete(sets, session_id),
      else: Map.put(sets, session_id, set)
  end
end
