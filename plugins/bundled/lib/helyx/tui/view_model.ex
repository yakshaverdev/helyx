defmodule Helyx.TUI.ViewModel do
  @moduledoc """
  The TUI's view of a session: a pure fold over `Helyx.Event`.

  The TUI holds no session state of its own. Every event goes through
  `apply/2` and the screen renders from the result, so the fold is testable
  with scripted event lists.

  `cells` is the transcript: an Erlang `:array` of every cell, open or
  closed, by position, oldest first; `cells/1` gives it as a list. `open`
  maps a call id to a queue of the positions of its open tool cells, oldest
  first, so a result finds its cell with no scan. Each new cell and each
  result costs O(log n) in the cell count
  (`docs/features/session-snapshot.md`). A cell is one of:

    * `%Helyx.Message{}` – a completed user or assistant message
    * `{:tool, call, line, result}` – a tool call of the assistant message
      before it, and its line (`call_line/1`), made with the cell, so a
      frame does not pay for the size of the call; `result` is nil until
      the tool result message comes. The message proves that the call
      exists, not that it runs, so an open cell shows "awaiting result"
    * `{:notice, text}` – an aborted or failed turn, a provider that lost
      its session or got a cut transcript, a steer that was not confirmed, a
      notice of the session, or a command the client rejected
      (`notice/2`), drawn as an error
    * `{:info, text}` – information: a model change of any client, or a
      line of the client itself (`info/2`), such as a resumed session

  `reason` is why the client rejected the last input, or nil. It is
  client-local, like a notice: `reject/2` sets it and `clear_reason/1`
  clears it on the next key press, paste, or mouse press. A new reject
  replaces it. No event changes it.

  `streaming` is the open assistant message as a reversed block list, newest
  first, or nil when none is streaming. Text and thinking deltas join it
  through `Helyx.Message.add_block/2`, the session's convention. Each tool
  call of it is an open tool cell, so a frame does not make its line; the
  `message_end` makes the cells of the message again from the message.

  The view model has no `instance_id` or `seq` guard: the TUI subscribes
  once, and the registration and the snapshot happen in one server handler,
  so no event of another instance or of an older `seq` reaches it (ADR 0006,
  revision of 2026-10-03).
  """

  alias Helyx.{Event, Message}
  alias Helyx.Session.Snapshot

  # The cut of an error notice or a tool call line (`cut_line/1`).
  @render_max_bytes 8_192

  # `cells` is set at run time in `from_snapshot/1`: an `:array` literal in
  # the struct default breaks the opaque type for Dialyzer.
  defstruct model: nil,
            cells: nil,
            open: %{},
            streaming: nil,
            running?: false,
            queue: %{steers: 0, follow_ups: 0},
            reason: nil

  @type tool_cell :: {:tool, Message.ToolCall.t(), String.t(), Message.t() | nil}
  @type cell :: Message.t() | tool_cell() | {:notice, String.t()} | {:info, String.t()}

  @type t :: %__MODULE__{
          model: String.t(),
          cells: :array.array(cell()),
          open: %{String.t() => :queue.queue(non_neg_integer())},
          streaming: [Message.block() | tool_cell()] | nil,
          running?: boolean(),
          queue: %{steers: non_neg_integer(), follow_ups: non_neg_integer()},
          reason: String.t() | nil
        }

  @delta_keys [:text_delta, :thinking_delta, :tool_call]

  @doc """
  Folds one event into the view model. The TUI is a tolerant reader of one
  Helyx version (ADR 0006, revision of 2026-10-03). It dispatches on the
  event type first: each known type has a clause that matches the type only
  and checks its payload inside, so a known type with a broken payload, such
  as a `message_start` with no message, is a bug in Core and crashes the TUI.
  An event of a type that no clause names leaves the view model unchanged,
  and its payload is not checked. Within a known type:

    * a `message_update` with no delta key that the TUI knows (an empty data
      map included) carries a new delta kind and is ignored; a known key with
      a value of another type, or two known keys, crashes
    * a message of a role that the TUI does not show makes no cell, and a
      delta with no open assistant message, such as one of a message of a
      new role, is dropped
    * a block kind that the TUI does not render stays in the message, and
      `Helyx.TUI.Transcript` shows a placeholder for it
  """
  @spec apply(t(), Event.t()) :: t()
  def apply(vm, %Event{type: :turn_start}), do: %{vm | running?: true}

  def apply(vm, %Event{type: :turn_end, data: data}) do
    vm = %{vm | running?: false, streaming: nil}

    case data do
      %{outcome: :done} -> vm
      %{outcome: :aborted} -> add_cell(vm, {:notice, "aborted"})
      %{outcome: :error, error: error} -> add_cell(vm, {:notice, "error: " <> error_text(error)})
    end
  end

  def apply(vm, %Event{type: :message_start, data: data}) do
    %{message: %Message{role: role}} = data
    if role == :assistant, do: %{vm | streaming: []}, else: vm
  end

  # Core sends one delta key for each update. An update with no known key
  # has a delta kind that this client does not know, so it is ignored; a
  # known key with another value, or two known keys, is a bug in Core and
  # crashes.
  def apply(vm, %Event{type: :message_update, data: data}) do
    case Map.to_list(Map.take(data, @delta_keys)) do
      [] -> vm
      [{:text_delta, delta}] when is_binary(delta) -> stream(vm, {:text_delta, delta})
      [{:thinking_delta, delta}] when is_binary(delta) -> stream(vm, {:thinking_delta, delta})
      [{:tool_call, %Message.ToolCall{} = call}] -> stream(vm, {:tool_call, call})
    end
  end

  # A tool result shows in its call's cell at `tool_execution_end`.
  def apply(vm, %Event{type: :message_end, data: data}) do
    case data do
      %{message: %Message{role: :tool_result}} ->
        vm

      %{message: %Message{role: :assistant} = message} ->
        add_message(%{vm | streaming: nil}, message)

      %{message: %Message{} = message} ->
        add_message(vm, message)
    end
  end

  # A result of another role would leave its cell open, so it crashes.
  def apply(vm, %Event{type: :tool_execution_end, data: data}) do
    %{message: %Message{role: :tool_result} = result} = data
    add_message(vm, result)
  end

  def apply(vm, %Event{type: :queue_update, data: data}) do
    %{steers: steers, follow_ups: follow_ups} = data
    %{vm | queue: %{steers: steers, follow_ups: follow_ups}}
  end

  def apply(vm, %Event{type: :model_change, data: data}) do
    %{model: model} = data
    add_cell(%{vm | model: model}, {:info, "model: " <> model})
  end

  def apply(vm, %Event{type: :notice, data: data}) do
    %{text: text} = data
    add_cell(vm, {:notice, text})
  end

  def apply(vm, %Event{type: :steer_unconfirmed, data: data}) do
    %{text: text} = data
    add_cell(vm, {:notice, "the steer was not confirmed; send it again if needed: " <> text})
  end

  def apply(vm, %Event{type: :provider_session, data: data}) do
    %{provider: provider, lost: lost, cut: cut} = data
    lost_text = "#{provider} lost its own session; a fresh one got the transcript"
    vm = if lost, do: add_cell(vm, {:notice, lost_text}), else: vm
    cut_text = "#{provider} got the transcript without its #{cut} oldest messages"
    if cut > 0, do: add_cell(vm, {:notice, cut_text}), else: vm
  end

  # A type that this client does not know.
  def apply(vm, %Event{}), do: vm

  @doc """
  The view model of a session from its snapshot. The snapshot messages go
  through the fold in order, so the live and the snapshot paths share one
  pairing rule (ADR 0006, revision of 2026-10-03). Notices and information
  cells are not in the transcript, so a snapshot has none of them.
  """
  @spec from_snapshot(Snapshot.t()) :: t()
  def from_snapshot(%Snapshot{messages: messages, turn: turn} = snapshot) do
    vm = %__MODULE__{
      model: snapshot.model,
      cells: :array.new(),
      running?: turn != nil,
      queue: snapshot.queue
    }

    %{Enum.reduce(messages, vm, &add_message(&2, &1)) | streaming: streaming(turn)}
  end

  defp streaming(%{partial: %Message{role: :assistant} = partial}),
    do: Enum.reduce(partial.content, [], &add_streamed(&2, &1))

  defp streaming(_no_partial), do: nil

  @doc "The cells, oldest first, as a list. For tests and the benchmark."
  @spec cells(t()) :: [cell()]
  def cells(%__MODULE__{cells: cells}), do: :array.to_list(cells)

  @doc """
  The nearest user message older (`:older`) or newer (`:newer`) than the
  cell at `position`, as `{position, text}`, or nil. The text is
  `Helyx.Message.text/1`. A nil position is past the newest cell.
  """
  @spec prompt(t(), non_neg_integer() | nil, :older | :newer) ::
          {non_neg_integer(), String.t()} | nil
  def prompt(%__MODULE__{cells: cells}, position, direction) do
    start = position || :array.size(cells)

    range =
      case direction do
        :older -> (start - 1)..0//-1
        :newer -> (start + 1)..(:array.size(cells) - 1)//1
      end

    Enum.find_value(range, fn at ->
      case :array.get(at, cells) do
        %Message{role: :user} = message -> {at, Message.text(message)}
        _cell -> nil
      end
    end)
  end

  @doc "Adds a notice from the client itself, such as a rejected command."
  @spec notice(t(), String.t()) :: t()
  def notice(vm, text) when is_binary(text), do: add_cell(vm, {:notice, text})

  @doc "Adds information from the client itself, such as a resumed session."
  @spec info(t(), String.t()) :: t()
  def info(vm, text) when is_binary(text), do: add_cell(vm, {:info, text})

  @doc "Sets the reason the footer shows for a rejected input."
  @spec reject(t(), String.t()) :: t()
  def reject(vm, reason) when is_binary(reason), do: %{vm | reason: reason}

  @doc "Clears the reason. The TUI calls it on a key press, a paste, or a mouse press."
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

  # A delta with no open message is part of a message that the TUI does
  # not show, such as one of a new role, so it is dropped.
  defp stream(%{streaming: nil} = vm, _delta), do: vm
  defp stream(vm, {:tool_call, call}), do: %{vm | streaming: add_streamed(vm.streaming, call)}
  defp stream(vm, delta), do: %{vm | streaming: Message.add_block(vm.streaming, delta)}

  # A block of the streaming message; a tool call is an open tool cell, not
  # the block of `Message.add_block/2`, so a frame does not make its line.
  defp add_streamed(streaming, %Message.ToolCall{} = call), do: [tool_cell(call, nil) | streaming]
  defp add_streamed(streaming, block), do: [block | streaming]

  # A message as a transcript cell. Each call of an assistant message gets
  # an open cell; its result comes later. A message of a role that the TUI
  # does not show makes no cell.
  defp add_message(vm, %Message{role: :user} = message), do: add_cell(vm, message)

  defp add_message(vm, %Message{role: :assistant, content: content} = message) do
    for %Message.ToolCall{id: id} = call <- content, reduce: add_cell(vm, message) do
      vm ->
        position = :array.size(vm.cells)
        open = Map.update(vm.open, id, :queue.from_list([position]), &:queue.in(position, &1))
        %{vm | open: open, cells: :array.set(position, tool_cell(call, nil), vm.cells)}
    end
  end

  # The result closes the oldest open cell with its call id, wherever it
  # is: a notice can arrive while the tool runs. The first result answers
  # the first of two calls with one id, as in the session. A result with no
  # open cell crashes in `Map.fetch!/2`.
  defp add_message(vm, %Message{role: :tool_result, tool_call_id: id} = result) do
    {{:value, position}, queue} = :queue.out(Map.fetch!(vm.open, id))

    open =
      if :queue.is_empty(queue), do: Map.delete(vm.open, id), else: Map.put(vm.open, id, queue)

    cell = put_elem(:array.get(position, vm.cells), 3, result)
    %{vm | open: open, cells: :array.set(position, cell, vm.cells)}
  end

  defp add_message(vm, %Message{}), do: vm

  # The next free position is the array size: no cell is ever removed.
  defp add_cell(vm, cell), do: %{vm | cells: :array.set(:array.size(vm.cells), cell, vm.cells)}

  defp tool_cell(call, result), do: {:tool, call, call_line(call), result}
end
