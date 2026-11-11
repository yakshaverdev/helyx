defmodule Helyx.Session.Hands.Term.Hands do
  @moduledoc false
  # The terms that the hands send to the session for the work of a session: the
  # result of a call, the end of a background run, the record and the go of a
  # Task, an ask, a UI block, a transcript, an end of a Task, the answers of a
  # hook chain, and a hook answer. The provider process terms are in
  # `Helyx.Session.Hands.Term.Hands.Provider`.

  alias Helyx.{Message, UIBlock}
  alias Helyx.Session.Hands.Term.{Data, Record}
  alias Helyx.Session.Input

  @kinds [
    result: "hands.result",
    background_end: "hands.background_end",
    asker: "hands.asker",
    ask: "hands.ask",
    show: "hands.show",
    task_down: "hands.task_down",
    transcript: "hands.transcript",
    settle_answer: "hands.settle_answer",
    approval_result: "hands.approval_result",
    hook_answer: "hands.hook_answer"
  ]

  @doc false
  def kinds, do: @kinds

  @doc false
  def direction(_tag), do: :hands_to_session

  def check(
        %{
          t: :result,
          instance: instance,
          turn: turn,
          call: call,
          status: status,
          text: text,
          ui_blocks: ui_blocks,
          started: started,
          task: task
        } = term
      ) do
    with true <- map_size(term) == 9,
         true <- Data.id?(instance),
         true <- Data.turn_id?(turn),
         true <- Data.call_id?(call),
         true <- status in [:ok, :error],
         true <- Data.text?(text),
         {:ok, blocks} <- Data.blocks(ui_blocks),
         true <- is_boolean(started),
         true <- task?(started, task) do
      {:ok, %{term | text: Message.cut_result(text), ui_blocks: blocks}}
    else
      _ -> :error
    end
  end

  def check(%{t: :background_end, instance: instance, id: id, message: message} = term) do
    if map_size(term) == 4 and Data.id?(instance) and Data.id?(id) and Data.message?(message),
      do: {:ok, term},
      else: :error
  end

  def check(%{t: :asker, instance: instance, turn: turn, task: task, asker: asker} = term) do
    if map_size(term) == 5 and Data.id?(instance) and Data.turn_id?(turn) and Data.id?(task) and
         Data.asker?(asker),
       do: {:ok, term},
       else: :error
  end

  def check(%{t: :ask, instance: instance, task: task, tool: tool, request: request} = term) do
    if map_size(term) == 5 and Data.id?(instance) and Data.id?(task) and Data.text?(tool) and
         Data.ask_request?(request),
       do: {:ok, term},
       else: :error
  end

  def check(
        %{t: :show, instance: instance, task: task, call: call, key: key, block: block} = term
      ) do
    with true <- map_size(term) == 6,
         true <- Data.id?(instance),
         true <- Data.id?(task),
         true <- Data.call_id?(call),
         true <- UIBlock.key?(key),
         {:ok, block} <- UIBlock.check(block) do
      {:ok, %{term | block: block}}
    else
      _ -> :error
    end
  end

  def check(%{t: kind, instance: instance, task: task} = term)
      when kind in [:task_down, :transcript] do
    if map_size(term) == 3 and Data.id?(instance) and Data.id?(task),
      do: {:ok, term},
      else: :error
  end

  def check(%{t: :settle_answer, instance: instance, ref: ref, answer: answer} = term) do
    if map_size(term) == 4 and Data.id?(instance) and Data.id?(ref) and settle_answer?(answer),
      do: {:ok, term},
      else: :error
  end

  def check(
        %{t: :approval_result, instance: instance, turn: turn, call: call, decision: decision} =
          term
      ) do
    if map_size(term) == 5 and Data.id?(instance) and Data.turn_id?(turn) and Data.call_id?(call) and
         decision?(decision),
       do: {:ok, term},
       else: :error
  end

  def check(%{t: :hook_answer, instance: instance, turn: turn, record: record} = term) do
    if map_size(term) == 4 and Data.id?(instance) and Data.turn_id?(turn) and
         Record.record?(record),
       do: {:ok, term},
       else: :error
  end

  def check(_term), do: :error

  defp task?(true, task), do: Data.id?(task)
  defp task?(false, task), do: is_nil(task)

  defp settle_answer?(:settle), do: true

  defp settle_answer?({:continue, hook, text}),
    do: Data.plugin?(hook) and is_binary(text) and Input.text(text) == :ok

  defp settle_answer?(_answer), do: false

  defp decision?(:allow), do: true
  defp decision?({:deny, reason}), do: Data.reason?(reason)
  defp decision?(_decision), do: false

  # --- the JSON map of each term ---

  @doc false
  def encode(%{t: :result} = term) do
    {:ok,
     %{
       "t" => "hands.result",
       "instance" => term.instance,
       "turn" => term.turn,
       "call" => term.call,
       "status" => Atom.to_string(term.status),
       "text" => term.text,
       "ui_blocks" => term.ui_blocks,
       "started" => term.started,
       "task" => term.task
     }}
  end

  def encode(%{t: :background_end} = term) do
    {:ok,
     %{
       "t" => "hands.background_end",
       "instance" => term.instance,
       "id" => term.id,
       "message" => Data.message_to_map(term.message)
     }}
  end

  def encode(%{t: :asker} = term) do
    {:ok,
     %{
       "t" => "hands.asker",
       "instance" => term.instance,
       "turn" => term.turn,
       "task" => term.task,
       "asker" => Data.asker_to_map(term.asker)
     }}
  end

  def encode(%{t: :ask} = term) do
    {:ok,
     %{
       "t" => "hands.ask",
       "instance" => term.instance,
       "task" => term.task,
       "tool" => term.tool,
       "request" => term.request
     }}
  end

  def encode(%{t: :show} = term) do
    {:ok,
     %{
       "t" => "hands.show",
       "instance" => term.instance,
       "task" => term.task,
       "call" => term.call,
       "key" => term.key,
       "block" => term.block
     }}
  end

  def encode(%{t: kind} = term) when kind in [:task_down, :transcript] do
    {:ok, %{"t" => name(kind), "instance" => term.instance, "task" => term.task}}
  end

  def encode(%{t: :settle_answer} = term) do
    {:ok,
     %{
       "t" => "hands.settle_answer",
       "instance" => term.instance,
       "ref" => term.ref,
       "answer" => settle_answer_to_map(term.answer)
     }}
  end

  def encode(%{t: :approval_result} = term) do
    {:ok,
     %{
       "t" => "hands.approval_result",
       "instance" => term.instance,
       "turn" => term.turn,
       "call" => term.call,
       "decision" => decision_to_map(term.decision)
     }}
  end

  def encode(%{t: :hook_answer} = term) do
    {:ok,
     %{
       "t" => "hands.hook_answer",
       "instance" => term.instance,
       "turn" => term.turn,
       "record" => Record.record_to_map(term.record)
     }}
  end

  defp name(kind), do: kind |> Atom.to_string() |> then(&"hands.#{&1}")

  defp settle_answer_to_map(:settle), do: %{"kind" => "settle"}

  defp settle_answer_to_map({:continue, hook, text}),
    do: %{"kind" => "continue", "hook" => hook, "text" => text}

  defp decision_to_map(:allow), do: %{"kind" => "allow"}

  defp decision_to_map({:deny, reason}), do: %{"kind" => "deny", "text" => reason}

  # --- the term of a JSON map ---

  @doc false
  def decode(%{"t" => "hands.result"} = map) do
    Data.decode_fields(map, ~w(instance turn call status text ui_blocks started task), fn
      [instance, turn, call, status, text, blocks, started, task] ->
        with {:ok, status} <- status(status) do
          check(%{
            t: :result,
            instance: instance,
            turn: turn,
            call: call,
            status: status,
            text: text,
            ui_blocks: blocks,
            started: started,
            task: task
          })
        end
    end)
  end

  def decode(%{"t" => "hands.background_end"} = map) do
    Data.decode_fields(map, ~w(instance id message), fn [instance, id, message] ->
      with {:ok, message} <- Data.to_message(message) do
        check(%{t: :background_end, instance: instance, id: id, message: message})
      end
    end)
  end

  def decode(%{"t" => "hands.asker"} = map) do
    Data.decode_fields(map, ~w(instance turn task asker), fn [instance, turn, task, asker] ->
      with {:ok, asker} <- Data.to_asker(asker) do
        check(%{t: :asker, instance: instance, turn: turn, task: task, asker: asker})
      end
    end)
  end

  def decode(%{"t" => "hands.ask"} = map) do
    Data.decode_fields(map, ~w(instance task tool request), fn [instance, task, tool, request] ->
      check(%{t: :ask, instance: instance, task: task, tool: tool, request: request})
    end)
  end

  def decode(%{"t" => "hands.show"} = map) do
    Data.decode_fields(map, ~w(instance task call key block), fn
      [instance, task, call, key, block] ->
        check(%{t: :show, instance: instance, task: task, call: call, key: key, block: block})
    end)
  end

  def decode(%{"t" => kind} = map) when kind in ["hands.task_down", "hands.transcript"] do
    Data.decode_fields(map, ~w(instance task), fn [instance, task] ->
      check(%{t: kind(kind), instance: instance, task: task})
    end)
  end

  def decode(%{"t" => "hands.settle_answer"} = map) do
    Data.decode_fields(map, ~w(instance ref answer), fn [instance, ref, answer] ->
      with {:ok, answer} <- to_settle_answer(answer) do
        check(%{t: :settle_answer, instance: instance, ref: ref, answer: answer})
      end
    end)
  end

  def decode(%{"t" => "hands.approval_result"} = map) do
    Data.decode_fields(map, ~w(instance turn call decision), fn
      [instance, turn, call, decision] ->
        with {:ok, decision} <- to_decision(decision) do
          check(%{
            t: :approval_result,
            instance: instance,
            turn: turn,
            call: call,
            decision: decision
          })
        end
    end)
  end

  def decode(%{"t" => "hands.hook_answer"} = map) do
    Data.decode_fields(map, ~w(instance turn record), fn [instance, turn, record] ->
      with {:ok, record} <- Record.to_record(record) do
        check(%{t: :hook_answer, instance: instance, turn: turn, record: record})
      end
    end)
  end

  def decode(_map), do: :error

  defp status("ok"), do: {:ok, :ok}
  defp status("error"), do: {:ok, :error}
  defp status(_status), do: :error

  defp kind("hands.task_down"), do: :task_down
  defp kind("hands.transcript"), do: :transcript

  defp to_settle_answer(%{"kind" => "settle"} = map) when map_size(map) == 1, do: {:ok, :settle}

  defp to_settle_answer(%{"kind" => "continue", "hook" => hook, "text" => text} = map)
       when map_size(map) == 3,
       do: {:ok, {:continue, hook, text}}

  defp to_settle_answer(_answer), do: :error

  defp to_decision(%{"kind" => "allow"} = map) when map_size(map) == 1, do: {:ok, :allow}

  defp to_decision(%{"kind" => "deny", "text" => text} = map) when map_size(map) == 2,
    do: {:ok, {:deny, text}}

  defp to_decision(_decision), do: :error
end
