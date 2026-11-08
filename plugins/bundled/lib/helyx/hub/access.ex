defmodule Helyx.Hub.Access do
  @moduledoc false
  # The authority of a transport for a Hub (`Helyx.Transport.WebSocket.
  # Authority`, `docs/features/hub.md`, decision 5): `Helyx.Hub.authority/1`
  # gives `{Helyx.Hub.Access, %{hub: hub, core: core, dir: sessions_dir,
  # default_owner: user_id}}`.
  # Each callback runs in the process of the transport that calls it, and
  # makes one Hub call. Each but `release`, which only gives back a place,
  # first checks the credential: one that no longer holds closes the
  # connection with 4403.

  @behaviour Helyx.Transport.WebSocket.Authority

  alias Helyx.Hub
  alias Helyx.Hub.{Params, Saved}

  # The bound of the `prompt` of a record: the caller cuts the text, so no
  # Hub call carries more of it (Store schema).
  @max_prompt_bytes 1_024
  # The deadline of the find of the existence check (decision 8).
  @find_ms 5_000
  # The bounds of a stored `cwd` and `model` (Bounds).
  @max_cwd_bytes 4_096
  @max_model_bytes 256
  # The deadline of a `hub.*` operation on the wire, 6,000 ms, less 500 ms
  # for the reply: a write of the op commits before it or not at all. The
  # find of the existence check takes up to 5,000 ms of it.
  @run_ms 6_000 - 500

  @read_ops ~w(subscribe history)
  @text_ops ~w(prompt steer follow_up)
  @write_ops ~w(abort set_model compact answer stop)
  @param_ops ~w(hub.records.get hub.records.update hub.records.delete hub.records.search
                hub.projects.create hub.projects.update hub.projects.delete)
  @bad_params {:error, "bad_params", "a param is missing, of the wrong type, or unknown"}

  @impl true
  def hello(arg, %{nonce: nonce, token: token_id, proof: proof}) do
    case Hub.call(arg.hub, {:hello, token_id}) do
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
      passed(
        Hub.call(arg.hub, {:resume, auth, id, found(arg, id) != nil, running?(arg, id)}),
        params
      )

  # The resume of a folder becomes the resume of the newest session of the
  # folder that the user owns (decision 7).
  def check(arg, auth, "resume", %{"cwd" => cwd}) do
    case Saved.newest(arg, auth, cwd) do
      {:ok, id} -> {:ok, %{"id" => id}}
      other -> refused(other)
    end
  end

  def check(arg, auth, op, %{"session" => id} = params) when op in @read_ops,
    do: passed(Hub.call(arg.hub, {:session, auth, :read, id, running?(arg, id), nil}), params)

  def check(arg, auth, op, %{"session" => id, "text" => text} = params) when op in @text_ops,
    do:
      passed(
        Hub.call(arg.hub, {:session, auth, :write, id, running?(arg, id), {:touch, cut(text)}}),
        params
      )

  def check(arg, auth, op, %{"session" => id} = params) when op in @write_ops,
    do: passed(Hub.call(arg.hub, {:session, auth, :write, id, running?(arg, id), nil}), params)

  # The existence check of decision 8, before the Hub call. An operation
  # that needs a running session asks the Registry.
  defp running?(arg, id), do: session_pid(arg, id) != nil

  # The process of a session, which the live set monitors after the start
  # or resume that made or attached to it (decision 14).
  defp session_pid(arg, id), do: Helyx.Session.pid(%Helyx.Session{id: id, core: arg.core})

  # `resume` and the record operations take the `cwd` and `model` of a
  # session that exists, or nil: the header of its file for a Core with a
  # data folder, and the live list for a session that runs with no file, or
  # for a Core with none. A Core with a data folder runs the find for every
  # id, and one with none reads the live list for every id, so the time of
  # the answer does not tell a refused session from a missing one. The find
  # runs in a Task with a deadline, since Core bounds neither the project
  # folders nor their files: a find that does not end in time finds
  # nothing. Every value, from the disk or from Core, passes one check: a
  # `cwd` or `model` that a record cannot hold finds nothing.
  defp found(%{dir: nil} = arg, id), do: checked(live(arg, id))
  defp found(arg, id), do: checked(file(arg.dir, id) || running(arg, id))

  defp file(dir, id) do
    task = Task.async(fn -> Helyx.Session.File.Scan.find(dir, id) end)

    case Task.yield(task, @find_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:ok, _path, %{"cwd" => cwd} = header}} -> %{cwd: cwd, model: header["model"]}
      _ -> nil
    end
  end

  defp running(arg, id), do: if(running?(arg, id), do: live(arg, id))

  defp live(arg, id) do
    Enum.find_value(Helyx.Sessions.list_live(arg.core), fn
      %{id: ^id, cwd: cwd, model: model} -> %{cwd: cwd, model: model}
      _ -> nil
    end)
  end

  # A `cwd` is any UTF-8 path of 1 to 4,096 bytes; a model a text of 1 to
  # 256 bytes, the bound of a model ref (Bounds).
  defp checked(%{cwd: cwd, model: model} = found) do
    cwd? = is_binary(cwd) and byte_size(cwd) in 1..@max_cwd_bytes and String.valid?(cwd)
    if cwd? and Params.text?(model, 1, @max_model_bytes), do: found
  end

  defp checked(nil), do: nil

  defp passed(:ok, params), do: {:ok, params}
  defp passed(other, _params), do: refused(other)

  defp refused(:revoked), do: {:close, 4403}
  defp refused({:error, code}), do: {:error, Atom.to_string(code)}

  # The first 1,024 bytes of a text, cut on a UTF-8 boundary: the frame
  # decode of the transport admits only UTF-8.
  defp cut(text) do
    head = binary_part(text, 0, min(byte_size(text), @max_prompt_bytes))
    Enum.find([head | trims(head)], &String.valid?/1)
  end

  defp trims(head) do
    for n <- 1..3, byte_size(head) > n, do: binary_part(head, 0, byte_size(head) - n)
  end

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
      {:ok, views, next} -> {:ok, %{"items" => Enum.map(views, &view/1), "next" => next}}
      other -> error(other)
    end
  end

  defp hub_op(arg, auth, "hub.projects.create", name),
    do: project_answer(Hub.call(arg.hub, {:project_create, auth, name}, arg.until))

  defp hub_op(arg, auth, "hub.projects.update", {id, name}),
    do: project_answer(Hub.call(arg.hub, {:project_update, auth, id, name}, arg.until))

  defp hub_op(arg, auth, "hub.projects.delete", id),
    do: empty(Hub.call(arg.hub, {:project_delete, auth, id}, arg.until))

  defp token(token),
    do: %{"id" => token.id, "name" => token.name, "created_at" => token.created_at}

  defp record({:ok, view}), do: {:ok, %{"record" => view(view)}}
  defp record(other), do: error(other)

  defp empty(:ok), do: {:ok, %{}}
  defp empty(other), do: error(other)

  defp project_answer({:ok, project}), do: {:ok, %{"project" => project(project)}}
  defp project_answer(other), do: error(other)

  defp project(p), do: %{"id" => p.id, "name" => p.name, "created_at" => p.created_at}

  defp view(v) do
    %{
      "session" => v.session,
      "owner" => %{"id" => v.owner.id, "name" => v.owner.name},
      "project" => v.project,
      "title" => v.title,
      "labels" => v.labels,
      "visibility" => v.visibility,
      "archived" => v.archived,
      "stored" => v.stored,
      "created_at" => v.created_at,
      "updated_at" => v.updated_at
    }
  end

  # The codes of the Hub operations and of `sessions.saved`, with the text
  # of the code; a name that another project of the user has is
  # `bad_params` (`hub.projects.*`).
  @codes ~w(session_not_found forbidden too_many_records too_many_projects unknown_project
            unknown_token invalid_cwd)a

  defp error(:revoked), do: {:close, 4403}
  defp error({:error, :busy}), do: {:error, "busy", "too many requests in flight"}
  defp error({:error, :timeout}), do: {:error, "timeout", "the operation passed its deadline"}
  defp error({:error, :name_taken}), do: @bad_params
  defp error({:error, :bad_params}), do: @bad_params

  defp error({:error, code}) when code in @codes,
    do: {:error, Atom.to_string(code), String.replace(Atom.to_string(code), "_", " ")}

  defp error({:error, _}), do: {:error, "failed", "the operation failed"}

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
    start = %{session_id: id, cwd: params["cwd"], model: Map.get(params, "model")}

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
