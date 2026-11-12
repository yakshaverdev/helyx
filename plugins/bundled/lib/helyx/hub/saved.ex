defmodule Helyx.Hub.Saved do
  @moduledoc false
  # `sessions.saved` and the `resume` of a folder under a Hub, in the caller
  # (`docs/features/hub.md`, decision 7). One source: the records that the
  # user may read, from one Hub call. For the default owner the scan of Core
  # (`Helyx.Sessions.list_saved/2`, the 256 newest files) goes first, and the
  # Hub call writes the rows of the files that have none, so the page and the
  # cursor hold only records.

  alias Helyx.Hub
  alias Helyx.Hub.Params

  # The scan of Core and its deadline (Bounds); the page of `sessions.saved`
  # takes the bounds of `Params`.
  @scan_limit 256
  @scan_ms 10_000
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
      case Hub.call(arg.hub, {:saved, auth, cwd, cursor, limit, scanned}, until) do
        {:ok, rows} -> {:ok, page(rows, limit)}
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
         {:ok, limit} <-
           optional(params, "limit", &(is_integer(&1) and &1 in 1..Params.max_limit())),
         {:ok, cursor} <- optional(params, "after", &is_binary/1),
         {:ok, cursor} <- cursor(cursor),
         :ok <- cwd(cwd) do
      {:ok, cwd, cursor, limit || Params.default_limit()}
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
  # deadline. The Hub call writes the rows of the files that have none;
  # another user gets no item of a session with no record.
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

  # The page of at most `limit` rows, newest first by `{active_at, id}`, and
  # the cursor of its last item when the store read one more. The store
  # applies the cursor of the client, so every row is after it.
  defp page(rows, limit) do
    {page, rest} = Enum.split(rows, limit)
    next = if rest != [], do: next(List.last(page))
    %{"items" => Enum.map(page, &item/1), "next" => next}
  end

  defp item(row),
    do: %{
      "id" => row.session_id,
      "cwd" => row.cwd,
      "model" => row.model,
      "mtime" => row.active_at,
      "prompt" => row.prompt
    }

  defp next(row), do: "#{row.active_at}:#{row.session_id}"

  # The `resume` of a folder: the id of the newest session of the folder
  # that the user owns, or `{:error, :not_found}`, after one credential
  # check as for `page/3`. The scan goes to Hub as its summaries, whose
  # `mtime` and prompt become the row of a file that has none.
  def newest(arg, auth, cwd) do
    with :ok <- cwd(cwd),
         {:ok, scanned} <- scan(arg, auth, cwd, nil) do
      Hub.call(arg.hub, {:newest, auth, cwd, scanned})
    else
      early -> after_credential(arg, auth, early)
    end
  end
end
