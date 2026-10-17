defmodule Helyx.Transport.WebSocket.Ops do
  @moduledoc false
  # The operations of the wire on the public session and server API
  # (`docs/features/wire-protocol.md`, "Operations", "Deadlines"). `run/3`
  # runs in the worker of one request and returns `{:ok, result}` or
  # `{:error, code, text}`.

  alias Helyx.Session
  alias Helyx.Transport.WebSocket.{Outbound, Wire}

  # Each deadline and its reason is in the table "Deadlines".
  @deadlines %{
    "abort" => 46_000,
    "stop" => 77_000,
    "start" => 30_000,
    "resume" => 30_000,
    "sessions.saved" => 10_000
  }
  @default_deadline 6_000
  @default_tail 200

  @ops ~w(sessions.live sessions.saved start resume history prompt steer follow_up abort set_model
           compact stop)

  @core_errors ~w(session_not_found too_many_sessions invalid_cwd not_found invalid_utf8
                  invalid_origin queue_full turn_running text_too_large instance_changed
                  unknown_message)a

  def known?(op), do: op in @ops

  # An operation whose result can be large takes the encoder slot of the
  # connection before it reads from Core.
  def slot?(op), do: op in ~w(sessions.saved history)

  def deadline(op), do: Map.get(@deadlines, op, @default_deadline)

  def run(core, op, params) do
    op |> call(core, params) |> result()
  catch
    :exit, {:timeout, _call} -> Outbound.error("timeout")
  end

  defp call("sessions.live", core, params) do
    with :ok <- keys(params, [], []) do
      {:ok, %{"sessions" => Enum.map(Helyx.Sessions.list_live(core), &live/1)}}
    end
  end

  defp call("sessions.saved", core, params) do
    with :ok <- keys(params, [], ~w(cwd after limit)),
         {:ok, opts} <- opts(params, cwd: &is_binary/1, after: &is_binary/1, limit: &is_integer/1) do
      case Helyx.Sessions.list_saved(core, opts) do
        {:ok, items, next} -> {:ok, %{"items" => Enum.map(items, &saved/1), "next" => next}}
        {:error, :invalid_cwd} -> {:error, :invalid_cwd}
        {:error, _limit_or_cursor} -> :bad_params
      end
    end
  end

  defp call("start", core, params) do
    with :ok <- keys(params, ~w(cwd), ~w(model)),
         {:ok, opts} <- opts(params, cwd: &is_binary/1, model: &is_binary/1) do
      core |> Helyx.Sessions.start(opts) |> started()
    end
  end

  defp call("resume", core, params) do
    with {:ok, opts} <- resume_opts(params), do: core |> Helyx.Sessions.resume(opts) |> started()
  end

  defp call(op, core, params) when op in ~w(prompt steer follow_up) do
    with :ok <- keys(params, ~w(session text), ~w(origin)),
         {:ok, session} <- session(core, params),
         {:ok, text} <- string(params["text"]),
         {:ok, opts} <- origin(params["origin"]) do
      apply(Session, String.to_existing_atom(op), [session, text, opts])
    end
  end

  defp call("history", core, params) do
    with :ok <- keys(params, ~w(session instance_id before), ~w(limit)),
         {:ok, session} <- session(core, params),
         {:ok, instance_id} <- string(params["instance_id"]),
         {:ok, before} <- string(params["before"]),
         {:ok, opts} <- opts(params, limit: &is_integer/1) do
      case Session.history(session, instance_id, before, opts) do
        {:ok, page} -> {:ok, Wire.value(page)}
        {:error, :invalid_limit} -> :bad_params
        error -> error
      end
    end
  end

  defp call("abort", core, params) do
    with :ok <- keys(params, ~w(session), []),
         {:ok, session} <- session(core, params),
         do: Session.abort(session)
  end

  defp call("set_model", core, params) do
    with :ok <- keys(params, ~w(session model), []),
         {:ok, session} <- session(core, params),
         {:ok, model} <- string(params["model"]),
         do: Session.set_model(session, model)
  end

  defp call("compact", core, params) do
    with :ok <- keys(params, ~w(session), ~w(text)),
         {:ok, session} <- session(core, params),
         {:ok, text} <- string(Map.get(params, "text", "")),
         do: Session.compact(session, text)
  end

  defp call("stop", core, params) do
    with :ok <- keys(params, ~w(session), []),
         {:ok, session} <- session(core, params),
         do: Helyx.Sessions.stop(session)
  end

  # The session and the options of a `subscribe`, or `:bad_params`.
  def subscribe_params(core, params) do
    with :ok <- keys(params, ~w(session), ~w(tail after)),
         {:ok, session} <- session(core, params),
         {:ok, opts} <- opts(params, tail: &is_integer/1),
         {:ok, after_} <- after_(params["after"]) do
      # A subscribe with no tail gets the default tail of the wire, not the
      # full transcript of a client in the node.
      {:ok, session, Keyword.put_new(opts, :tail, @default_tail) ++ after_}
    end
  end

  defp after_(nil), do: {:ok, []}

  defp after_(%{"instance_id" => instance_id, "seq" => seq} = after_)
       when map_size(after_) == 2 and is_binary(instance_id) and is_integer(seq) and seq >= 0,
       do: {:ok, after: {instance_id, seq}}

  defp after_(_after), do: :bad_params

  defp resume_opts(%{"id" => id} = params) when map_size(params) == 1 and is_binary(id),
    do: {:ok, id: id}

  defp resume_opts(%{"cwd" => cwd} = params) when map_size(params) == 1 and is_binary(cwd),
    do: {:ok, cwd: cwd}

  defp resume_opts(_params), do: :bad_params

  # Every key of `required`, and no key outside `required` and `optional`.
  defp keys(params, required, optional) do
    if Enum.all?(required, &Map.has_key?(params, &1)) and
         Enum.all?(Map.keys(params), &(&1 in required or &1 in optional)),
       do: :ok,
       else: :bad_params
  end

  # The params present, as options, each of its type.
  defp opts(params, types) do
    Enum.reduce_while(types, {:ok, []}, fn {key, type?}, {:ok, acc} ->
      case Map.fetch(params, Atom.to_string(key)) do
        :error -> {:cont, {:ok, acc}}
        {:ok, value} -> opt(key, value, type?.(value), acc)
      end
    end)
  end

  defp opt(key, value, true, acc), do: {:cont, {:ok, [{key, value} | acc]}}
  defp opt(_key, _value, false, _acc), do: {:halt, :bad_params}

  defp session(core, %{"session" => id}) when is_binary(id),
    do: {:ok, %Session{id: id, core: core}}

  defp session(_core, _params), do: :bad_params

  defp string(value) when is_binary(value), do: {:ok, value}
  defp string(_value), do: :bad_params

  defp origin(nil), do: {:ok, []}

  defp origin(%{"kind" => "product", "id" => id} = origin)
       when map_size(origin) == 2 and is_binary(id),
       do: {:ok, origin: %{kind: :product, id: id}}

  defp origin(_origin), do: :bad_params

  defp started({:ok, %Session{id: id}}), do: {:ok, %{"session" => id}}
  defp started({:error, reason}) when reason in @core_errors, do: {:error, reason}
  defp started({:error, {:invalid_model_ref, _}} = error), do: error
  defp started({:error, {:unknown_provider, _}} = error), do: error

  defp started({:error, reason}) do
    Helyx.Reason.log("wire start failed", reason)
    {:error, "start_failed", Helyx.Reason.text(reason)}
  end

  defp live(%Helyx.Sessions.Live{} = live) do
    %{
      "id" => live.id,
      "instance_id" => live.instance_id,
      "cwd" => live.cwd,
      "model" => live.model,
      "status" => Atom.to_string(live.status)
    }
  end

  defp saved(summary) do
    %{
      "id" => summary.id,
      "cwd" => summary.cwd,
      "model" => summary.model,
      "mtime" => summary.mtime,
      "prompt" => summary.prompt
    }
  end

  defp result(:ok), do: {:ok, %{}}
  defp result({:ok, %{} = result}), do: {:ok, result}

  defp result(:bad_params), do: Outbound.error("bad_params")

  defp result({:error, _code, _text} = error), do: error

  defp result({:error, {code, text}}) when code in [:invalid_model_ref, :unknown_provider],
    do: {:error, Atom.to_string(code), text}

  defp result({:error, code}) when code in @core_errors,
    do: {:error, Atom.to_string(code), String.replace(Atom.to_string(code), "_", " ")}
end
