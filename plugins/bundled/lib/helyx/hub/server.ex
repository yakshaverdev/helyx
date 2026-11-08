defmodule Helyx.Hub.Server do
  @moduledoc false
  # The process of a Hub (`docs/features/hub.md`): the only caller of the
  # store, so a cap check and its insert are one step. Each request is a Hub
  # call of `Helyx.Hub.call/2` with its deadline; a call taken at or past
  # its deadline is dropped before it reads or writes.

  use GenServer

  alias Helyx.Hub.{Live, Records, Rules}

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
          {:ok, Live.init(state), {:continue, :live}}

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

    {:noreply, Live.seed(state, sessions)}
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
       Live.started(state, caller, start.session_id, pid)}

  defp serve({:resumed, auth, id, pid}, caller, deadline, state),
    do: {Rules.handle({:credential, auth}, deadline, state), Live.started(state, caller, id, pid)}

  defp serve(:release, caller, _deadline, state), do: {:ok, Live.release(state, caller)}

  defp serve(request, _caller, deadline, state), do: {handle(request, deadline, state), state}

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

  @impl true
  def handle_info({:DOWN, ref, :process, pid, _reason}, state),
    do: {:noreply, Live.down(state, ref, pid)}

  def handle_info({:place_expired, caller, monitor}, state),
    do: {:noreply, Live.expired(state, caller, monitor)}

  # Another message changes nothing (the exit of the parent of the Hub, which
  # traps exits, stops it before this clause): a crash would lose the live
  # set.
  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state), do: state.store.close(state.db)

  defp handle({:add_user, name}, deadline, %{store: mod, db: db}) do
    with {:ok, id} <- insert_user(mod, db, name, deadline) do
      {:ok, %{id: id, name: name}}
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
