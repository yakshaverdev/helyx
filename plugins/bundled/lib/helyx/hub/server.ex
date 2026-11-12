defmodule Helyx.Hub.Server do
  @moduledoc false
  # The process of a Hub: the only caller of the store, so a cap check and
  # its insert are one step (`docs/features/hub.md`, decision 9). Each
  # request is a Hub call of `Helyx.Hub.call/2` with its deadline.

  use GenServer

  alias Helyx.Hub.{
    Connections,
    Live,
    LiveRead,
    RecordFeed,
    Records,
    Rules,
    Schedules,
    Subscriptions,
    Wake,
    Webhook
  }

  # The deadline of the write of a row of the feed: a write that waits for
  # nobody, and one past this rolls back. The repair path writes the row
  # later (decision 8).
  @seen_ms 1_000

  # The caps of the operator API (Bounds).
  @max_users 64
  @max_tokens 16

  @impl true
  def init(config) do
    # The stop closes the store (decision 16).
    Process.flag(:trap_exit, true)

    # {:error, reason} ends the start with no exit signal to the caller.
    with {:ok, store} <- config.store.open(path: config.path) do
      case default_owner(config.store, store, config.default_owner) do
        {:ok, owner_id} ->
          # Before the seed: a session that starts during the list sends its
          # Live after this register. The ask notices give the open-ask sets
          # of the records feed (live-records.md).
          {:ok, dropped} = Helyx.Sessions.watch(config.core, [:ask, :ask_end])

          state =
            Map.merge(config, %{
              db: store,
              default_owner_id: owner_id,
              feed: dropped,
              feed_dropped: 0
            })

          {:ok,
           state
           |> Live.init()
           |> Connections.init()
           |> Wake.init()
           |> RecordFeed.init()
           |> LiveRead.init(), {:continue, :live}}

        {:error, _} = error ->
          config.store.close(store)
          error
      end
    end
  end

  defp default_owner(mod, store, name) do
    with {:ok, users} <- mod.users(store) do
      case Enum.find(users, &(&1.name == name)) do
        %{id: id} -> {:ok, id}
        nil -> insert_user(mod, store, name, :infinity)
      end
    end
  end

  defp insert_user(mod, store, name, deadline) do
    user = %{id: Schedules.new_id(), name: name, created_at: System.os_time(:second)}

    case mod.add_user(store, user, @max_users, deadline) do
      :ok -> {:ok, user.id}
      {:error, :name_taken} -> {:error, :invalid_name}
      {:error, _} = error -> error
    end
  end

  # Every live session of the Core enters the live set once, and its row, from
  # a read in a Task outside the Hub (`Helyx.Hub.LiveRead`; decision 14,
  # live-records.md). A read that fails or passes its bound leaves
  # `seed_pending`, and the next poll reads again: the start and the repair are
  # one mechanism.
  @impl true
  def handle_continue(:live, state) do
    # The first poll of the wake-ups comes at the start (decision 12), and it
    # starts the first read.
    {:noreply, poll(state)}
  end

  defp seen_all(state, sessions),
    do: Enum.reduce(sessions, state, fn {live, pid}, state -> seen(state, live, pid) end)

  # The periodic step of Hub: the read of the live sessions, the repair of a
  # records subscriber, then the poll of the wake-ups. It needs no timer of its
  # own, because the poll already runs each 1,000 ms (decision 12).
  defp poll(state), do: state |> LiveRead.maybe_read() |> RecordFeed.repaired() |> Wake.poll()

  # A read that took: its sessions enter the live set and tell the feed, and a
  # snapshot that failed keeps its old set for the next poll.
  defp read_applied(state, {:ok, sessions, seeds}) do
    state
    |> RecordFeed.seed(seeds)
    |> seen_all(sessions)
    |> RecordFeed.prune()
    |> RecordFeed.repaired()
  end

  defp read_applied(state, :error), do: state

  # The Live of the feed, and the row that it writes: the write waits for
  # nobody (decision 8). The live entry takes the status, which the record
  # derives and never stores. A write that took sends the change to the
  # records feed; a write that failed sends the full list at the next poll.
  #
  # A row of a session with no row is silent while a start of another user is
  # in flight: the place names no session, so the row cannot be told from that
  # start, and the default owner must not see the id of another user's start.
  # The start's `result` knows the owner and tells the feed then.
  defp seen(state, %Helyx.Sessions.Live{} = live, pid) do
    state = LiveRead.touched(state, live.id)
    existed? = RecordFeed.row?(state, live.id)
    in_flight? = Live.start_in_flight?(state)
    state = Live.watch(state, live.id, pid, Atom.to_string(live.status))
    deadline = System.monotonic_time(:millisecond) + @seen_ms

    case Records.seen(live, deadline, state) do
      :ok -> announce(state, live.id, existed?, in_flight?)
      _error -> RecordFeed.failed(state)
    end
  end

  defp announce(state, session_id, :absent, true), do: RecordFeed.silent(state, session_id)

  defp announce(state, session_id, existed?, _in_flight?),
    do: RecordFeed.changed(state, session_id, if(existed? == :absent, do: "new", else: "changed"))

  @impl true
  def handle_call({:hub, deadline, request}, {caller, _tag}, state) do
    # A call taken at or past its deadline is dropped before it reads or
    # writes: its caller already exited on its timeout.
    if System.monotonic_time(:millisecond) >= deadline do
      {:noreply, state}
    else
      {reply, state} = serve(request, caller, deadline, state)
      {:reply, reply, state}
    end
  end

  # The requests that take or end a place of decision 14.
  defp serve({:start, auth, _cwd_bytes} = request, caller, deadline, state) do
    with :ok <- Rules.handle(request, deadline, state),
         {:ok, state} <-
           Live.reserve(state, auth.user, caller, auth.user != state.default_owner_id) do
      {:ok, state}
    else
      error -> {error, state}
    end
  end

  # The place comes before the touch of the record, so a resume refused at
  # the cap moves nothing.
  defp serve({:resume, auth, id, exists?, running?}, caller, deadline, state) do
    with :ok <- Rules.handle({:session, auth, :resume, id, exists?, nil}, deadline, state),
         {:ok, state} <- place(state, auth.user, caller, id, running?) do
      {reply, state} =
        touched(Rules.touch(id, {:touch, nil}, deadline, state), :ok, caller, state)

      {reply, if(reply == :ok, do: RecordFeed.changed(state, id, "changed"), else: state)}
    else
      error -> {error, state}
    end
  end

  # The session of the resume of a folder is known only here: whether it
  # runs is a Registry lookup (`Helyx.Session.pid/1`), which does not wait.
  # The scan before it writes up to 256 rows, so a success sends the full
  # list to the subscribers of the default owner.
  defp serve({:newest, auth, _cwd, _scanned} = request, caller, deadline, state) do
    case Records.handle(request, deadline, state) do
      {:ok, id} ->
        state = RecordFeed.refresh(state, auth.user)
        newest_place(auth, id, caller, deadline, state)

      error ->
        {error, state}
    end
  end

  defp serve({:started, auth, start, pid}, caller, deadline, state) do
    state = LiveRead.touched(state, start.session_id)
    existed? = RecordFeed.row?(state, start.session_id)
    prior_owner = RecordFeed.owner(state, start.session_id)
    reply = Rules.handle({:started, auth, start}, deadline, state)
    state = Live.started(state, caller, start.session_id, pid, auth.user)

    {reply, started_change(reply, state, auth.user, start.session_id, existed?, prior_owner)}
  end

  defp serve({:resumed, auth, id, pid}, caller, deadline, state),
    do:
      {Rules.handle({:credential, auth}, deadline, state),
       Live.started(state, caller, id, pid, auth.user)}

  # The user for whom a session acts (`Helyx.Hub.actor/2`): its starter,
  # while the starter exists and owns the session.
  defp serve({:actor, id}, _caller, deadline, state),
    do: {Rules.handle({:actor, id, Live.starter(state, id)}, deadline, state), state}

  defp serve(:release, caller, _deadline, state), do: {:ok, Live.release(state, caller)}

  # The connections of decision 13: a `hello` adds its connection; a revoke
  # closes the connections that proved the token, a remove those of the
  # user, and a record change those that may no longer read.
  defp serve({:hello, token_id, connection}, _caller, deadline, state) do
    case Rules.handle({:hello, token_id}, deadline, state) do
      {:ok, found} = reply -> {reply, Connections.add(state, connection, found.user, found.token)}
      reply -> {reply, state}
    end
  end

  defp serve({:revoke_token, token_id} = request, _caller, deadline, state),
    do: revoked(handle(request, deadline, state), token_id, state)

  defp serve({:revoke, _auth, token_id} = request, _caller, deadline, state),
    do: revoked(handle(request, deadline, state), token_id, state)

  # A remove deletes the records of the user with it (decision 8), so the
  # read comes first: a "hub" record among them takes read access from every
  # user but the default owner, who owns the session then.
  defp serve({:remove_user, user_id} = request, _caller, deadline, %{store: mod, db: db} = state) do
    shared? = mod.hub_records?(db, user_id) != {:ok, false}

    # The schedules of the user go with it; their Tasks are killed.
    case handle(request, deadline, state) do
      :ok when shared? ->
        {:ok, state |> Connections.close_others([state.default_owner_id]) |> killed(user_id)}

      :ok ->
        {:ok, state |> Connections.close_user(user_id) |> killed(user_id)}

      error ->
        {error, state}
    end
  end

  # A get that finds a session with no row writes one (decision 8), so its
  # success tells the feed of the new record.
  defp serve({:record_get, _auth, id, _found} = request, _caller, deadline, state) do
    existed? = RecordFeed.row?(state, id)
    reply = handle(request, deadline, state)

    {reply,
     if(match?({:ok, _}, reply) and existed? == :absent,
       do: RecordFeed.changed(state, id, "new"),
       else: state
     )}
  end

  defp serve({:record_delete, auth, id, found} = request, _caller, deadline, state) do
    state = LiveRead.touched(state, id)
    owner = RecordFeed.owner(state, id)
    {reply, state} = readers_change(request, auth.user, id, found != nil, deadline, state)
    {reply, if(reply == :ok, do: RecordFeed.removed(state, id, owner), else: state)}
  end

  defp serve({:record_update, auth, id, found, _changes} = request, _caller, deadline, state) do
    {reply, state} = readers_change(request, auth.user, id, found != nil, deadline, state)

    {reply,
     if(match?({:ok, _}, reply), do: RecordFeed.changed(state, id, "changed"), else: state)}
  end

  # A project that a record used goes: the records of the user lose it, and
  # one full list tells them.
  defp serve({:project_delete, auth, _project} = request, _caller, deadline, state) do
    reply = handle(request, deadline, state)
    {reply, if(reply == :ok, do: RecordFeed.refresh(state, auth.user), else: state)}
  end

  # A text that Hub authorized moved the record: its `active_at`, and its
  # `prompt` the first time (`docs/features/hub.md`, decision 8).
  defp serve(
         {:session, _auth, _kind, id, _exists?, {:touch, _prompt}} = request,
         _caller,
         deadline,
         state
       ) do
    reply = handle(request, deadline, state)
    {reply, if(reply == :ok, do: RecordFeed.changed(state, id, "changed"), else: state)}
  end

  # The scan of `sessions.saved` writes the rows of the files that have none,
  # up to 256: one full list tells the subscribers of the default owner.
  defp serve({:saved, auth, _cwd, _cursor, _limit, _scanned} = request, _caller, deadline, state) do
    reply = Records.handle(request, deadline, state)
    {reply, if(match?({:ok, _}, reply), do: RecordFeed.refresh(state, auth.user), else: state)}
  end

  # The records subscription of a connection (`docs/features/live-records.md`).
  defp serve({:records_subscribe, auth, pid}, _caller, deadline, state) do
    with :ok <- Rules.handle({:credential, auth}, deadline, state),
         {:ok, views, more} <- RecordFeed.list(state, auth.user),
         {:ok, state} <- RecordFeed.subscribe(state, auth.user, pid) do
      {{:ok, %{"records" => views, "more" => more}}, state}
    else
      error -> {error, state}
    end
  end

  defp serve(request, _caller, deadline, state)
       when elem(request, 0) in [:schedule_list, :schedule_create],
       do: {Schedules.handle(request, deadline, state), state}

  # The subscriptions of decision 17.
  defp serve(request, _caller, deadline, state)
       when elem(request, 0) in [:subscription_list, :subscription_create],
       do: {Subscriptions.handle(request, deadline, state), state}

  # A delete kills the Task of its schedule, or the Tasks of the deliveries
  # of its subscription, before the reply; a prompt that the session already
  # took or queued still runs.
  defp serve({:schedule_delete, _auth, id} = request, _caller, deadline, state),
    do: deleted(Schedules.handle(request, deadline, state), :schedule, id, state)

  defp serve({:subscription_delete, _auth, id} = request, _caller, deadline, state),
    do: deleted(Subscriptions.handle(request, deadline, state), :subscription, id, state)

  # A resume of a wake-up that Core answers `not_found` deletes the record of
  # the session, as `hub.records.delete` does (decision 8).
  defp serve({:wake_gone, row}, caller, deadline, state) do
    {reply, state} = Wake.serve({:wake_refused, row}, caller, deadline, state)
    id = row.session_id
    state = LiveRead.touched(state, id)
    {_, state} = readers_change({:record_gone, id}, row.owner, id, false, deadline, state)
    {reply, RecordFeed.removed(state, id, row.owner)}
  end

  # The delivery of a wake-up that the session took moves the record, as a
  # text that Hub authorized (decision 12; live-records.md).
  defp serve({:wake_outcome, row, {:delivered, _head}} = request, caller, deadline, state) do
    {reply, state} = Wake.serve(request, caller, deadline, state)

    {reply,
     if(reply == :ok, do: RecordFeed.changed(state, row.session_id, "changed"), else: state)}
  end

  # The Hub calls of a delivery Task (`Helyx.Hub.Delivery`).
  defp serve(request, caller, deadline, state)
       when elem(request, 0) in [:wake_place, :wake_resumed, :wake_retry, :wake_refused] or
              elem(request, 0) in [:wake_decide, :wake_outcome],
       do: Wake.serve(request, caller, deadline, state)

  # The webhook endpoint of decision 17: the path id, the signature header,
  # and the raw body.
  defp serve({:webhook, id, signature, body}, _caller, deadline, state),
    do: {Webhook.accept(id, signature, body, deadline, state), state}

  defp serve(request, _caller, deadline, state), do: {handle(request, deadline, state), state}

  # The place of a resume of a folder, after the scan wrote its rows.
  defp newest_place(auth, id, caller, deadline, state) do
    running? = Helyx.Session.pid(%Helyx.Session{id: id, core: state.core}) != nil

    case place(state, auth.user, caller, id, running?) do
      {:ok, state} -> newest_touch(id, caller, deadline, state)
      error -> {error, state}
    end
  end

  defp newest_touch(id, caller, deadline, state) do
    {reply, state} =
      touched(Rules.touch(id, {:touch, nil}, deadline, state), {:ok, id}, caller, state)

    {reply, if(reply == {:ok, id}, do: RecordFeed.changed(state, id, "changed"), else: state)}
  end

  # A start of the default owner keeps every reader; a start of another user
  # moves the row that the feed may have written, so the owner before it gets
  # the removal, and no other user sees the id (`docs/features/live-records.md`).
  defp started_change(:ok, %{default_owner_id: user} = state, user, id, existed?, _prior) do
    state = RecordFeed.forget(state, id)
    RecordFeed.changed(state, id, if(existed? == :absent, do: "new", else: "changed"))
  end

  defp started_change(:ok, state, _user, id, _existed?, prior_owner),
    do: RecordFeed.moved(state, id, prior_owner)

  defp started_change(_error, state, _user, _id, _existed?, _prior), do: state

  defp killed(state, user_id), do: Wake.kill(state, &(&1.owner == user_id))

  defp deleted(:ok, key, id, state), do: {:ok, Wake.kill(state, &(Map.fetch!(&1, key) == id))}
  defp deleted(error, _key, _id, state), do: {error, state}

  defp revoked(:ok, token_id, state), do: {:ok, Connections.close_token(state, token_id)}
  defp revoked(error, _token_id, state), do: {error, state}

  # A resume whose touch fails is refused, and its place goes back.
  defp touched(:ok, reply, _caller, state), do: {reply, state}
  defp touched(error, _reply, caller, state), do: {error, Live.release(state, caller)}

  # A resume of a session that runs, or whose entry of the live set already
  # counts, attaches and needs no place.
  defp place(state, user, caller, id, running?) do
    if running? or Live.running?(state, id),
      do: {:ok, state},
      else: Live.reserve(state, user, caller, false)
  end

  defp readers_change(request, user, id, exists?, deadline, state) do
    before = Rules.access(id, exists?, state)

    case handle(request, deadline, state) do
      # A store that failed after the change may have committed it: the
      # change tells nothing of its readers, as a failed read before it.
      {:error, :failed} = reply -> {reply, lost_readers(reply, user, id, exists?, state)}
      {:error, _} = reply -> {reply, state}
      reply -> {reply, lost_readers(before, user, id, exists?, state)}
    end
  end

  # Only a "hub" record has readers besides its owner (decision 4); the
  # close keeps the owner before the change, who made it and whose close
  # would come before the reply of its own request, and the owner after, who
  # still reads. A read that fails closes every user but the one who made
  # the change.
  defp lost_readers({:ok, %{visibility: "hub", owner: owner}}, _user, id, exists?, state) do
    case Rules.access(id, exists?, state) do
      {:ok, %{visibility: "hub"}} -> state
      {:ok, %{owner: now}} -> Connections.close_others(state, [owner, now])
      _missing_or_failed -> Connections.close_others(state, [owner])
    end
  end

  defp lost_readers({:ok, _not_shared}, _user, _id, _exists?, state), do: state

  defp lost_readers(_failed, user, _id, _exists?, state),
    do: Connections.close_others(state, [user])

  # A notice of the session feed.
  @impl true
  def handle_info({:helyx_feed, pid, %Helyx.Sessions.Live{} = live}, state),
    do: {:noreply, seen(state, live, pid)}

  # An ask opens or ends: the record of the session waits, or stops waiting
  # (`docs/features/live-records.md`).
  def handle_info({:helyx_feed, _pid, %Helyx.Event{type: :ask} = event}, state) do
    %Helyx.Event{session_id: id, data: %{ask_id: ask_id}} = event
    state = LiveRead.touched(state, id)
    {:noreply, state |> RecordFeed.ask(id, ask_id) |> RecordFeed.changed(id, "changed")}
  end

  def handle_info({:helyx_feed, _pid, %Helyx.Event{type: :ask_end} = event}, state) do
    %Helyx.Event{session_id: id, data: %{ask_id: ask_id}} = event
    state = LiveRead.touched(state, id)
    {:noreply, state |> RecordFeed.ask_end(id, ask_id) |> RecordFeed.changed(id, "changed")}
  end

  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    state = LiveRead.failed(state, ref)
    id = Live.watched(state, ref)
    state = state |> Live.down(ref, pid) |> Connections.down(ref) |> Wake.ended(ref)

    state =
      case id do
        nil ->
          state

        id ->
          state
          |> LiveRead.touched(id)
          |> RecordFeed.clear_asks(id)
          |> RecordFeed.forget(id)
          |> RecordFeed.changed(id, "changed")
      end

    {:noreply, RecordFeed.down(state, ref)}
  end

  def handle_info({:place_expired, caller, monitor}, state),
    do: {:noreply, Live.expired(state, caller, monitor)}

  def handle_info(:wake_poll, state), do: {:noreply, poll(state)}
  def handle_info({:wake_kill, ref}, state), do: {:noreply, Wake.expired(state, ref)}

  # The result of a read of the live sessions, or the reply of a delivery
  # Task. A read that the Hub killed leaves no result; its `:DOWN` is above.
  def handle_info({ref, result}, state) when is_reference(ref) do
    case LiveRead.take(state, ref) do
      nil ->
        {:noreply, Wake.ended(state, ref)}

      {read, state} ->
        {outcome, state} = LiveRead.outcome(state, read, result)
        {:noreply, read_applied(state, outcome)}
    end
  end

  def handle_info({:live_read_timeout, ref}, state),
    do: {:noreply, LiveRead.timeout(state, ref)}

  # Another message changes nothing (the exit of the parent of the Hub, which
  # traps exits, stops it before this clause): a crash would lose the live
  # set.
  def handle_info(_message, state), do: {:noreply, state}

  # The stop kills the delivery Tasks, then closes the store (decision 16).
  @impl true
  def terminate(_reason, state) do
    Wake.stop(state)
    state.store.close(state.db)
  end

  defp handle({:add_user, name}, deadline, %{store: mod, db: db}) do
    with {:ok, id} <- insert_user(mod, db, name, deadline) do
      {:ok, %{id: id, name: name}}
    end
  end

  # The row of a session whose file is gone; a session with none is as it is.
  defp handle({:record_gone, id}, deadline, %{store: mod, db: db}) do
    case mod.delete_record(db, id, deadline) do
      {:error, :not_found} -> :ok
      other -> other
    end
  end

  defp handle({:remove_user, id}, _deadline, %{default_owner_id: id}),
    do: {:error, :default_owner}

  defp handle({:remove_user, id}, deadline, %{store: mod, db: db}) do
    case mod.remove_user(db, id, deadline) do
      {:error, :not_found} -> {:error, :unknown_user}
      other -> other
    end
  end

  # What the authority of the transport needs in the caller (decisions 7 and
  # 8): the Core and its data folder for the existence check, and for the
  # scan of saved sessions the default owner, who alone gets that scan.
  defp handle(:authority, _deadline, state),
    do: {:ok, %{core: state.core, dir: state.sessions_dir, default_owner: state.default_owner_id}}

  defp handle(:users, _deadline, %{store: mod, db: db}) do
    with {:ok, users} <- mod.users(db) do
      {:ok, Enum.map(users, &Map.take(&1, [:id, :name]))}
    end
  end

  defp handle({:create_token, user_id, name}, deadline, %{store: mod, db: db}) do
    id = Schedules.new_id()
    text = id <> "." <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

    token = %{
      id: id,
      user_id: user_id,
      name: name,
      key: :crypto.hash(:sha256, text),
      created_at: System.os_time(:second)
    }

    with :ok <- mod.add_token(db, token, @max_tokens, deadline), do: {:ok, text}
  end

  defp handle({:revoke_token, token_id}, deadline, %{store: mod, db: db}) do
    case mod.revoke_token(db, :any, token_id, deadline) do
      {:error, :not_found} -> {:error, :unknown_token}
      other -> other
    end
  end

  # The calls of the authority (`Helyx.Hub.Access`).
  defp handle(request, deadline, state), do: Rules.handle(request, deadline, state)
end
