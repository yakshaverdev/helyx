defmodule Helyx.Session.Server.UIBlocks do
  @moduledoc false
  # The UI blocks of the running turn (docs/features/ui-blocks.md): the
  # only writer of `ui_blocks` and `helyx_calls` in `Helyx.Session.Turn`.
  #
  # `ui_blocks` holds the newest block of each pair of call id and key of
  # the `:ui_block` events, in the order of the first event of the pair,
  # for the snapshot. The blocks of a call leave when its result joins the
  # transcript (`call_end/2`); the turn takes the rest with it.
  #
  # `helyx_calls` holds an entry for each Helyx tool request of the turn
  # whose call was open at the request and whose result has not joined the
  # transcript: the UI blocks of the hands' result, `[]` until it comes.
  # The result message gets them when the provider's `tool_result` event
  # joins it (`result_blocks/2`). The entry is the window of the call's
  # blocks: a tool's block only inside it, a provider block never.

  import Helyx.Session.Server.Events, only: [emit: 3]

  alias Helyx.Session.Server.{State, Wait}
  alias Helyx.Session.{Transcript, Turn}

  @max_keys Helyx.UIBlock.max_keys()

  # A Helyx tool request of the turn. A call that has blocks of the
  # provider is one that the provider ran itself: it names it in a request
  # too, a contract break (`:shown`), and the session stops the provider.
  # Only a call that is open gets a window. A request for a call with no
  # open tool call, one that has its result or that was never streamed,
  # runs as before (#369) and shows no block, so no block comes after a
  # result, and every entry ends with its call's result.
  def request(%State{activity: %Turn{} = turn} = state, call_id) do
    cond do
      Enum.any?(turn.ui_blocks, fn {{id, _key}, _block} -> id == call_id end) ->
        :shown

      open_call?(state, call_id) ->
        {:ok, %{state | activity: %{turn | helyx_calls: Map.put(turn.helyx_calls, call_id, [])}}}

      true ->
        {:ok, state}
    end
  end

  # The blocks of the hands' result of a running Helyx call. A call whose
  # result joined the transcript first, such as the `aborted` result at a
  # taken steer, has no entry, and its blocks go nowhere.
  def result(%State{activity: %Turn{} = turn} = state, call_id, blocks),
    do: %{state | activity: %{turn | helyx_calls: Map.replace(turn.helyx_calls, call_id, blocks)}}

  # The blocks that the result message of the call gets.
  def result_blocks(%State{activity: %Turn{helyx_calls: calls}}, call_id),
    do: Map.get(calls, call_id, [])

  def result_blocks(_state, _call_id), do: []

  # The result of the call joined the transcript: its blocks leave.
  def call_end(%State{activity: %Turn{} = turn} = state, call_id) do
    blocks = Enum.reject(turn.ui_blocks, fn {{id, _key}, _block} -> id == call_id end)

    %{
      state
      | activity: %{turn | ui_blocks: blocks, helyx_calls: Map.delete(turn.helyx_calls, call_id)}
    }
  end

  def call_end(state, _call_id), do: state

  # A block of a running Helyx call (`Helyx.Tool.show/2`), which waits for
  # the reply: `:ok`, `{:error, :not_running}`, or `:too_many` for a new
  # key past the count, on which the caller raises. The entry in
  # `helyx_calls` is the window of the call's blocks, from its request to
  # its result in the transcript, as it is for a provider block: a Task
  # that runs on after an `aborted` result shows nothing.
  def tool_block(
        %State{activity: %Turn{tool_queue: %{running: running}, helyx_calls: calls}} = state,
        call_id,
        key,
        block
      )
      when is_map_key(running, call_id) and is_map_key(calls, call_id) do
    case put(state, call_id, key, block) do
      {:ok, state} -> {:reply, :ok, state}
      :too_many -> {:reply, :too_many, state}
    end
  end

  def tool_block(state, _call_id, _key, _block), do: {:reply, {:error, :not_running}, state}

  # A block of the provider of the turn. A call id that does not name an
  # open call of the turn that the provider runs itself drops the block: it
  # can be on its way when its call ends. A new key past the count is a
  # contract break: `{:error, reason}`, and the session stops the provider.
  def provider_block(%State{} = state, call_id, key, block) do
    if call_id == nil or provider_call?(state, call_id) do
      case put(state, call_id, key, block) do
        {:ok, state} -> {:ok, state}
        :too_many -> {:error, {:too_many_ui_block_keys, @max_keys}}
      end
    else
      {:ok, state}
    end
  end

  defp provider_call?(%State{activity: %Turn{} = turn} = state, call_id),
    do: not is_map_key(turn.helyx_calls, call_id) and open_call?(state, call_id)

  # A call of the open assistant message, or of the transcript with no result.
  defp open_call?(%State{activity: %Turn{partial: partial}} = state, call_id) do
    Enum.any?(partial || [], &match?(%Helyx.Message.ToolCall{id: ^call_id}, &1)) or
      Enum.any?(Transcript.open_calls(state.transcript), &(&1.id == call_id))
  end

  defp put(%State{activity: %Turn{ui_blocks: blocks} = turn} = state, call_id, key, block) do
    pair = {call_id, key}
    new? = not List.keymember?(blocks, pair, 0)

    if new? and Enum.count(blocks, fn {{id, _key}, _block} -> id == call_id end) >= @max_keys do
      :too_many
    else
      state = %{
        state
        | activity: %{turn | ui_blocks: List.keystore(blocks, pair, 0, {pair, block})}
      }

      {:ok, emit(state, :ui_block, %{call_id: call_id, key: key, block: block})}
    end
  end

  # The blocks of a snapshot, each as the data of its event: of the running
  # turn, or of the turn whose `turn_end` waits for the hands.
  def snapshot(%State{activity: %Turn{ui_blocks: blocks}}), do: data(blocks)

  def snapshot(%State{activity: %Wait{turn_end: data, ui_blocks: blocks}}) when data != nil,
    do: data(blocks)

  def snapshot(_state), do: []

  defp data(blocks),
    do: for({{call_id, key}, block} <- blocks, do: %{call_id: call_id, key: key, block: block})
end
