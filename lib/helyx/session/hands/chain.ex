defmodule Helyx.Session.Hands.Chain do
  @moduledoc false
  # The chain of a Helyx tool call, in its call Task of
  # `Helyx.Session.Hands` (docs/features/hooks.md): the `before_tool`
  # hooks, the tool, then the `after_tool` hooks. Each hook runs in a Task
  # of the hands of its own; the call Task waits for its answer with a call
  # to the hands, which answer after the release of the hook's handles.
  # The chain state is in the process dictionary of the call Task, so
  # `Helyx.Tool.started/1` runs the `after_tool` hooks on a start answer.
  # The `before_settle` chain runs the same way from a chain Task of its
  # own (`settle/2`, docs/features/before-settle.md).

  alias Helyx.Message.ToolCall
  alias Helyx.Session.Hands.Run
  alias Helyx.Session.HookEntry

  # `hooks` is `%{point => [{module, limit_ms}]}`. Returns the result for
  # the hands to deliver.
  @spec run(module(), ToolCall.t(), String.t(), String.t(), map()) :: {:ok | :error, String.t()}
  def run(tool, %ToolCall{} = call, cwd, _turn_id, hooks)
      when not is_map_key(hooks, :before_tool) and not is_map_key(hooks, :after_tool),
      do: Run.tool(tool, call, cwd)

  def run(tool, %ToolCall{} = call, cwd, turn_id, hooks) do
    input = %{
      tool: call.name,
      arguments: call.arguments,
      cwd: cwd,
      session_id: Helyx.Tool.context().session_id,
      turn_id: turn_id,
      call_id: call.id,
      provider: nil
    }

    Process.put(:helyx_chain, %{hooks: hooks, input: input, after: :pending})

    case before(Map.get(hooks, :before_tool, []), input, :first) do
      :allow -> after_tool(Run.tool(tool, call, cwd))
      {:error, _text} = denied -> denied
    end
  end

  defp before([], _input, _record), do: :allow

  defp before([{module, ms} | rest], input, record) do
    case step(module, ms, :before_tool, input, record) do
      {:answer, :allow} ->
        before(rest, input, nil)

      {:answer, {:allow, _reason}} ->
        before(rest, input, nil)

      {:answer, {:deny, reason}} ->
        {:error, "the hook #{inspect(module)} denied the call: " <> reason}

      {:failed, how} ->
        {:error, "the hook #{inspect(module)} failed: #{how}; the call was not run"}
    end
  end

  # The `after_tool` hooks run once on a call: on its result, or on its
  # start answer when it went on in the background.
  defp after_tool(result) do
    case Process.get(:helyx_chain) do
      %{after: :pending} = chain ->
        Process.put(:helyx_chain, %{chain | after: :done})
        hooks = Map.get(chain.hooks, :after_tool, [])
        after_each(hooks, chain.input, :first, result)

      %{after: :done} ->
        result
    end
  end

  # The start answer of a background run (`Helyx.Tool.started/1`): the
  # hooks run here, and not again on the end of the run, which is no
  # result. A process with no chain, such as a hook Task, and a call with
  # no place from `Helyx.Tool.background/0`, whose `started/1` raises,
  # run no hook here.
  def after_start(result) do
    if Process.get(:helyx_chain) && Process.get(:helyx_place),
      do: after_tool(result),
      else: result
  end

  defp after_each([], _input, _record, result), do: result

  defp after_each([{module, ms} | rest], input, record, result) do
    case step(module, ms, :after_tool, Map.put(input, :result, result), record) do
      {:answer, :keep} -> after_each(rest, input, record, result)
      {:answer, {:replace, replaced}} -> after_each(rest, input, nil, replaced)
      {:failed, _how} -> after_each(rest, input, nil, result)
    end
  end

  # The `before_settle` hooks in plugin order, from the chain Task
  # (`Helyx.Session.Hands.Settle`): the first continue ends the chain; a
  # settle and a failed hook go on.
  @spec settle([{module(), pos_integer()}], Helyx.Hook.settle()) ::
          :settle | {:continue, module(), String.t()}
  def settle([], _input), do: :settle

  def settle([{module, ms} | rest], input) do
    case step(module, ms, :before_settle, input, nil) do
      {:answer, {:continue, text}} -> {:continue, module, text}
      _settle_or_failed -> settle(rest, input)
    end
  end

  # One hook in its own Task of the hands. `record` is `:first` until the
  # chain wrote an entry: the entry then gets the call.
  defp step(module, ms, point, input, record) do
    request = %{
      module: module,
      ms: ms,
      point: point,
      input: input,
      record: if(record == :first, do: record_call(input)),
      context: Helyx.Tool.context()
    }

    GenServer.call(Process.get(:helyx_hands), {:hook, request}, :infinity)
  end

  # The call in the first entry of a chain: its tool name and the JSON of
  # its arguments, cut at a character boundary (ADR 0013 §6). The call
  # Task makes the copy, so the session encodes nothing large.
  defp record_call(%{tool: tool, arguments: arguments}) do
    {json, cut?} = HookEntry.cut(JSON.encode!(arguments))
    %{tool: tool, arguments: json, arguments_cut: cut?}
  end
end
