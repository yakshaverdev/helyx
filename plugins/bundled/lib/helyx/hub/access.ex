defmodule Helyx.Hub.Access do
  @moduledoc false
  # The authority of a transport for a Hub (`Helyx.Transport.WebSocket.
  # Authority`, `docs/features/hub.md`, decision 5).
  # Each callback runs in the process of the transport that calls it, and
  # makes one Hub call. Each but `release`, which only gives back a place,
  # first checks the credential: one that no longer holds closes the
  # connection with 4403.

  @behaviour Helyx.Transport.WebSocket.Authority

  alias Helyx.Hub
  alias Helyx.Hub.{Params, Saved}

  # The deadline of the find of the existence check (decision 8).
  @find_ms 5_000
  # The deadline of a `hub.*` operation on the wire, 6,000 ms, less 500 ms
  # for the reply: a write of the op commits before it or not at all. The
  # find of the existence check takes up to 5,000 ms of it.
  @run_ms 6_000 - 500

  @read_ops ~w(subscribe history)
  @text_ops ~w(prompt steer follow_up)
  @write_ops ~w(abort set_model compact answer stop)
  @param_ops Params.ops()
  @bad_params {:error, "bad_params", "a param is missing, of the wrong type, or unknown"}

  # The Hub call registers the connection for the closes of decision 13; a
  # connection whose proof fails closes at once, and the Hub drops it at its
  # `:DOWN`.
  @impl true
  def hello(arg, %{nonce: nonce, token: token_id, proof: proof, connection: connection}) do
    case Hub.call(arg.hub, {:hello, token_id, connection}) do
      {:ok, found} ->
        with {:ok, key} <- key(found),
             true <- proof?(key, nonce, proof),
             do: {:ok, Map.take(found, [:user, :token])},
             else: (_ -> :error)

      :error ->
        # The answer for an unknown id costs the HMAC of a known one, so it
        # does not tell whether the id exists (decision 3).
        _ = proof?(:crypto.strong_rand_bytes(32), nonce, proof)
        :error

      {:error, :busy} ->
        {:error, :busy}
    end
  end

  # The credential of a paired client of the public listener: it acts as the
  # default owner, the user that the server token gives (decision 3;
  # `docs/features/remote-hands.md`, "The handshake of a paired peer"). The
  # Hub adds the connection to the connections of decision 13, so a change of
  # access closes it as it closes a connection with the server token.
  @impl true
  def paired(arg, _kind, _name, connection) do
    case Hub.call(arg.hub, {:paired, connection}) do
      {:ok, auth} -> {:ok, auth}
      {:error, _passing} -> {:error, :busy}
    end
  end

  # The key of a token, or of the server token, which the closure of the
  # option gives and the caller checks: a closure that gives no text proves
  # nothing.
  defp key(%{key: key}), do: {:ok, key}

  defp key(%{server_token: token}) do
    case token.() do
      text when is_binary(text) and text != "" -> {:ok, :crypto.hash(:sha256, text)}
      _ -> :error
    end
  end

  defp proof?(key, nonce, proof) do
    expected = Base.encode64(:crypto.mac(:hmac, :sha256, key, nonce))
    is_binary(proof) and Plug.Crypto.secure_compare(expected, proof)
  end

  @impl true
  def check(arg, auth, "sessions.live", params),
    do: passed(Hub.call(arg.hub, {:credential, auth}), params)

  def check(arg, auth, "start", %{"cwd" => cwd} = params),
    do: passed(Hub.call(arg.hub, {:start, auth, byte_size(cwd)}), params)

  def check(arg, auth, "resume", %{"id" => id} = params),
    do:
      passed(Hub.call(arg.hub, {:resume, auth, id, exists?(arg, id), running?(arg, id)}), params)

  # The resume of a folder becomes the resume of the newest session of the
  # folder that the user owns (decision 7).
  def check(arg, auth, "resume", %{"cwd" => cwd}) do
    case Saved.newest(arg, auth, cwd) do
      {:ok, id} -> {:ok, %{"id" => id}}
      other -> refused(other)
    end
  end

  def check(arg, auth, op, %{"session" => id} = params) when op in @read_ops,
    do: passed(Hub.call(arg.hub, {:session, auth, :read, id, exists?(arg, id), nil}), params)

  def check(arg, auth, op, %{"session" => id, "text" => text} = params) when op in @text_ops,
    do:
      passed(
        Hub.call(
          arg.hub,
          {:session, auth, :write, id, exists?(arg, id), {:touch, Params.cut(text)}}
        ),
        params
      )

  def check(arg, auth, op, %{"session" => id} = params) when op in @write_ops,
    do: passed(Hub.call(arg.hub, {:session, auth, :write, id, running?(arg, id), nil}), params)

  # A text op to a session that a stop unloaded resumes it as the `resume` op
  # does: the place of the user's live sessions, the Core resume, and the
  # starter (docs/features/idle-unload.md). A session that runs needs none.
  @impl true
  def load(arg, auth, op, %{"session" => id}) when op in @text_ops do
    if running?(arg, id) do
      :ok
    else
      case resume(arg, auth, id) do
        {:ok, _session} -> :ok
        {:close, 4403} = close -> close
        {:error, reason} -> load_error(reason)
      end
    end
  end

  def load(_arg, _auth, _op, _params), do: :ok

  # The load of a stopped session for a text, shared by the wire authority
  # and the Elixir API (`Helyx.Hub.Api`): the place of the user's live
  # sessions, the Core resume, and the starter. A session that runs is
  # attached with no place; a load stops only a process that its own resume
  # started, so a loader that attached leaves the process of the loader that
  # started it alone. A place that a load took goes back when a later step
  # fails. The result is `{:ok, session}`, `{:close, 4403}`, or
  # `{:error, code}`, each caller mapping the error at its edge.
  @doc false
  @spec resume(map(), map(), String.t()) ::
          {:ok, Helyx.Session.t()} | {:error, term()} | {:close, 4403}
  def resume(arg, auth, id) do
    if running?(arg, id) do
      resume_check(arg, auth, id)
    else
      load_stopped(arg, auth, id)
    end
  end

  # A session that runs, or that another loader started between the check
  # for running and the check's place: an attach takes no place, so two
  # loads of one session take one place.
  defp load_stopped(arg, auth, id) do
    case check(arg, auth, "resume", %{"id" => id}) do
      {:ok, _params} ->
        resume_core(arg, auth, id)

      {:error, "too_many_sessions"} = error ->
        if running?(arg, id), do: resume_check(arg, auth, id), else: error

      {:error, code} ->
        {:error, code_atom(code)}

      {:close, 4403} = close ->
        close
    end
  end

  defp resume_check(arg, auth, id) do
    case check(arg, auth, "resume", %{"id" => id}) do
      {:ok, _params} -> resume_core(arg, auth, id)
      {:error, code} -> {:error, code_atom(code)}
      {:close, 4403} = close -> close
    end
  end

  defp resume_core(arg, auth, id) do
    case Helyx.Sessions.resume(arg.core, id: id) do
      {:ok, session, origin} ->
        bind(arg, auth, id, session, origin)

      {:error, reason} ->
        give_back(arg)
        {:error, resume_error(reason)}
    end
  end

  # The starter binds the session to its user; a session with none acts for
  # no user in its coordinator tools, so the caller gets no session.
  defp bind(arg, auth, id, session, origin) do
    case hub_call(arg.hub, {:resumed, auth, id, Helyx.Session.pid(session)}) do
      :ok ->
        {:ok, session}

      other ->
        if origin == :started, do: Helyx.Sessions.stop(session)
        give_back(arg)
        {:error, hub_error(other)}
    end
  end

  # The Hub calls of a load: an exit of a call is a timeout, as on the wire,
  # and the place goes back.
  defp hub_call(hub, request) do
    Hub.call(hub, request)
  catch
    :exit, _reason -> {:error, :timeout}
  end

  # The place of decision 14 goes back at once; an attach holds none, so a
  # release changes nothing.
  defp give_back(arg) do
    _ = hub_call(arg.hub, :release)
    :ok
  end

  defp hub_error(:revoked), do: :revoked
  defp hub_error({:error, code}), do: code
  defp hub_error(_other), do: :timeout

  # The check gives its codes as names of the wire; a load gives the codes of
  # the Hub and Core as atoms, and each caller maps them.
  defp code_atom("session_not_found"), do: :session_not_found
  defp code_atom("not_found"), do: :not_found
  defp code_atom("forbidden"), do: :forbidden
  defp code_atom("too_many_sessions"), do: :too_many_sessions
  defp code_atom("busy"), do: :busy
  defp code_atom("timeout"), do: :timeout
  defp code_atom(_other), do: :failed

  # A file that a resume does not find answers as a missing session.
  defp resume_error(reason) when reason in [:not_found, :invalid_id], do: :session_not_found
  defp resume_error(reason), do: reason

  # A client of a text op knows these errors; a load that fails for another
  # reason answers `failed`, so no client meets a code that its text does not
  # name. A revoked credential still closes the connection.
  defp load_error(:revoked), do: {:close, 4403}

  defp load_error(reason) when reason in [:session_not_found, :not_found, :invalid_id],
    do: {:error, "session_not_found"}

  defp load_error(reason) when reason in [:forbidden, :busy, :timeout],
    do: {:error, Atom.to_string(reason)}

  defp load_error(_reason), do: {:error, "failed"}

  # The existence check of decision 8, before the Hub call. An operation
  # that needs a running session asks the Registry.
  defp running?(arg, id), do: session_pid(arg, id) != nil

  # The whole check, for `Helyx.Hub.owner/2`: a session that runs, or whose
  # file the find confirms.
  @doc false
  def exists?(arg, id), do: running?(arg, id) or found(arg, id) != nil

  # The existence check of the schedule and subscription operations: a
  # session whose file the find confirms, or that runs with no file.
  @doc false
  def found?(arg, id), do: found(arg, id) != nil

  # The process of a session, which the live set monitors after the start
  # or resume that made or attached to it (decision 14).
  defp session_pid(arg, id), do: Helyx.Session.pid(%Helyx.Session{id: id, core: arg.core})

  # `resume` and the record operations take the `cwd` and `model` of a
  # session that exists, or nil (decision 8; hub.md, Accepted holes, "The
  # time of a refusal"). The find runs in a Task with a deadline, since Core
  # bounds neither the project folders nor their files: a find that does not
  # end in time finds nothing. Every value, from the disk or from Core,
  # passes one check: a `cwd` or `model` that a record cannot hold finds
  # nothing. A parent link that does not pass its check is dropped, as at a
  # resume of the session.
  defp found(%{dir: nil} = arg, id), do: checked(live(arg, id))
  defp found(arg, id), do: checked(file(arg.dir, id) || running(arg, id))

  defp file(dir, id) do
    task = Task.async(fn -> Helyx.Session.File.Scan.find(dir, id) end)

    case Task.yield(task, @find_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:ok, _path, %{"cwd" => cwd} = header}} ->
        %{cwd: cwd, model: header["model"], parent: parent(header["parent"])}

      _ ->
        nil
    end
  end

  defp running(arg, id), do: if(running?(arg, id), do: live(arg, id))

  defp live(arg, id) do
    Enum.find_value(Helyx.Sessions.list_live(arg.core), fn
      %{id: ^id, cwd: cwd, model: model, parent: parent} ->
        %{cwd: cwd, model: model, parent: parent}

      _ ->
        nil
    end)
  end

  defp parent(link) do
    case Helyx.Session.Input.header_parent(link) do
      {:ok, checked} -> checked
      {:error, :invalid_parent} -> nil
    end
  end

  # The `cwd` and `model` of a record hold their bounds, else the find finds
  # nothing (`Params.record_fields?/2`).
  defp checked(%{cwd: cwd, model: model} = found) do
    if Params.record_fields?(cwd, model), do: found
  end

  defp checked(nil), do: nil

  defp passed(:ok, params), do: {:ok, params}
  defp passed(other, _params), do: refused(other)

  defp refused(:revoked), do: {:close, 4403}
  defp refused({:error, code}), do: {:error, Atom.to_string(code)}

  @impl true
  def run(arg, auth, "hub.me", params) when map_size(params) == 0 do
    case Hub.call(arg.hub, {:me, auth}) do
      {:ok, user} -> {:ok, %{"user" => %{"id" => user.id, "name" => user.name}}}
      other -> error(other)
    end
  end

  def run(arg, auth, "hub.tokens.list", params) when map_size(params) == 0 do
    case Hub.call(arg.hub, {:tokens, auth}) do
      {:ok, tokens} -> {:ok, %{"tokens" => Enum.map(tokens, &token/1)}}
      other -> error(other)
    end
  end

  # A revoke of the token of the connection closes it before the reply
  # (decision 13).
  def run(arg, auth, "hub.tokens.revoke", %{"token" => token_id} = params)
      when map_size(params) == 1 and is_binary(token_id) do
    case Hub.call(arg.hub, {:revoke, auth, token_id}) do
      :ok when token_id == auth.token -> {:close, 4403}
      :ok -> {:ok, %{}}
      other -> error(other)
    end
  end

  def run(arg, auth, "hub.projects.list", params) when map_size(params) == 0 do
    case Hub.call(arg.hub, {:projects, auth}) do
      {:ok, projects} -> {:ok, %{"projects" => Enum.map(projects, &project/1)}}
      other -> error(other)
    end
  end

  # The params first, in the caller, before any object is read (decision 5);
  # bad params still check the credential first.
  def run(arg, auth, op, params) when op in @param_ops do
    arg = Map.put(arg, :until, System.monotonic_time(:millisecond) + @run_ms)

    case Params.check(op, params) do
      {:ok, checked} -> hub_op(arg, auth, op, checked)
      :bad_params -> after_credential(arg, auth, @bad_params)
      :text_too_large -> after_credential(arg, auth, error({:error, :text_too_large}))
    end
  end

  # The answers that need no object still check the credential first, so a
  # revoked one closes the connection at its next request.
  def run(arg, auth, op, _params)
      when op in ~w(hub.me hub.tokens.list hub.tokens.revoke hub.projects.list),
      do: after_credential(arg, auth, @bad_params)

  # The page of `sessions.saved` under a Hub (decision 7).
  def run(arg, auth, "sessions.saved", params) do
    case Saved.page(arg, auth, params) do
      {:ok, _page} = ok -> ok
      other -> error(other)
    end
  end

  def run(arg, auth, _op, _params),
    do: after_credential(arg, auth, {:error, "unknown_op", "unknown operation"})

  defp after_credential(arg, auth, answer) do
    case Hub.call(arg.hub, {:credential, auth}) do
      :ok -> answer
      other -> error(other)
    end
  end

  defp hub_op(arg, auth, "hub.records.get", id),
    do: record(Hub.call(arg.hub, {:record_get, auth, id, found(arg, id)}, arg.until))

  defp hub_op(arg, auth, "hub.records.update", {id, changes}),
    do: record(Hub.call(arg.hub, {:record_update, auth, id, found(arg, id), changes}, arg.until))

  defp hub_op(arg, auth, "hub.records.delete", id),
    do: empty(Hub.call(arg.hub, {:record_delete, auth, id, found(arg, id)}, arg.until))

  defp hub_op(arg, auth, "hub.records.search", filters) do
    case Hub.call(arg.hub, {:record_search, auth, filters}, arg.until) do
      {:ok, views, next} ->
        {:ok, %{"items" => Enum.map(views, &record_wire/1), "next" => next}}

      other ->
        error(other)
    end
  end

  defp hub_op(arg, auth, "hub.projects.create", name),
    do: project_answer(Hub.call(arg.hub, {:project_create, auth, name}, arg.until))

  defp hub_op(arg, auth, "hub.projects.update", {id, name}),
    do: project_answer(Hub.call(arg.hub, {:project_update, auth, id, name}, arg.until))

  defp hub_op(arg, auth, "hub.projects.delete", id),
    do: empty(Hub.call(arg.hub, {:project_delete, auth, id}, arg.until))

  defp hub_op(arg, auth, "hub.schedules.create", parsed),
    do: Helyx.Hub.Access.Schedules.create(arg, auth, parsed)

  defp hub_op(arg, auth, "hub.schedules.list", id),
    do: Helyx.Hub.Access.Schedules.list(arg, auth, id)

  defp hub_op(arg, auth, "hub.schedules.delete", id),
    do: empty(Hub.call(arg.hub, {:schedule_delete, auth, id}, arg.until))

  # The event subscriptions of decision 17, in `Helyx.Hub.Access.Subscriptions`.
  defp hub_op(arg, auth, "hub.subscriptions.create", parsed),
    do: Helyx.Hub.Access.Subscriptions.create(arg, auth, parsed)

  defp hub_op(arg, auth, "hub.subscriptions.list", id),
    do: Helyx.Hub.Access.Subscriptions.list(arg, auth, id)

  defp hub_op(arg, auth, "hub.subscriptions.delete", id),
    do: empty(Hub.call(arg.hub, {:subscription_delete, auth, id}, arg.until))

  defp token(token),
    do: %{"id" => token.id, "name" => token.name, "created_at" => token.created_at}

  defp record({:ok, view}), do: {:ok, %{"record" => record_wire(view)}}
  defp record(other), do: error(other)

  defp empty(:ok), do: {:ok, %{}}
  defp empty(other), do: error(other)

  defp project_answer({:ok, project}), do: {:ok, %{"project" => project(project)}}
  defp project_answer(other), do: error(other)

  # A map with atom keys as the wire shows it, shared with
  # `Helyx.Hub.Access.Schedules` and `Helyx.Hub.Access.Subscriptions`.
  @doc false
  def wire(map), do: Map.new(map, fn {key, value} -> {Atom.to_string(key), value} end)

  defp project(p), do: %{"id" => p.id, "name" => p.name, "created_at" => p.created_at}

  # The one shape of a record on the wire, shared with the records feed.
  defp record_wire(view), do: Helyx.Hub.Records.wire(view)

  # The codes of the Hub operations and of `sessions.saved`, with the text
  # of the code; a name that another project of the user has is
  # `bad_params` (`hub.projects.*`).
  @codes ~w(session_not_found forbidden too_many_records too_many_projects unknown_project
            unknown_token invalid_cwd too_many_schedules unknown_schedule text_too_large
            too_many_event_subscriptions unknown_subscription)a

  # The reply of a Hub call as an error of the wire, shared with
  # `Helyx.Hub.Access.Subscriptions`.
  @doc false
  def error(:revoked), do: {:close, 4403}
  def error({:error, :busy}), do: {:error, "busy", "too many requests in flight"}
  def error({:error, :timeout}), do: {:error, "timeout", "the operation passed its deadline"}
  def error({:error, :name_taken}), do: @bad_params
  def error({:error, :bad_params}), do: @bad_params

  def error({:error, code}) when code in @codes,
    do: {:error, Atom.to_string(code), String.replace(Atom.to_string(code), "_", " ")}

  def error({:error, _}), do: {:error, "failed", "the operation failed"}

  @impl true
  def webhook(arg, id, request), do: Helyx.Hub.Access.Subscriptions.webhook(arg, id, request)

  # The records subscription of the connection (`docs/features/live-records.md`):
  # one Hub call registers the process and gives the first list. The Hub
  # process it names is the one that the transport monitors, so a Hub that
  # restarts ends the subscription.
  @impl true
  def records(arg, auth, pid) do
    hub = GenServer.whereis(arg.hub)

    case Hub.call(arg.hub, {:records_subscribe, auth, pid}) do
      {:ok, result} -> {:ok, result, hub}
      other -> error(other)
    end
  end

  @impl true
  def result(arg, auth, "sessions.live", _params, %{"sessions" => lines} = result) do
    case Hub.call(arg.hub, {:readable, auth, Enum.map(lines, & &1["id"])}) do
      {:ok, ids} ->
        readable = MapSet.new(ids)
        {:ok, %{result | "sessions" => Enum.filter(lines, &(&1["id"] in readable))}}

      other ->
        refused(other)
    end
  end

  def result(arg, auth, "start", params, %{"session" => id} = result) do
    start = %{
      session_id: id,
      cwd: params["cwd"],
      model: Map.get(params, "model"),
      thread_of: Map.get(params, "thread_of")
    }

    case Hub.call(arg.hub, {:started, auth, start, session_pid(arg, id)}) do
      :ok -> {:ok, result}
      other -> refused(other)
    end
  end

  def result(arg, auth, "resume", _params, %{"session" => id} = result),
    do: passed(Hub.call(arg.hub, {:resumed, auth, id, session_pid(arg, id)}), result)

  # The place of a start or resume whose Core call failed goes back at once
  # (decision 14); a Hub that does not answer frees it at the `:DOWN` of the
  # caller or after its 60,000 ms.
  @impl true
  def release(arg, _auth, _op, _params) do
    _ = Hub.call(arg.hub, :release)
    :ok
  end
end
