defmodule Helyx.Hub.Server do
  @moduledoc false
  # The process of a Hub (`docs/features/hub.md`): the only caller of the
  # store, so a cap check and its insert are one step. Each request is a Hub
  # call of `Helyx.Hub.call/2` with its deadline; a call taken at or past
  # its deadline is dropped before it reads or writes.

  use GenServer

  alias Helyx.Hub.{Connections, Live, Records, Rules, Schedules, Wake}

  # The read of the live sessions of the Core at the start (decision 14).
  @seed_ms 5_000

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
          state = Map.merge(config, %{db: store, default_owner_id: owner_id})
          {:ok, state |> Live.init() |> Connections.init() |> Wake.init(), {:continue, :live}}

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
    user = %{id: new_id(), name: name, created_at: System.os_time(:second)}

    case mod.add_user(store, user, @max_users, deadline) do
      :ok -> {:ok, user.id}
      {:error, :name_taken} -> {:error, :invalid_name}
      {:error, _} = error -> error
    end
  end

  # Every live session of the Core enters the live set once, read with a
  # deadline; past it, or on a failed read, the set starts empty (decision
  # 14). The read runs in a process with a monitor and no link, and gives its
  # answer as its exit reason: the Hub, which traps exits, gets one `:DOWN`
  # and no `:EXIT`, and a read past its deadline is killed and its `:DOWN`
  # taken here, so no message of the read comes after the start.
  @impl true
  def handle_continue(:live, state) do
    core = state.core
    {pid, ref} = spawn_monitor(fn -> exit({:live, live_sessions(core)}) end)

    sessions =
      receive do
        {:DOWN, ^ref, :process, ^pid, {:live, sessions}} -> sessions
        {:DOWN, ^ref, :process, ^pid, _reason} -> []
      after
        @seed_ms ->
          Process.exit(pid, :kill)

          receive do
            {:DOWN, ^ref, :process, ^pid, _reason} -> []
          end
      end

    # The first poll of the wake-ups comes at the start (decision 12).
    {:noreply, state |> Live.seed(sessions) |> Wake.poll()}
  end

  defp live_sessions(core) do
    for live <- Helyx.Sessions.list_live(core),
        pid = Helyx.Session.pid(%Helyx.Session{id: live.id, core: core}),
        do: {live.id, pid}
  end

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

  # The requests that take or end a place of decision 14; the place is the
  # caller's, the process that runs the request.
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
      touched(Rules.touch(id, {:touch, nil}, deadline, state), :ok, caller, state)
    else
      error -> {error, state}
    end
  end

  # The session of the resume of a folder is known only here: whether it
  # runs is a Registry lookup (`Helyx.Session.pid/1`), which does not wait.
  # A derived record has no row to touch.
  defp serve({:newest, auth, _cwd, _scanned} = request, caller, deadline, state) do
    with {:ok, id, kind} <- Records.handle(request, deadline, state),
         running? = Helyx.Session.pid(%Helyx.Session{id: id, core: state.core}) != nil,
         {:ok, state} <- place(state, auth.user, caller, id, running?) do
      touch = if kind == :stored, do: {:touch, nil}
      touched(Rules.touch(id, touch, deadline, state), {:ok, id}, caller, state)
    else
      error -> {error, state}
    end
  end

  defp serve({:started, auth, start, pid}, caller, deadline, state),
    do:
      {Rules.handle({:started, auth, start}, deadline, state),
       Live.started(state, caller, start.session_id, pid, auth.user)}

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
  # user, and a record change those of every user but the owner who could
  # read the session before and cannot after (the owner keeps its
  # connections, also when a delete takes its access).
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
  # read comes first: a "hub" record among them, or a read that fails, takes
  # read access from every user but the default owner, who owns the session
  # then; that close takes the connections of the user too.
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

  defp serve({:record_delete, auth, id, found} = request, _caller, deadline, state),
    do: readers_change(request, auth.user, id, found != nil, deadline, state)

  defp serve({:record_update, auth, id, found, _changes} = request, _caller, deadline, state),
    do: readers_change(request, auth.user, id, found != nil, deadline, state)

  defp serve({op, _auth, _id, _exists?} = request, _caller, deadline, state)
       when op == :schedule_list,
       do: {Schedules.handle(request, deadline, state), state}

  # A delete kills the Task of its schedule; a prompt that the session
  # already took or queued still runs.
  defp serve({:schedule_delete, _auth, id} = request, _caller, deadline, state) do
    case Schedules.handle(request, deadline, state) do
      :ok -> {:ok, Wake.kill(state, &(&1.schedule == id))}
      error -> {error, state}
    end
  end

  # A resume of a wake-up that Core answers `not_found` deletes the record of
  # the session, as `hub.records.delete` does (decision 8).
  defp serve({:wake_gone, row}, caller, deadline, state) do
    {reply, state} = Wake.serve({:wake_refused, row}, caller, deadline, state)
    id = row.session_id
    {_, state} = readers_change({:record_gone, id}, row.owner, id, false, deadline, state)
    {reply, state}
  end

  # The Hub calls of a delivery Task (`Helyx.Hub.Delivery`).
  defp serve(request, caller, deadline, state)
       when elem(request, 0) in [:wake_place, :wake_resumed, :wake_retry, :wake_refused] or
              elem(request, 0) in [:wake_decide, :wake_outcome],
       do: Wake.serve(request, caller, deadline, state)

  defp serve({op, _auth, _id, _exists?, _fields} = request, _caller, deadline, state)
       when op == :schedule_create,
       do: {Schedules.handle(request, deadline, state), state}

  defp serve(request, _caller, deadline, state), do: {handle(request, deadline, state), state}

  defp killed(state, user_id), do: Wake.kill(state, &(&1.owner == user_id))

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

  # Only a "hub" record has readers besides its owner (decision 4), so only
  # a change from "hub" takes read access from a user who is not the owner
  # (a delete also takes the access of the owner, who keeps its connections:
  # decision 13 closes "every user but the owner"): it closes the connections of
  # every user but the owner after, who still reads, and the owner before,
  # who made the change, and whose close would come before the reply of its
  # own request. A read that fails tells nothing, so a change that then
  # commits closes every user but the one who made it.
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

  @impl true
  def handle_info({:DOWN, ref, :process, pid, _reason}, state),
    do: {:noreply, state |> Live.down(ref, pid) |> Connections.down(ref) |> Wake.ended(ref)}

  def handle_info({:place_expired, caller, monitor}, state),
    do: {:noreply, Live.expired(state, caller, monitor)}

  def handle_info(:wake_poll, state), do: {:noreply, Wake.poll(state)}
  def handle_info({:wake_kill, ref}, state), do: {:noreply, Wake.expired(state, ref)}
  # The reply of a delivery Task.
  def handle_info({ref, _result}, state) when is_reference(ref),
    do: {:noreply, Wake.ended(state, ref)}

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

  # What the authority of the transport needs in the caller: the Core and
  # its data folder for the existence check (decision 8), and for the scan
  # of saved sessions (decision 7) the Core and the default owner, who alone
  # gets that scan.
  defp handle(:authority, _deadline, state),
    do: {:ok, %{core: state.core, dir: state.sessions_dir, default_owner: state.default_owner_id}}

  defp handle(:users, _deadline, %{store: mod, db: db}) do
    with {:ok, users} <- mod.users(db) do
      {:ok, Enum.map(users, &Map.take(&1, [:id, :name]))}
    end
  end

  defp handle({:create_token, user_id, name}, deadline, %{store: mod, db: db}) do
    id = new_id()
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

  # The shape of a session id, the base64url of 9 random bytes (decisions 1
  # and 2). Helyx.Session.Id is internal to Core, which Hub does not call.
  defp new_id, do: Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)
end
