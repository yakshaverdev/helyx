defmodule Helyx.Provider.Codex.Check do
  @moduledoc false
  # The shape check of the lines of `Helyx.Provider.Codex`. It reads the
  # provider state as a map: `due`, `thread`, `turn`, `resume`, `started`,
  # and `open`.

  alias Helyx.Message

  @lost "no rollout found for thread id "
  # Item types that run something (see the research note).
  @tool_item_types ~w(commandExecution fileChange mcpToolCall dynamicToolCall collabAgentToolCall
            webSearch imageView imageGeneration)
  def tool_item_types, do: @tool_item_types

  # The statuses that end a tool item, from the schema of codex 0.157.1
  # (research note). `imageGeneration` has a free string: every value but
  # `inProgress` ends it. A type with no status ends at its `item/completed`.
  @ended %{
    "commandExecution" => ~w(completed failed declined),
    "fileChange" => ~w(completed failed declined),
    "mcpToolCall" => ~w(completed failed),
    "dynamicToolCall" => ~w(completed failed),
    "collabAgentToolCall" => ~w(completed failed interrupted)
  }
  # The notifications that clear or confirm turn state, and the statuses
  # that end a turn.
  @turn_lines ~w(turn/started turn/completed item/started item/completed)
  @turn_ends ~w(completed failed interrupted)
  # The kinds of a `subAgentActivity` item in the schema of codex 0.157.1.
  @agent_kinds ~w(started interacted interrupted completed)
  # The hex digits of the tool set digest in a stored id.
  @digest_hex 16

  def digest_hex, do: @digest_hex

  # The one check of every line that changes turn or thread state, before
  # any state changes: the answers to the due requests, and the turn and
  # item notifications of this program's thread. Gives nil, or the method of a
  # line without its full shape (the schema of codex 0.157.1, research
  # note); that line stops the provider process.
  # A turn or item notification is never a request, on any thread: such a
  # line is a protocol fault of the program.
  def malformed(%{"id" => _, "method" => method}, _state) when method in @turn_lines,
    do: method

  def malformed(%{"id" => _, "method" => _}, _state), do: nil

  # An answer to a due request. Any other answer is dropped.
  def malformed(%{"id" => id} = answer, %{due: due} = state) when is_map_key(due, id),
    do: if(answer?(due[id], answer, state), do: nil, else: due[id])

  def malformed(%{"method" => method, "params" => %{"threadId" => thread} = params}, state)
      when method in @turn_lines and thread == state.thread and is_binary(thread),
      do: if(line?(method, params) and not again?(method, params, state), do: nil, else: method)

  # A turn or item line of another thread. With no string thread id (the
  # schema requires one), it can be a line of this thread.
  def malformed(%{"method" => method, "params" => %{"threadId" => thread}}, _state)
      when method in @turn_lines and is_binary(thread),
      do: nil

  def malformed(%{"method" => method}, _state) when method in @turn_lines, do: method

  def malformed(_object, _state), do: nil

  # An `item/started` of the running turn with the id of an item that has
  # a tool call would add that tool call again. Only tool items are in
  # `started`. An `item/completed` of the running turn with the id of an
  # open tool item of another type would clear that item while it runs.
  defp again?(
         "item/started",
         %{"turnId" => turn, "item" => %{"id" => id}},
         %{turn: turn} = state
       ),
       do: MapSet.member?(state.started, id)

  defp again?(
         "item/completed",
         %{"turnId" => turn, "item" => %{"id" => id, "type" => type}},
         %{turn: turn} = state
       ),
       do: is_map_key(state.open, id) and state.open[id] != type

  defp again?(_method, _params, _state), do: false

  # An answer is an error object or a result, never both. A resume fails
  # only with the lost-thread error of the research note, and succeeds only
  # for the thread it asked for.
  defp answer?(_method, %{"error" => _, "result" => _}, _state), do: false

  defp answer?("thread/resume", %{"error" => %{"code" => -32_600, "message" => message}}, state),
    do: message == @lost <> state.resume

  defp answer?("thread/resume", %{"result" => %{"thread" => %{"id" => thread}}}, state),
    do: thread == state.resume

  defp answer?("thread/resume", _answer, _state), do: false

  # The stored id can add `#` and the digest to the thread id, so the
  # thread id must pass `Message.resume_id?/1` with that room kept free.
  defp answer?("thread/start", %{"result" => %{"thread" => %{"id" => thread}}}, _state)
       when is_binary(thread) and thread != "",
       do: Message.resume_id?(thread <> "#" <> String.duplicate("0", @digest_hex))

  defp answer?("turn/start", %{"result" => %{"turn" => %{"id" => turn}}}, _state),
    do: is_binary(turn)

  defp answer?(method, %{"result" => _}, _state) when method in ["thread/start", "turn/start"],
    do: false

  defp answer?(_method, %{"error" => error}, _state), do: is_map(error)
  defp answer?(_method, %{"result" => result}, _state), do: is_map(result)
  defp answer?(_method, _answer, _state), do: false

  defp line?("turn/started", %{"turn" => %{"id" => turn}}), do: is_binary(turn)

  defp line?("turn/completed", %{"turn" => %{"id" => turn, "status" => status}}),
    do: is_binary(turn) and status in @turn_ends

  defp line?(method, %{
         "turnId" => turn,
         "item" => %{"type" => "subAgentActivity", "id" => id, "agentThreadId" => child} = item
       })
       when method in ["item/started", "item/completed"] and is_binary(turn) and is_binary(id) and
              is_binary(child),
       do: item["kind"] in @agent_kinds

  defp line?(_method, %{"item" => %{"type" => "subAgentActivity"}}), do: false

  # A tool item leaves the open work only with a status that ends it.
  defp line?(method, %{"turnId" => turn, "item" => %{"type" => type, "id" => id} = item})
       when method in ["item/started", "item/completed"] and is_binary(turn) and is_binary(type) and
              is_binary(id),
       do: method == "item/started" or type not in @tool_item_types or ended?(item)

  defp line?(_method, _params), do: false

  defp ended?(%{"type" => type, "status" => status}) when is_map_key(@ended, type),
    do: status in @ended[type]

  defp ended?(%{"type" => "imageGeneration", "status" => status}),
    do: is_binary(status) and status != "inProgress"

  defp ended?(%{"type" => type}) when is_map_key(@ended, type) or type == "imageGeneration",
    do: false

  defp ended?(_item), do: true
end
