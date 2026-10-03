defmodule Helyx.TUI.ViewModel do
  @moduledoc """
  The TUI's view of a session: a pure fold over `Helyx.Event`.

  The TUI holds no session state of its own. Every event goes through
  `apply/2` and the screen renders from the result, so the fold is testable
  with scripted event lists.

  `cells` is the transcript, oldest first. A cell is one of:

    * `%Helyx.Message{}` – a completed user or assistant message
    * `{:tool, call, line, result}` – a tool call of the assistant message
      before it, and its line (`call_line/1`), made with the cell, so a
      frame does not pay for the size of the call; `result` is nil until
      the tool result message comes. The cell comes from the message, not
      from `tool_execution_start`: the message proves that the call exists,
      not that it runs, so an open cell shows "awaiting result"
    * `{:notice, text}` – an aborted or failed turn, a provider that lost
      its session or got a cut transcript, a steer that was not confirmed, a
      notice of the session, or a command the client rejected
      (`notice/2`)

  `reason` is why the client rejected the last input, or nil. It is
  client-local, like a notice: `reject/2` sets it and `clear_reason/1`
  clears it on the next key press or paste. A new reject replaces it. No event changes it.

  `streaming` is the open assistant message as a reversed block list, newest
  first, or nil when none is streaming. Text and thinking deltas join it
  through `Helyx.Message.add_block/2`, the session's convention. Each tool
  call of it is an open tool cell, so a frame does not make its line; the
  `message_end` makes the cells of the message again from the message.

  `instance_id` is the session instance of the view model. `apply/2` drops
  an event of another instance: a resume keeps the session id and starts
  `seq` at 0 again, and two Cores can hold one session id (#204).

  `seq` is the seq of the last event in the view model: `apply/2` drops an
  event at or below it, so an event that `from_snapshot/1` already holds
  does not show twice.
  """

  alias Helyx.{Event, Message}
  alias Helyx.Session.Snapshot

  # The cut of an error notice or a tool call line (`cut_line/1`).
  @render_max_bytes 8_192

  defstruct model: nil,
            instance_id: nil,
            seq: 0,
            cells: [],
            streaming: nil,
            running?: false,
            queue: %{steers: 0, follow_ups: 0},
            reason: nil

  @type tool_cell :: {:tool, Message.ToolCall.t(), String.t(), Message.t() | nil}
  @type cell :: Message.t() | tool_cell() | {:notice, String.t()}

  @type t :: %__MODULE__{
          model: String.t(),
          instance_id: String.t() | nil,
          seq: non_neg_integer(),
          cells: [cell()],
          streaming: [Message.Text.t() | Message.Thinking.t() | tool_cell()] | nil,
          running?: boolean(),
          queue: %{steers: non_neg_integer(), follow_ups: non_neg_integer()},
          reason: String.t() | nil
        }

  @doc "A view model on `model` with no instance: it drops every event. For render tests."
  @spec new(String.t()) :: t()
  def new(model), do: %__MODULE__{model: model}

  # The event types that this client knows: one entry for each type that
  # `fold/2` has a clause for. A type that is not here is dropped.
  @known_types [
    :agent_start,
    :agent_end,
    :turn_start,
    :turn_end,
    :message_start,
    :message_update,
    :message_end,
    :tool_execution_start,
    :tool_execution_end,
    :queue_update,
    :model_change,
    :provider_session,
    :steer_unconfirmed,
    :notice
  ]

  @delta_keys [:text_delta, :thinking_delta, :tool_call]

  @doc """
  Folds one event into the view model. A client ignores what it does not
  know (ADR 0006, section 5), so a newer Core does not crash the TUI:

    * an event of an unknown type leaves the view model unchanged, `seq`
      included
    * a `message_update` with no delta key that the TUI knows (an empty data
      map included: it has the shape of a new delta kind), and a
      `message_start` or `message_end` whose message has a role that the TUI
      does not show, are ignored
    * a delta with no open assistant message, such as one of a message of a
      new role, is dropped
    * a block kind that the TUI does not render is dropped from an assistant
      message before the message becomes a cell

  For the other ignored events only `seq` moves. A known type with a missing
  required field, such as a `message_start` with no message, is a bug in
  Core and crashes the TUI. So do a `message_update` with a delta key that
  the TUI knows and a value of another type, a `message_update` with two
  such keys, and a block of an assistant message that is not a struct.

  An event of another session instance also leaves the view model
  unchanged, whatever its `seq` (ADR 0006, section 3).
  """
  @spec apply(t(), Event.t()) :: t()
  def apply(%__MODULE__{instance_id: id} = vm, %Event{instance_id: other}) when other != id,
    do: vm

  def apply(%__MODULE__{seq: seq} = vm, %Event{seq: event_seq}) when event_seq <= seq, do: vm
  def apply(vm, %Event{type: type}) when type not in @known_types, do: vm
  def apply(vm, %Event{seq: seq} = event), do: fold(%{vm | seq: seq}, event)

  defp fold(vm, %Event{type: :agent_start}), do: %{vm | running?: true}

  defp fold(vm, %Event{type: :agent_end, data: data}) do
    vm = %{vm | running?: false, streaming: nil}

    case data do
      %{stop_reason: :aborted} ->
        add_cell(vm, {:notice, "aborted"})

      %{stop_reason: :error, error: error} ->
        add_cell(vm, {:notice, "error: " <> error_text(error)})

      %{stop_reason: other} when other != :error ->
        vm
    end
  end

  # The TUI shows a turn and its tool calls only through its messages, and
  # a user message when it ends.
  defp fold(vm, %Event{type: type}) when type in [:turn_start, :turn_end, :tool_execution_start],
    do: vm

  defp fold(vm, %Event{type: :message_start, data: %{message: %Message{role: :assistant}}}) do
    %{vm | streaming: []}
  end

  defp fold(vm, %Event{type: :message_start, data: %{message: %Message{}}}), do: vm

  # Core sends one delta key for each update. An update with no known key
  # has a delta kind from a newer Core, so it is ignored; a known key with
  # another value, or two known keys, is a bug in Core and crashes.
  defp fold(vm, %Event{type: :message_update, data: data}) do
    case Map.to_list(Map.take(data, @delta_keys)) do
      [] -> vm
      [{:text_delta, delta}] when is_binary(delta) -> stream(vm, {:text_delta, delta})
      [{:thinking_delta, delta}] when is_binary(delta) -> stream(vm, {:thinking_delta, delta})
      [{:tool_call, %Message.ToolCall{} = call}] -> stream(vm, {:tool_call, call})
    end
  end

  defp fold(vm, %Event{type: :message_end, data: %{message: %Message{role: :user} = message}}) do
    add_cell(vm, message)
  end

  # Each call of the message gets an open cell; its result comes later.
  defp fold(vm, %Event{type: :message_end, data: %{message: %Message{role: :assistant} = message}}) do
    cells = [
      rendered_blocks(message) | for(call <- tool_calls(message), do: tool_cell(call, nil))
    ]

    %{vm | streaming: nil, cells: vm.cells ++ cells}
  end

  defp fold(vm, %Event{type: :message_end, data: %{message: %Message{}}}), do: vm

  defp fold(vm, %Event{
         type: :tool_execution_end,
         data: %{message: %Message{role: :tool_result} = result}
       }) do
    %{vm | cells: attach_result(vm.cells, result)}
  end

  defp fold(vm, %Event{type: :queue_update, data: %{steers: steers, follow_ups: follow_ups}}) do
    %{vm | queue: %{steers: steers, follow_ups: follow_ups}}
  end

  defp fold(vm, %Event{type: :model_change, data: %{model: model}}), do: %{vm | model: model}

  defp fold(vm, %Event{type: :notice, data: %{text: text}}), do: add_cell(vm, {:notice, text})

  defp fold(vm, %Event{type: :steer_unconfirmed, data: %{text: text}}),
    do: add_cell(vm, {:notice, "the steer was not confirmed; send it again if needed: " <> text})

  defp fold(vm, %Event{type: :provider_session, data: data}) do
    %{provider: provider, lost: lost, cut: cut} = data
    lost_text = "#{provider} lost its own session; a fresh one got the transcript"
    vm = if lost, do: add_cell(vm, {:notice, lost_text}), else: vm
    cut_text = "#{provider} got the transcript without its #{cut} oldest messages"
    if cut > 0, do: add_cell(vm, {:notice, cut_text}), else: vm
  end

  @doc """
  The view model of a session from its snapshot. Its cells are the
  transcript cells that the fold of every event up to `snapshot.seq` makes:
  each message makes the cell its events make live, and after an assistant
  message comes a tool cell for each of its calls, closed when the call has
  a result and open when not. Notices and a partial reply with text only of
  an aborted or failed turn are not in the transcript, so a snapshot has none
  of them. A message of a role that the TUI does not show makes no cell, and
  a block kind that it does not render is dropped, as in `apply/2`.
  """
  @spec from_snapshot(Snapshot.t()) :: t()
  def from_snapshot(%Snapshot{messages: messages, turn: turn} = snapshot) do
    %__MODULE__{
      model: snapshot.model,
      instance_id: snapshot.instance_id,
      seq: snapshot.seq,
      cells: history(messages),
      streaming: streaming(turn),
      running?: turn != nil,
      queue: snapshot.queue
    }
  end

  defp streaming(%{partial: %Message{role: :assistant} = partial}),
    do: Enum.reduce(rendered_blocks(partial).content, [], &add_streamed(&2, &1))

  defp streaming(_no_partial), do: nil

  defp history(messages) do
    messages
    |> Enum.flat_map_reduce(results_in_call_order(messages), fn
      %Message{role: :assistant} = message, results ->
        calls = tool_calls(message)
        {mine, rest} = Enum.split(results, length(calls))
        {[rendered_blocks(message) | Enum.zip_with(calls, mine, &tool_cell/2)], rest}

      %Message{role: :user} = message, acc ->
        {[message], acc}

      # A tool result shows in its call's cell; a new role does not show.
      %Message{}, acc ->
        {[], acc}
    end)
    |> elem(0)
  end

  # The result of each tool call of the history, or nil, in call order: a
  # result answers the first still-open earlier call with its id, which on a
  # session transcript pairs as `Helyx.Session.Transcript.open_calls/1` does.
  # One pass over the history, with one map entry per call.
  defp results_in_call_order(messages) do
    {results, _open, count} =
      Enum.reduce(messages, {%{}, %{}, 0}, fn
        %Message{role: :assistant, content: content}, acc ->
          for %Message.ToolCall{id: id} <- content, reduce: acc do
            {results, open, index} ->
              {results, Map.update(open, id, [index], &(&1 ++ [index])), index + 1}
          end

        %Message{role: :tool_result, tool_call_id: id} = result, {results, open, index} ->
          case Map.get(open, id, []) do
            [] -> {results, open, index}
            [call | rest] -> {Map.put(results, call, result), Map.put(open, id, rest), index}
          end

        %Message{}, acc ->
          acc
      end)

    for index <- 0..(count - 1)//1, do: Map.get(results, index)
  end

  @doc "Adds a notice from the client itself, such as a rejected command."
  @spec notice(t(), String.t()) :: t()
  def notice(vm, text) when is_binary(text), do: add_cell(vm, {:notice, text})

  @doc "Sets the reason the status bar shows for a rejected input."
  @spec reject(t(), String.t()) :: t()
  def reject(vm, reason) when is_binary(reason), do: %{vm | reason: reason}

  @doc "Clears the reason. The TUI calls it on a key press or a paste when a reason is set."
  @spec clear_reason(t()) :: t()
  def clear_reason(vm), do: %{vm | reason: nil}

  @doc """
  The line of a tool call: its name, then each argument as `key=value`,
  with the key raw and the value through `inspect/1`, cut at
  #{@render_max_bytes} bytes. The name and each key are cut before they join
  the line, the walk over the arguments stops once the line is over the cut,
  and the line is cut before its newlines become "␤". The fold makes the line
  with the tool cell, and not on each frame.
  """
  @spec call_line(Message.ToolCall.t()) :: String.t()
  def call_line(%Message.ToolCall{name: name, arguments: arguments}) do
    ("⚙ " <> cut_line(name))
    |> join_arguments(arguments |> :maps.iterator() |> :maps.next())
    |> cut_line()
    |> String.replace("\n", "␤")
    |> cut_line()
  end

  # `:maps.next/1` walks the map lazily, so a call of many keys costs no
  # more than the keys up to the cut.
  defp join_arguments(line, :none), do: line
  defp join_arguments(line, _next) when byte_size(line) > @render_max_bytes, do: line

  defp join_arguments(line, {key, value, iterator}),
    do: join_arguments("#{line} #{cut_line("#{key}")}=#{inspect(value)}", :maps.next(iterator))

  # One rule for an error notice or a tool call line that holds provider or
  # model text: `inspect/1` escapes a character to up to four times its
  # bytes (a control or invalid byte renders as `\x01`) and has no total
  # limit over nested terms, so the text is cut at `@render_max_bytes`; a
  # character cut in half is dropped (`Helyx.Text.cap/3`).
  defp cut_line(text), do: Helyx.Text.cap(text, @render_max_bytes, :head)

  # `binaries: :as_strings` escapes a control or invalid byte, so an error
  # text shows as text, not as a list of bytes.
  defp error_text(error), do: error |> inspect(binaries: :as_strings) |> cut_line()

  # The blocks that `Helyx.TUI.Transcript` renders in an assistant message:
  # keep this list and its `block_lines/2` clauses the same. A newer Core can
  # add a block kind, and an image block has no rendering; the TUI drops both
  # here, so the render path never meets them.
  defp rendered_blocks(%Message{content: content} = message) do
    %{message | content: Enum.filter(content, &rendered_block?/1)}
  end

  # A block that is not a struct is a bug in Core and crashes.
  defp rendered_block?(%kind{}), do: kind in [Message.Text, Message.Thinking, Message.ToolCall]

  # A delta with no open message is part of a message that the TUI does
  # not show, such as one of a new role, so it is dropped.
  defp stream(%{streaming: nil} = vm, _delta), do: vm
  defp stream(vm, {:tool_call, call}), do: %{vm | streaming: add_streamed(vm.streaming, call)}
  defp stream(vm, delta), do: %{vm | streaming: Message.add_block(vm.streaming, delta)}

  # A block of the streaming message; a tool call is an open tool cell, not
  # the block of `Message.add_block/2`, so a frame does not make its line.
  defp add_streamed(streaming, %Message.ToolCall{} = call), do: [tool_cell(call, nil) | streaming]
  defp add_streamed(streaming, block), do: [block | streaming]

  defp tool_calls(%Message{content: content}),
    do: for(%Message.ToolCall{} = call <- content, do: call)

  defp add_cell(vm, cell), do: %{vm | cells: vm.cells ++ [cell]}

  # The result goes to the oldest open tool cell with its call id, wherever
  # it is: a notice can arrive while the tool runs (#83). It is the rule of
  # the session and of `from_snapshot/1`: the first result answers the first
  # of two calls with one id. A cell with a result never changes. Every
  # call has an open cell from its message, so a result with no open cell
  # has no call and makes no cell, as in a snapshot.
  defp attach_result(cells, %Message{tool_call_id: id} = result) do
    case Enum.find_index(cells, &match?({:tool, %Message.ToolCall{id: ^id}, _, nil}, &1)) do
      nil -> cells
      index -> List.update_at(cells, index, &put_elem(&1, 3, result))
    end
  end

  defp tool_cell(call, result), do: {:tool, call, call_line(call), result}
end
