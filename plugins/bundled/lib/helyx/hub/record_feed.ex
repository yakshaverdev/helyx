defmodule Helyx.Hub.RecordFeed do
  @moduledoc false
  # The records feed of a user (`docs/features/live-records.md`), in the state
  # of the Hub process.
  #
  # `records`: monitor ref => `%{pid, user, pending, dropped}`, one entry for
  # each records subscription of a connection. `pending` holds the ids of the
  # changes that wait for the process to drain, so many changes of one record
  # become one, the newest, and `dropped` says that the process passed the
  # bound and gets the full list at the next poll.
  #
  # `asks`: session id => the ids of its open asks, from the `:ask` and
  # `:ask_end` notices of the feed, and the seed of the session snapshots.
  # `ask_epoch`: session id => the number of the last ask notice of it, so a
  # seed replaces a set only when no notice came while it ran.

  alias Helyx.Hub.{Live, Records}
  alias Helyx.Transport.WebSocket.Bounds

  # The rows of the first reply, the waiting changes of one subscriber, and
  # the subscriptions of a Hub (live-records.md, "Bounds").
  def page, do: Bounds.get("record_page")
  def max_pending, do: Bounds.get("record_pending")
  def max_subscribers, do: Bounds.get("record_subscribers")

  def init(state), do: Map.merge(state, %{records: %{}, asks: %{}, ask_epoch: %{}})

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

  # The first reply or a full list: the records of the user, waiting first,
  # then by activity time, newest first, then by id. `more` is true when the
  # user owns more than the page, and a live record of the user is in the page
  # whatever its age.
  def list(state, user) do
    %{store: mod, db: db} = state

    with {:ok, newest} <- mod.owned(db, user, page() + 1),
         {:ok, live} <- mod.rows(db, Live.ids(state)) do
      rows =
        (newest ++ live)
        |> Enum.uniq_by(& &1.session_id)
        |> Enum.filter(&(&1.owner == user))
        |> order(state)

      with {:ok, views} <- Records.views(Enum.take(rows, page()), user, state) do
        {:ok, Enum.map(views, &Records.wire/1), length(rows) > page()}
      end
    end
  end

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

  # A change of a record that has a row. A user owns its rows only, so a
  # record of another user reaches none of its clients.
  def changed(%{records: records} = state, _session_id, _kind) when map_size(records) == 0,
    do: state

  def changed(state, session_id, kind) do
    case state.store.record(state.db, session_id) do
      {:ok, row} ->
        case Records.view(row, row.owner, state) do
          {:ok, view} -> send_row(state, row.owner, change(kind, view))
          _failed -> state
        end

      _missing_or_failed ->
        state
    end
  end

  # A start of a user who is not the default owner moves the owner of the row
  # that the feed may have written: the new owner gets the record, every other
  # user gets its removal, which a client that never held it drops.
  def moved(%{records: records} = state, _session_id) when map_size(records) == 0, do: state

  def moved(state, session_id) do
    with {:ok, row} <- state.store.record(state.db, session_id),
         {:ok, view} <- Records.view(row, row.owner, state) do
      changed = change("changed", view)
      removed = change("removed", session_id)

      Enum.reduce(state.records, state, fn {ref, sub}, state ->
        send_change(state, ref, session_id, moved_change(sub, row, changed, removed))
      end)
    else
      _missing_or_failed -> state
    end
  end

  defp moved_change(sub, row, changed, removed),
    do: if(sub.user == row.owner, do: changed, else: removed)

  # A record that is gone: every client drops it, one that never held it too.
  def removed(%{records: records} = state, _session_id) when map_size(records) == 0, do: state

  def removed(state, session_id) do
    Enum.reduce(state.records, state, fn {ref, _sub}, state ->
      send_change(state, ref, session_id, change("removed", session_id))
    end)
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
        state
    end
  end

  # -- The open asks ---------------------------------------------------------

  def ask(state, session_id, ask_id) do
    set = state.asks |> Map.get(session_id, MapSet.new()) |> MapSet.put(ask_id)

    %{
      state
      | asks: Map.put(state.asks, session_id, set),
        ask_epoch: bump(state.ask_epoch, session_id)
    }
  end

  def ask_end(state, session_id, ask_id) do
    set = Map.get(state.asks, session_id, MapSet.new()) |> MapSet.delete(ask_id)

    state = %{
      state
      | asks: put_set(state.asks, session_id, set),
        ask_epoch: bump(state.ask_epoch, session_id)
    }

    state
  end

  # The `:DOWN` of a session: its asks end with it.
  def clear_asks(state, session_id) do
    %{
      state
      | asks: Map.delete(state.asks, session_id),
        ask_epoch: Map.delete(state.ask_epoch, session_id)
    }
  end

  # The ask notices that Hub has seen, for the guard of a seed.
  def epochs(state), do: state.ask_epoch

  # `seeds`: `{session id, [ask id]}` for each live session of a snapshot.
  # A set whose session had a notice while the seed ran keeps the notices.
  def seed(state, epochs, seeds) do
    Enum.reduce(seeds, state, fn {session_id, ask_ids}, state ->
      if Map.get(epochs, session_id, 0) == Map.get(state.ask_epoch, session_id, 0) do
        %{state | asks: put_set(state.asks, session_id, MapSet.new(ask_ids))}
      else
        state
      end
    end)
  end

  # Drops the sets and epochs of sessions that no longer run, after a seed
  # and the live set that it read: a notice that the feed dropped leaves no
  # state behind (`docs/features/live-records.md`, "Bounds").
  def prune(state) do
    live = MapSet.new(Live.ids(state))
    keep = fn {session_id, _value} -> MapSet.member?(live, session_id) end

    %{state | asks: Map.filter(state.asks, keep), ask_epoch: Map.filter(state.ask_epoch, keep)}
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
        {:cont, flush_change(state, sub, session_id)}
    end
  end

  defp flush_change(state, sub, session_id) do
    case current(state, session_id, sub.user) do
      nil ->
        state

      change ->
        send(sub.pid, {:record_change, change})
        state
    end
  end

  # The newest value of a record for a subscriber: its record, or its removal
  # when it is gone or no longer the user's.
  defp current(state, session_id, user) do
    case state.store.record(state.db, session_id) do
      {:ok, %{owner: ^user} = row} ->
        case Records.view(row, user, state) do
          {:ok, view} -> change("changed", view)
          _failed -> nil
        end

      _gone_or_moved ->
        change("removed", session_id)
    end
  end

  defp change("removed", session_id), do: %{"kind" => "removed", "session" => session_id}
  defp change(kind, view), do: %{"kind" => kind, "record" => Records.wire(view)}

  defp send_row(state, user, change) do
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

  defp bump(epochs, session_id), do: Map.update(epochs, session_id, 1, &(&1 + 1))
end
