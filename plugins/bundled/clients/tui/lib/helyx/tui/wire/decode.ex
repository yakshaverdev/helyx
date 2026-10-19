defmodule Helyx.TUI.Wire.Decode do
  @moduledoc false
  # The JSON values of the server as the Core values that
  # `Helyx.TUI.ViewModel` folds (`docs/features/wire-protocol.md`,
  # "Codec"). A message is the message entry of the session file
  # (`Helyx.Session.File.Codec`). A tolerant reader: a key that it does not
  # know is ignored, and an event of a type that it does not know is nil. A
  # known value with a broken shape raises, and each public function gives
  # `:error` for it: the connection ends on a contract break.

  import Helyx.Usage, only: [wire_tokens?: 1]

  alias Helyx.{Event, Message, ModelRef}
  alias Helyx.Session.File.{Codec, Scan}
  alias Helyx.Session.{Snapshot, Totals}
  alias Helyx.TUI.ViewModel

  @event_types ~w(turn_start message_start message_update message_end tool_execution_end
                  turn_end queue_update queue_dropped model_change resume_id
                  steer_unconfirmed compaction notice ask ask_end)a
  @types Map.new(@event_types, &{Atom.to_string(&1), &1})

  @error_codes ~w(unknown_op bad_params busy timeout failed session_not_found
                  too_many_sessions too_many_subscriptions unknown_sub instance_changed
                  unknown_message invalid_cwd invalid_model_ref unknown_provider not_found
                  start_failed invalid_utf8 invalid_origin queue_full turn_running
                  text_too_large invalid_answer not_waiting)a
  @codes Map.new(@error_codes, &{Atom.to_string(&1), &1})
  # The codes whose text names the value: the TUI shows it.
  @texts ~w(invalid_model_ref unknown_provider start_failed)a

  defguardp count?(value) when is_integer(value) and value >= 0
  defguardp count_or_nil?(value) when is_nil(value) or count?(value)
  # The bounds of Core that the fold trusts: a token count of a compaction
  # (`Helyx.Session.Stream`). The total cost of a session is a sum of costs
  # of at most 10^12 each, so it has no bound of its own below the float
  # limit (usage-and-limits.md, "session totals"); 10^300 is far above any
  # sum, and leaves the footer room for its `cost * 10_000`.
  defguardp tokens_or_nil?(value) when is_nil(value) or wire_tokens?(value)

  defguardp cost_or_nil?(value)
            when is_nil(value) or (is_number(value) and value >= 0 and value <= 1.0e300)

  @spec event(term()) :: {:ok, Event.t() | nil} | :error
  def event(value), do: decoded(fn -> event!(value) end)

  # The result of a request of `op`: `{:ok, result}` as the operation of
  # Core gives it, or `{:error, code}`, with `{code, text}` for the codes
  # of `@texts`.
  @spec result(String.t(), term()) :: {:ok, term()} | :error
  def result(op, value), do: decoded(fn -> result!(op, value) end)

  defp decoded(fun) do
    {:ok, fun.()}
  rescue
    _broken -> :error
  end

  defp result!(_op, %{"ok" => false, "error" => %{"code" => code, "text" => text}})
       when is_binary(text) do
    code = Map.fetch!(@codes, code)
    {:error, if(code in @texts, do: {code, text}, else: code)}
  end

  defp result!(op, %{"ok" => true, "result" => %{} = result}), do: ok(op, result)

  defp ok("subscribe", %{"sub" => sub, "snapshot" => snapshot}) when is_binary(sub),
    do: {:ok, snapshot!(snapshot), sub}

  defp ok("subscribe", %{"sub" => sub, "replay" => events}) when is_binary(sub),
    do: {:ok, {:replay, events |> Enum.map(&event!/1) |> Enum.reject(&is_nil/1)}, sub}

  defp ok(op, %{"session" => id}) when op in ["start", "resume"] and is_binary(id), do: {:ok, id}

  defp ok("sessions.saved", %{"items" => items, "next" => next})
       when is_binary(next) or is_nil(next),
       do: {:ok, Enum.map(items, &saved/1), next}

  defp ok(op, _empty) when op not in ["subscribe", "start", "resume", "sessions.saved"], do: :ok

  defp saved(%{"id" => id, "cwd" => cwd, "model" => model, "mtime" => mtime, "prompt" => prompt})
       when is_binary(id) and is_binary(cwd) and is_binary(model) and count?(mtime) and
              is_binary(prompt),
       do: %Scan.Summary{id: id, cwd: cwd, model: model, mtime: mtime, prompt: prompt}

  defp event!(%{
         "type" => type,
         "session_id" => session_id,
         "instance_id" => instance_id,
         "turn_id" => turn_id,
         "seq" => seq,
         "data" => %{} = data
       })
       when is_binary(session_id) and is_binary(instance_id) and
              (is_binary(turn_id) or is_nil(turn_id)) and count?(seq) do
    case Map.fetch(@types, type) do
      {:ok, type} ->
        %Event{
          type: type,
          session_id: session_id,
          instance_id: instance_id,
          turn_id: turn_id,
          seq: seq,
          data: data(type, data)
        }

      :error ->
        nil
    end
  end

  defp data(:turn_start, data), do: turn_origin(data["origin"])

  defp data(:message_start, %{"message" => message}), do: %{message: message!(message)}

  # The roles that the fold takes for each event.
  defp data(:tool_execution_end, %{"message" => message}),
    do: %{message: message!(message, :tool_result)}

  # One delta key, as Core sends it.
  defp data(:message_update, data) do
    case Map.take(data, ["text_delta", "thinking_delta", "tool_call"]) do
      %{"text_delta" => delta} = one when map_size(one) == 1 and is_binary(delta) ->
        %{text_delta: delta}

      %{"thinking_delta" => delta} = one when map_size(one) == 1 and is_binary(delta) ->
        %{thinking_delta: delta}

      %{"tool_call" => call} = one when map_size(one) == 1 ->
        %{tool_call: tool_call(call)}
    end
  end

  defp data(:message_end, %{"message" => message} = data),
    do: Map.merge(%{message: message!(message)}, message_error(data["error"]))

  defp data(:turn_end, %{"outcome" => "done"}), do: %{outcome: :done}
  defp data(:turn_end, %{"outcome" => "aborted"}), do: %{outcome: :aborted}

  defp data(:turn_end, %{"outcome" => "error", "error" => error}) when is_binary(error),
    do: %{outcome: :error, error: error}

  defp data(:queue_update, data), do: queue(data)

  # The wire leaves out the texts; the messages carry them.
  defp data(:queue_dropped, %{"messages" => messages}) when is_list(messages) do
    messages = Enum.map(messages, &message!(&1, :user))
    %{messages: messages, texts: Enum.map(messages, &Message.text/1)}
  end

  defp data(:steer_unconfirmed, %{"message" => message}) do
    message = message!(message, :user)
    %{message: message, text: Message.text(message)}
  end

  defp data(:model_change, %{"model" => model}), do: %{model: model!(model)}

  defp data(:resume_id, %{"provider" => provider, "resume_id" => id, "lost" => lost, "cut" => cut})
       when is_binary(provider) and is_binary(id) and is_boolean(lost) and count?(cut),
       do: %{provider: provider, resume_id: id, lost: lost, cut: cut}

  defp data(:compaction, %{
         "trigger" => trigger,
         "tokens_before" => before,
         "tokens_after" => after_
       })
       when trigger in ["manual", "auto"] and tokens_or_nil?(before) and tokens_or_nil?(after_),
       do: %{trigger: trigger(trigger), tokens_before: before, tokens_after: after_}

  defp data(:notice, %{"text" => text}) when is_binary(text), do: %{text: text}
  defp data(:ask, data), do: ask(data)

  defp data(:ask_end, %{"ask_id" => id, "outcome" => outcome}) when is_binary(id),
    do: %{ask_id: id, outcome: ask_outcome(outcome)}

  defp turn_origin(nil), do: %{}
  defp turn_origin("provider"), do: %{origin: :provider}
  defp turn_origin("compaction"), do: %{origin: :compaction}

  defp message_error(nil), do: %{}
  defp message_error(%{"kind" => "aborted"}), do: %{error: :aborted}

  defp message_error(%{"kind" => "failed", "text" => text}) when is_binary(text),
    do: %{error: text}

  defp trigger("manual"), do: :manual
  defp trigger("auto"), do: :auto

  defp ask_outcome("answered"), do: :answered
  defp ask_outcome("ended"), do: :ended

  defp ask(%{
         "ask_id" => ask_id,
         "call_id" => call_id,
         "tool" => tool,
         "request" => %{} = request
       })
       when is_binary(ask_id) and is_binary(call_id) and is_binary(tool),
       do: %{ask_id: ask_id, call_id: call_id, tool: tool, request: request}

  defp queue(%{
         "steers" => steers,
         "follow_ups" => follow_ups,
         "running" => running,
         "held" => held,
         "waiting" => waiting
       })
       when count?(steers) and count?(follow_ups) and count?(running) and count?(held) and
              count?(waiting),
       do: %{
         steers: steers,
         follow_ups: follow_ups,
         running: running,
         held: held,
         waiting: waiting
       }

  defp tool_call(%{"type" => "tool_call", "id" => id, "name" => name, "arguments" => %{} = args})
       when is_binary(id) and is_binary(name),
       do: %Message.ToolCall{id: id, name: name, arguments: Message.cap_integers(args)}

  # A user message of a file from before #649 has the origin `unknown` on
  # the wire; the session file has no origin for it.
  defp message!(%{"id" => id, "origin" => %{"kind" => "unknown", "id" => nil}} = message)
       when is_binary(id),
       do: message |> Map.delete("origin") |> Codec.decode()

  defp message!(%{"id" => id} = message) when is_binary(id), do: Codec.decode(message)

  # A tool result has the call id that the fold pairs it by.
  defp message!(value, :tool_result) do
    %Message{role: :tool_result, tool_call_id: id} = message = message!(value)
    true = is_binary(id)
    message
  end

  defp message!(value, role) do
    %Message{role: ^role} = message = message!(value)
    message
  end

  # A model ref as Core checks it (`Helyx.ModelRef.parse/1`).
  defp model!(model) do
    {:ok, _ref} = ModelRef.parse(model)
    model
  end

  defp snapshot!(%{
         "instance_id" => instance_id,
         "seq" => seq,
         "messages" => messages,
         "more" => more,
         "turn" => turn,
         "model" => model,
         "queue" => queue,
         "persisting" => persisting,
         "usage" => usage,
         "context" => context,
         "asks" => asks
       })
       when is_binary(instance_id) and count?(seq) and is_boolean(more) and is_boolean(persisting) do
    snapshot = %Snapshot{
      instance_id: instance_id,
      seq: seq,
      messages: Enum.map(messages, &message!/1),
      more: more,
      turn: turn(turn),
      model: model!(model),
      queue: queue(queue),
      persisting: persisting,
      usage: totals(usage),
      context: context(context),
      asks: Enum.map(asks, &ask/1)
    }

    # The fold pairs each tool result with an earlier call; a snapshot that
    # it cannot take raises here, not in the owner.
    ViewModel.from_snapshot(snapshot)
    snapshot
  end

  defp turn(nil), do: nil

  defp turn(%{"id" => id, "partial" => partial, "elapsed_ms" => elapsed})
       when is_binary(id) and count?(elapsed),
       do: %{id: id, partial: partial(partial), elapsed_ms: elapsed}

  defp partial(nil), do: nil
  defp partial(message), do: message!(message, :assistant)

  defp totals(%{
         "input" => input,
         "output" => output,
         "cache_read" => cache_read,
         "cache_write" => cache_write,
         "cost" => cost,
         "unknown" => unknown,
         "list" => list
       })
       when count?(input) and count?(output) and count?(cache_read) and count?(cache_write) and
              cost_or_nil?(cost) and is_boolean(unknown) and is_boolean(list) do
    %Totals{
      input: input,
      output: output,
      cache_read: cache_read,
      cache_write: cache_write,
      cost: cost,
      unknown: unknown,
      list: list
    }
  end

  defp context(nil), do: nil

  defp context(%{"tokens" => tokens, "window" => window, "model" => model, "bytes" => bytes})
       when count_or_nil?(tokens) and (is_nil(window) or (is_integer(window) and window > 0)) and
              (is_nil(model) or is_binary(model)) and count?(bytes),
       do: %{tokens: tokens, window: window, model: model, bytes: bytes}
end
