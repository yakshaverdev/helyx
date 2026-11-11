defmodule Helyx.TUI.Wire.Decode do
  @moduledoc false
  # The JSON values of the server as the Core values that `Helyx.TUI.ViewModel` folds
  # (`docs/features/wire-protocol.md`, "Codec"). Each is checked strictly against the schema
  # before it becomes a Core value (`docs/features/tui-attach.md`, decision 14); the tolerant
  # decoder of the session file is not used. A key that it does not know is ignored, and an event
  # of a type that it does not know is nil. A known value with a broken shape raises, and each
  # public function gives `:error` for it: the connection ends on a contract break.

  alias Helyx.{Event, Message, Usage}
  alias Helyx.Session.File.Scan
  alias Helyx.Session.{Snapshot, Totals}
  alias Helyx.TUI.ViewModel
  alias Helyx.TUI.Wire.UIBlocks

  @event_types ~w(turn_start message_start message_update message_end tool_execution_end
                  turn_end queue_update queue_dropped model_change resume_id
                  steer_unconfirmed compaction notice ask ask_end ui_block tools_change)a
  @types Map.new(@event_types, &{Atom.to_string(&1), &1})

  @codes Map.new(Helyx.Transport.WebSocket.Bounds.error_codes(), &{Atom.to_string(&1), &1})
  # The codes whose text names the value: the TUI shows it.
  @texts ~w(invalid_model_ref unknown_provider start_failed)a

  @stop_reasons Map.new(Message.stop_reasons(), &{Atom.to_string(&1), &1})
  @usage_keys Map.keys(%Usage{}) -- [:__struct__]

  defguardp count?(value) when is_integer(value) and value >= 0
  defguardp count_or_nil?(value) when is_nil(value) or count?(value)
  defguardp cost_or_nil?(value) when is_nil(value) or (is_number(value) and value >= 0)
  # A cost of the totals over 10^300 counts as 10^300: the footer shows `>$99999` for both, and
  # adding a message cost of at most 10^12 to it stays in the float range (usage-and-limits.md,
  # "session totals").
  @max_total_cost 1.0e300

  @spec event(term()) :: {:ok, Event.t() | nil} | :error
  def event(value), do: decoded(fn -> event!(value) end)

  # The result of a request of `op`: `{:ok, result}` as the operation of Core gives it, or
  # `{:error, code}`, with `{code, text}` for the codes of `@texts`.
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

  defp ok("subscribe", %{"sub" => sub, "replay" => events})
       when is_binary(sub) and is_list(events),
       do: {:ok, {:replay, events |> Enum.map(&event!/1) |> Enum.reject(&is_nil/1)}, sub}

  defp ok(op, %{"session" => id}) when op in ["start", "resume"] and is_binary(id), do: {:ok, id}

  defp ok("sessions.saved", %{"items" => items, "next" => next})
       when is_list(items) and (is_binary(next) or is_nil(next)),
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

  # A text for a person that becomes a notice gets the cut of the error text of a failed turn,
  # 4,000 bytes (`Helyx.Reason.text/1`, coding-agent.md), once.
  defp data(:turn_end, %{"outcome" => "error", "error" => error}) when is_binary(error),
    do: %{outcome: :error, error: Helyx.Reason.text(error)}

  defp data(:queue_update, data), do: queue(data)

  defp data(:queue_dropped, %{"messages" => messages}) when is_list(messages),
    do: %{messages: Enum.map(messages, &message!(&1, :user))}

  defp data(:steer_unconfirmed, %{"message" => message}), do: %{message: message!(message, :user)}

  defp data(:model_change, %{"model" => model}), do: %{model: model!(model)}
  defp data(:tools_change, %{"activated" => names}), do: %{activated: activated!(names)}

  defp data(:resume_id, %{"provider" => provider, "resume_id" => id, "lost" => lost, "cut" => cut})
       when is_binary(provider) and is_binary(id) and is_boolean(lost) and count?(cut),
       do: %{provider: Helyx.Reason.text(provider), resume_id: id, lost: lost, cut: cut}

  defp data(:compaction, %{
         "trigger" => trigger,
         "tokens_before" => before,
         "tokens_after" => after_
       })
       when trigger in ["manual", "auto"] and count_or_nil?(before) and count_or_nil?(after_),
       do: %{trigger: trigger(trigger), tokens_before: before, tokens_after: after_}

  defp data(:notice, %{"text" => text}) when is_binary(text), do: %{text: Helyx.Reason.text(text)}
  defp data(:ask, data), do: ask(data)

  defp data(:ask_end, %{"ask_id" => id, "outcome" => outcome}) when is_binary(id),
    do: %{ask_id: id, outcome: ask_outcome(outcome)}

  defp data(:ui_block, data), do: UIBlocks.shown!(data)

  defp turn_origin(nil), do: %{}
  defp turn_origin("provider"), do: %{origin: :provider}
  defp turn_origin("compaction"), do: %{origin: :compaction}

  defp message_error(nil), do: %{}
  defp message_error(%{"kind" => "aborted"}), do: %{error: :aborted}

  defp message_error(%{"kind" => "failed", "text" => text}) when is_binary(text),
    do: %{error: Helyx.Reason.text(text)}

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
       do: %{ask_id: ask_id, call_id: call_id, tool: tool, request: UIBlocks.request!(request)}

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

  # An integer of any size: the call line shows it as its text, cut with the line
  # (`Helyx.TUI.CallLine`).
  defp tool_call(%{"type" => "tool_call", "id" => id, "name" => name, "arguments" => %{} = args})
       when is_binary(id) and is_binary(name),
       do: %Message.ToolCall{id: id, name: name, arguments: args}

  # Any count of blocks: a cell keeps the first 1,024 and a cut of the others
  # (`Helyx.TUI.ViewModel.Cut`).
  defp message!(%{"id" => id, "role" => role, "content" => content} = message)
       when is_binary(id) and is_list(content) do
    role = role!(role)

    %Message{
      role: role,
      id: id,
      origin: origin!(role, message["origin"]),
      content: Enum.map(content, &block!(&1, role)),
      model: optional!(message["model"]),
      stop_reason: stop_reason!(message["stop_reason"]),
      tool_call_id: optional!(message["tool_call_id"]),
      tool_name: optional!(message["tool_name"]),
      is_error: flag!(message["is_error"]),
      usage: usage!(message["usage"]),
      ui_blocks: UIBlocks.message!(role, message["ui_blocks"])
    }
  end

  defp message!(value, role) do
    %Message{role: ^role} = message = message!(value)
    message
  end

  defp role!(role) when role in ~w(user assistant tool_result), do: String.to_existing_atom(role)

  # An origin of the schema. A user message keeps one that Core makes, so it decodes as Core holds
  # it; any other is dropped, as the TUI shows no
  # origin.
  defp origin!(_role, nil), do: nil

  defp origin!(role, %{"kind" => kind, "id" => id}) when is_binary(id) or is_nil(id) do
    origin = %{kind: origin_kind!(kind), id: id}
    if role == :user and Message.origin?(origin), do: origin
  end

  defp origin_kind!(kind) when kind in ~w(user background product hook),
    do: String.to_existing_atom(kind)

  # A text of a tool result gets the cut of Core at each boundary of tool text
  # (`Helyx.Message.cut_result/1`), once, so no frame draws more.
  defp block!(%{"type" => "text", "text" => text}, :tool_result) when is_binary(text),
    do: %Message.Text{text: Message.cut_result(text)}

  defp block!(%{"type" => "text", "text" => text}, _role) when is_binary(text),
    do: %Message.Text{text: text}

  defp block!(%{"type" => "thinking", "thinking" => thinking}, _role) when is_binary(thinking),
    do: %Message.Thinking{thinking: thinking}

  defp block!(call, _role), do: tool_call(call)

  defp optional!(nil), do: nil
  defp optional!(value) when is_binary(value), do: value

  defp stop_reason!(nil), do: nil
  defp stop_reason!(reason), do: Map.fetch!(@stop_reasons, reason)

  defp flag!(nil), do: false
  defp flag!(value) when is_boolean(value), do: value

  # The known keys of a usage, checked by the schema. A usage that Core would not make
  # (`Helyx.Usage.valid?/1`) is the unknown usage `%Usage{}`, the usage of a message whose
  # accounting is missing.
  defp usage!(nil), do: nil

  defp usage!(%{} = object) do
    fields = for key <- @usage_keys, do: {key, object[Atom.to_string(key)]}
    usage = struct!(Usage, Keyword.put(fields, :cost_kind, cost_kind!(object["cost_kind"])))
    counts = [usage.input, usage.output, usage.cache_read, usage.cache_write]

    true =
      Enum.all?(counts, &count?(&1)) and count_or_nil?(usage.context_tokens) and
        count_or_nil?(usage.context_window) and cost_or_nil?(usage.cost)

    if Usage.valid?(usage), do: usage, else: %Usage{}
  end

  defp cost_kind!(kind) when kind in [nil, "list", "billed"],
    do: kind && String.to_existing_atom(kind)

  defp activated!(names) when is_list(names), do: Enum.map(names, &(<<_::binary>> = &1))

  # Any string: the footer and a model change line draw it cut and cleaned (`Helyx.TUI.Footer`).
  defp model!(model) when is_binary(model), do: model

  defp snapshot!(
         %{
           "instance_id" => instance_id,
           "seq" => seq,
           "messages" => messages,
           "turn" => turn,
           "model" => model,
           "queue" => queue,
           "persisting" => persisting,
           "usage" => usage,
           "context" => context,
           "asks" => asks,
           "ui_blocks" => ui_blocks,
           "activated" => activated
         } = wire
       )
       when is_binary(instance_id) and count?(seq) and is_list(messages) and
              is_boolean(persisting) and is_list(asks) and is_list(ui_blocks) do
    older = Map.fetch!(wire, "older")
    true = count?(older)

    snapshot = %Snapshot{
      instance_id: instance_id,
      seq: seq,
      messages: Enum.map(messages, &message!/1),
      older: older,
      turn: turn(turn),
      model: model!(model),
      queue: queue(queue),
      persisting: persisting,
      usage: totals(usage),
      context: context(context),
      asks: Enum.map(asks, &ask/1),
      ui_blocks: Enum.map(ui_blocks, &UIBlocks.shown!/1),
      activated: activated!(activated)
    }

    # A snapshot that the fold cannot take raises here, not in the owner.
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
      cost: cost && min(cost, @max_total_cost),
      unknown: unknown,
      list: list
    }
  end

  defp context(nil), do: nil

  # A window of 0 is no window: the footer shows no context % for it.
  defp context(%{"tokens" => tokens, "window" => window, "model" => model, "bytes" => bytes})
       when count_or_nil?(tokens) and count_or_nil?(window) and
              (is_nil(model) or is_binary(model)) and count?(bytes),
       do: %{tokens: tokens, window: if(window != 0, do: window), model: model, bytes: bytes}
end
