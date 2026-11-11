defmodule Helyx.Transport.WebSocket.Ops do
  @moduledoc false
  # The operations of the wire on the public session and server API
  # (`docs/features/wire-protocol.md`, "Operations", "Deadlines"). One
  # table holds the facts of each op; `check/3` checks its params, so a
  # worker holds only the checked values; `run/1` runs the call in the
  # worker of one request and returns `{:ok, result}` or
  # `{:error, code, text}`.

  alias Helyx.Session
  alias Helyx.Transport.WebSocket.{Bounds, Outbound, Wire}

  @default_tail 200

  @prompt_params %{
    "session" => {:required, :session},
    "text" => {:required, :string},
    "origin" => {:optional, :origin}
  }

  @hub_ops ~w(hub.me hub.records.get hub.records.update hub.records.delete
              hub.records.search hub.projects.list hub.projects.create
              hub.projects.update hub.projects.delete hub.tokens.list hub.tokens.revoke
              hub.schedules.list hub.schedules.create hub.schedules.delete
              hub.subscriptions.list hub.subscriptions.create hub.subscriptions.delete)

  # The facts of one operation of the wire: `params` is a map from a key to
  # `{required | optional, type}`, nil when the op checks its own params in
  # its `check/3` clause; `deadline` overrides `Bounds.deadline/1`; `slot`
  # says that the result takes the encoder slot of the connection; `result`,
  # `release`, and `run` are the facts of an authority
  # (`Helyx.Transport.WebSocket.Authorize`). Every `hub.*` op is the `run` of
  # an authority.
  @ops Map.new(@hub_ops, &{&1, [run: true]})
       |> Map.merge(%{
         "sessions.live" => [params: nil, result: true],
         "sessions.saved" => [
           params: %{
             "cwd" => {:optional, :string},
             "after" => {:optional, :string},
             "limit" => {:optional, :int}
           },
           slot: true,
           run: true
         ],
         "start" => [
           params: %{"cwd" => {:required, :string}, "model" => {:optional, :string}},
           deadline: :infinity,
           result: true,
           release: true
         ],
         "resume" => [params: nil, deadline: :infinity, result: true, release: true],
         "prompt" => [params: @prompt_params],
         "steer" => [params: @prompt_params],
         "follow_up" => [params: @prompt_params],
         "subscribe" => [
           params: %{
             "session" => {:required, :session},
             "tail" => {:optional, :int},
             "after" => {:optional, :after},
             "answers" => {:optional, :bool}
           },
           slot: true
         ],
         "unsubscribe" => [],
         "history" => [
           params: %{
             "session" => {:required, :session},
             "instance_id" => {:required, :string},
             "before" => {:required, :string},
             "limit" => {:optional, :int}
           },
           slot: true
         ],
         "abort" => [params: %{"session" => {:required, :session}}],
         "set_model" => [
           params: %{"session" => {:required, :session}, "model" => {:required, :string}}
         ],
         "compact" => [],
         "stop" => [params: %{"session" => {:required, :session}}],
         "answer" => []
       })

  @core_errors ~w(session_not_found too_many_sessions invalid_cwd not_found invalid_utf8
                  invalid_origin queue_full turn_running text_too_large instance_changed
                  unknown_message invalid_answer not_waiting)a

  @core_codes Enum.map(@core_errors, &Atom.to_string/1)

  @spec deadline(String.t()) :: pos_integer() | :infinity
  def deadline(op), do: Keyword.get(facts(op), :deadline, Bounds.deadline(op))

  # An operation whose result can be large takes the encoder slot of the
  # connection before it reads from Core.
  def slot?(op), do: fact(op, :slot)

  # Under an authority, `sessions.saved` is the `run` of the authority: the
  # scan of Core and one Hub call (docs/features/hub.md, decision 7).
  @saved_run_ms 10_000 + 5_000
  @spec deadline(String.t(), boolean()) :: pos_integer() | :infinity
  def deadline("sessions.saved", true), do: @saved_run_ms
  def deadline(op, _authority?), do: deadline(op)

  # Whether the `result/5` of the authority answers the op, whether the op
  # frees a reserved place with `release/4` when its Core call fails, and
  # whether the authority runs the op in place of a Core call.
  def result?(op), do: fact(op, :result)
  def release?(op), do: fact(op, :release)
  def run?(op), do: fact(op, :run)

  # Runs `body` in the worker of request `id` within `ms`. The deadline of
  # a request with a large result starts at its slot. An open has no
  # deadline here: the session bounds it (#834).
  def within(conn, out, id, op, ms, body) do
    if slot?(op), do: Outbound.slot(out)
    timer = ms != :infinity && Process.send_after(conn, {:deadline, self(), id}, ms)

    try do
      body.()
    after
      # The timer ends with its worker, so the timers are at most the
      # requests in flight.
      if timer, do: Process.cancel_timer(timer)
    end
  end

  # The error of `code` for `op`, with the text that the op gives when Core
  # answers it, so a refusal of the authority reads as the answer of a
  # missing object.
  def error(op, code) do
    if Outbound.transport_code?(code) and (op == "subscribe" or code not in @core_codes),
      do: Outbound.error(code),
      else: {:error, code, String.replace(code, "_", " ")}
  end

  def run(call) do
    call.() |> result()
  catch
    :exit, {:timeout, _call} -> Outbound.error("timeout")
  end

  # A text op to a session that a stop unloaded loads it first, so a client
  # sends to a session, not to an id (docs/features/idle-unload.md). A running
  # session costs one Registry lookup. The load runs before the deadline of
  # the op, as a `resume` does: a load of a file has the bound of the session
  # open (#834). A missing file answers `session_not_found`, and any other
  # error answers `failed`.
  @spec load(Helyx.Core.name(), String.t(), map()) ::
          :ok | {:error, String.t(), String.t()}
  def load(core, op, %{"session" => id}) when op in ~w(prompt steer follow_up) do
    session = %Session{id: id, core: core}

    if Session.pid(session) do
      :ok
    else
      case Helyx.Sessions.resume(core, id: id) do
        {:ok, _resumed} ->
          :ok

        {:error, reason} when reason in [:not_found, :invalid_id] ->
          error(op, "session_not_found")

        {:error, _reason} ->
          Outbound.error("failed")
      end
    end
  end

  def load(_core, _op, _params), do: :ok

  # The Core call of a request as a closure of its checked params, run by
  # `run/1`, or `:bad_params` or `:unknown_op`.
  def check(core, "sessions.live", params) do
    with :ok <- keys(params, [], []) do
      {:ok, fn -> {:ok, %{"sessions" => Enum.map(Helyx.Sessions.list_live(core), &live/1)}} end}
    end
  end

  def check(core, "resume", params) do
    with {:ok, opts} <- resume_opts(params),
         do: {:ok, fn -> core |> Helyx.Sessions.resume(opts) |> started() end}
  end

  def check(core, "compact", params) do
    with :ok <- keys(params, ~w(session), ~w(text)),
         {:ok, session} <- session(core, params),
         {:ok, text} <- string(Map.get(params, "text", "")),
         do: {:ok, fn -> Session.compact(session, text) end}
  end

  # An answer is an object. Core checks it here, before the worker, with a
  # walk that stops past its bound, so no worker holds an answer over it
  # (`Helyx.Session.check_answer/1`); a refused one gives the worker only
  # its error.
  def check(core, "answer", params) do
    with :ok <- keys(params, ~w(session ask_id answer), []),
         {:ok, session} <- session(core, params),
         {:ok, ask_id} <- string(params["ask_id"]),
         {:ok, answer} <- object(params["answer"]) do
      case Session.check_answer(answer) do
        :ok -> {:ok, fn -> Session.answer(session, ask_id, answer) end}
        error -> {:ok, fn -> error end}
      end
    end
  end

  # Every other op reads its params from the table: the typed values then
  # build its Core call.
  def check(core, op, params) do
    with {:ok, spec} <- params_spec(op),
         {:ok, values} <- typed(core, spec, params) do
      {:ok, call(core, op, values)}
    end
  end

  # The session and the options of a `subscribe`, or `:bad_params`.
  def subscribe_params(core, params) do
    with {:ok, spec} <- params_spec("subscribe"),
         {:ok, values} <- typed(core, spec, params) do
      opts = values |> Map.take(["tail", "answers"]) |> keyword()
      opts = if after_ = values["after"], do: Keyword.put(opts, :after, after_), else: opts
      # A subscribe with no tail gets the default tail of the wire, not the
      # full transcript of a client in the node.
      {:ok, values["session"], Keyword.put_new(opts, :tail, @default_tail)}
    end
  end

  defp call(core, "sessions.saved", values),
    do: fn -> saved_page(Helyx.Sessions.list_saved(core, keyword(values))) end

  defp call(core, "start", values),
    do: fn -> core |> Helyx.Sessions.start(keyword(values)) |> started() end

  defp call(_core, op, values) when op in ~w(prompt steer follow_up) do
    fn ->
      apply(Session, String.to_existing_atom(op), [
        values["session"],
        values["text"],
        origin(values)
      ])
    end
  end

  defp call(_core, "history", values) do
    fn ->
      page(
        Session.history(
          values["session"],
          values["instance_id"],
          values["before"],
          limit(values)
        )
      )
    end
  end

  defp call(_core, "abort", values), do: fn -> Session.abort(values["session"]) end

  defp call(_core, "set_model", values),
    do: fn -> Session.set_model(values["session"], values["model"]) end

  defp call(_core, "stop", values),
    do: fn -> stopped(Helyx.Sessions.stop(values["session"])) end

  # The params of a common op, or `:unknown_op` for an op that has none.
  defp params_spec(op) do
    case Map.fetch(@ops, op) do
      {:ok, facts} ->
        case Keyword.fetch(facts, :params) do
          {:ok, %{} = spec} -> {:ok, spec}
          _ -> :unknown_op
        end

      :error ->
        :unknown_op
    end
  end

  # The checked values of `params` for `spec`, or `:bad_params`. Every key
  # of `spec` that is required is present, no key outside `spec` is, and
  # each value has its type.
  defp typed(core, spec, params) do
    if Enum.all?(spec, fn {key, {need, _}} -> need == :optional or Map.has_key?(params, key) end) and
         Enum.all?(Map.keys(params), &Map.has_key?(spec, &1)) do
      Enum.reduce_while(params, {:ok, %{}}, &cast_param(core, spec, &1, &2))
    else
      :bad_params
    end
  end

  defp cast_param(core, spec, {key, value}, {:ok, values}) do
    {_need, type} = Map.fetch!(spec, key)

    case cast(core, type, value) do
      {:ok, value} -> {:cont, {:ok, Map.put(values, key, value)}}
      :bad_params -> {:halt, :bad_params}
    end
  end

  defp cast(_core, :string, value) when is_binary(value), do: {:ok, value}
  defp cast(_core, :int, value) when is_integer(value), do: {:ok, value}
  defp cast(_core, :bool, value) when is_boolean(value), do: {:ok, value}
  defp cast(_core, :object, value) when is_map(value), do: {:ok, value}

  defp cast(core, :session, id) when is_binary(id),
    do: {:ok, %Session{id: id, core: core}}

  defp cast(_core, :origin, nil), do: {:ok, nil}

  defp cast(_core, :origin, %{"kind" => "product", "id" => id} = origin)
       when map_size(origin) == 2 and is_binary(id),
       do: {:ok, %{kind: :product, id: id}}

  defp cast(_core, :after, nil), do: {:ok, nil}

  defp cast(_core, :after, %{"instance_id" => instance_id, "seq" => seq} = after_)
       when map_size(after_) == 2 and is_binary(instance_id) and is_integer(seq) and seq >= 0,
       do: {:ok, {instance_id, seq}}

  defp cast(_core, _type, _value), do: :bad_params

  # The checked values as a keyword list for an option list. The keys of the
  # table make the atoms, so a key of a frame never makes one, and a VM that
  # loads no module of a key, such as `:answers`, still answers
  # (docs/features/wire-protocol.md, "Bounds").
  @keys %{
    "after" => :after,
    "answers" => :answers,
    "cwd" => :cwd,
    "limit" => :limit,
    "model" => :model,
    "tail" => :tail
  }

  defp keyword(values),
    do: Enum.map(values, fn {key, value} -> {Map.fetch!(@keys, key), value} end)

  defp origin(%{"origin" => origin}) when origin != nil, do: [origin: origin]
  defp origin(_values), do: []

  defp limit(%{"limit" => limit}), do: [limit: limit]
  defp limit(_values), do: []

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

  defp session(core, %{"session" => id}) when is_binary(id),
    do: {:ok, %Session{id: id, core: core}}

  defp session(_core, _params), do: :bad_params

  defp string(value) when is_binary(value), do: {:ok, value}
  defp string(_value), do: :bad_params

  defp object(value) when is_map(value), do: {:ok, value}
  defp object(_value), do: :bad_params

  defp started({:ok, %Session{id: id}}), do: {:ok, %{"session" => id}}
  defp started({:error, reason}) when reason in @core_errors, do: {:error, reason}
  defp started({:error, {:invalid_model_ref, _}} = error), do: error
  defp started({:error, {:unknown_provider, _}} = error), do: error

  defp started({:error, reason}) do
    Helyx.Reason.log_term("wire start failed", reason)
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

  defp saved_page({:ok, items, next}),
    do: {:ok, %{"items" => Enum.map(items, &saved/1), "next" => next}}

  defp saved_page({:error, :invalid_cwd} = error), do: error
  defp saved_page({:error, _limit_or_cursor}), do: :bad_params

  defp saved(summary) do
    %{
      "id" => summary.id,
      "cwd" => summary.cwd,
      "model" => summary.model,
      "mtime" => summary.mtime,
      "prompt" => summary.prompt
    }
  end

  # The session ended: the wire does not carry the stop report (#752).
  defp stopped({:error, {:not_released, _handles}}), do: :ok
  defp stopped(result), do: result

  defp page({:ok, page}), do: {:ok, Wire.value(page)}
  defp page({:error, :invalid_limit}), do: :bad_params
  defp page(error), do: error

  defp result(:ok), do: {:ok, %{}}
  defp result({:ok, %{} = result}), do: {:ok, result}

  defp result(:bad_params), do: Outbound.error("bad_params")

  defp result({:error, _code, _text} = error), do: error

  defp result({:error, {code, text}}) when code in [:invalid_model_ref, :unknown_provider],
    do: {:error, Atom.to_string(code), text}

  # The wire has no code for it: no wire start sets the limit
  # (docs/features/output-limit.md).
  defp result({:error, {:max_output_tokens_unsupported, _id}}), do: Outbound.error("failed")

  defp result({:error, code}) when code in @core_errors,
    do: {:error, Atom.to_string(code), String.replace(Atom.to_string(code), "_", " ")}

  defp fact(op, key), do: Keyword.get(facts(op), key, false)
  defp facts(op), do: Map.fetch!(@ops, op)
end
