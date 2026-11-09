defmodule Helyx.Hub.Saved do
  @moduledoc false
  # `sessions.saved` and the `resume` of a folder under a Hub, in the caller
  # (`docs/features/hub.md`, decision 7). Two sources: the stored records
  # that the user may read, from one Hub call; and for the default owner the
  # scan of Core (`Helyx.Sessions.list_saved/2`, the 256 newest files), with
  # the ids that have a row dropped in the same Hub call. Each is filtered
  # by access before the page and the cursor are made.

  alias Helyx.Hub

  # The scan of Core, its deadline, and the page of `sessions.saved` (Bounds).
  @scan_limit 256
  @scan_ms 10_000
  @max_limit 256
  @default_limit 50
  # The deadline of `sessions.saved` under an authority on the wire, 15,000
  # ms, less 500 ms for the reply.
  @run_ms 15_000 - 500

  # The answer of `sessions.saved`, or a Hub answer for `Access` to map.
  # Each answer checks the credential in one Hub call: the call of the
  # page, or for an answer decided before it (bad params, a `cwd` that Core
  # refuses, a scan past its deadline) a call of the credential alone.
  def page(arg, auth, params) do
    until = System.monotonic_time(:millisecond) + @run_ms

    with {:ok, cwd, cursor, limit} <- params(params),
         {:ok, scanned} <- scan(arg, auth, cwd, params["after"]) do
      ids = Enum.map(scanned, & &1.id)

      case Hub.call(arg.hub, {:saved, auth, cwd, cursor, limit, ids}, until) do
        {:ok, stored, derived} -> {:ok, merge(stored, scanned, derived, limit)}
        other -> other
      end
    else
      early -> after_credential(arg, auth, early)
    end
  end

  defp after_credential(arg, auth, early) do
    case Hub.call(arg.hub, {:credential, auth}) do
      :ok -> early
      other -> other
    end
  end

  # The params of Core, for every user: `cwd` a text, `limit` 1 to 256, and
  # `after` parsed with the rule of Core (an integer, `:`, a session id); a
  # key that is present is never nil. A `cwd` that Core refuses is
  # `invalid_cwd`, for every user, before any scan.
  defp params(params) do
    with true <- Enum.all?(Map.keys(params), &(&1 in ~w(cwd after limit))),
         {:ok, cwd} <- optional(params, "cwd", &is_binary/1),
         {:ok, limit} <- optional(params, "limit", &(is_integer(&1) and &1 in 1..@max_limit)),
         {:ok, cursor} <- optional(params, "after", &is_binary/1),
         {:ok, cursor} <- cursor(cursor),
         :ok <- cwd(cwd) do
      {:ok, cwd, cursor, limit || @default_limit}
    else
      {:error, :invalid_cwd} = error -> error
      _ -> {:error, :bad_params}
    end
  end

  defp optional(params, key, valid?) do
    case Map.fetch(params, key) do
      :error -> {:ok, nil}
      {:ok, value} -> if valid?.(value), do: {:ok, value}, else: :error
    end
  end

  # The rule of Core for a `cwd`: UTF-8 with no NUL byte.
  defp cwd(nil), do: :ok

  defp cwd(cwd) do
    if String.valid?(cwd) and not String.contains?(cwd, <<0>>),
      do: :ok,
      else: {:error, :invalid_cwd}
  end

  defp cursor(nil), do: {:ok, nil}

  defp cursor(cursor) do
    with [time, id] <- String.split(cursor, ":", parts: 2),
         {time, ""} <- Integer.parse(time),
         true <- id =~ ~r/\A[A-Za-z0-9_-]{12}\z/ do
      {:ok, {time, id}}
    else
      _ -> :error
    end
  end

  # The scan of Core, for the default owner only, in a Task killed past its
  # deadline. Another user gets no item of a session with no record.
  defp scan(%{default_owner: user} = arg, %{user: user}, cwd, cursor) do
    opts =
      for {key, value} <- [limit: @scan_limit, cwd: cwd, after: cursor], value, do: {key, value}

    task = Task.async(fn -> Helyx.Sessions.list_saved(arg.core, opts) end)

    case Task.yield(task, @scan_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:ok, items, _next}} -> {:ok, items}
      nil -> {:error, :timeout}
    end
  end

  defp scan(_arg, _auth, _cwd, _cursor), do: {:ok, []}

  # The two lists, newest first by `{mtime, id}`; each holds only items
  # after the cursor (the query and the scan of Core compare them), so the
  # page is their first `limit`, and `next` the key of its last item when
  # either list holds more.
  defp merge(stored, scanned, derived, limit) do
    keep = MapSet.new(derived)

    items =
      Enum.map(stored, &item(&1.session_id, &1.cwd, &1.model, &1.active_at, &1.prompt)) ++
        for s <- scanned, s.id in keep, do: item(s.id, s.cwd, s.model, s.mtime, s.prompt)

    {page, rest} = items |> Enum.sort_by(&{&1["mtime"], &1["id"]}, :desc) |> Enum.split(limit)
    next = if rest != [], do: next(List.last(page))
    %{"items" => page, "next" => next}
  end

  defp item(id, cwd, model, mtime, prompt),
    do: %{"id" => id, "cwd" => cwd, "model" => model, "mtime" => mtime, "prompt" => prompt}

  defp next(%{"mtime" => mtime, "id" => id}), do: "#{mtime}:#{id}"

  # The `resume` of a folder: the id of the newest session of the folder
  # that the user owns, or `{:error, :not_found}`, after one credential
  # check as for `page/3`. The scan goes to Hub as the `mtime` of each id.
  def newest(arg, auth, cwd) do
    with :ok <- cwd(cwd),
         {:ok, scanned} <- scan(arg, auth, cwd, nil) do
      Hub.call(arg.hub, {:newest, auth, cwd, Map.new(scanned, &{&1.id, &1.mtime})})
    else
      early -> after_credential(arg, auth, early)
    end
  end
end
