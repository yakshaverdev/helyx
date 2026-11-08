defmodule Helyx.Session.Server.UIBlocks do
  @moduledoc false
  # The UI blocks of the running turn (docs/features/ui-blocks.md): the
  # only writer of `ui_blocks`, `held_results`, `helyx_calls`, and
  # `helyx_calls_refused` in `Helyx.Session.Turn`.
  #
  # `ui_blocks` holds the newest block of each pair of call id and key of
  # the `:ui_block` events, in the order of the first event of the pair,
  # for the snapshot. The blocks of a call leave when its result joins the
  # transcript (`call_end/2`); the turn takes the rest with it.
  #
  # `held_results` holds the UI blocks of the hands' result of a Helyx call
  # until the provider's `tool_result` event joins it (`result_blocks/2`).
  # The blocks of `ui_blocks` and of `held_results` are at most
  # @max_turn_blocks together.
  #
  # `helyx_calls` holds the id of each Helyx tool request of the turn, from
  # the request to the end of the turn, in any order of the request and
  # its tool call: a provider block that names one is dropped (ADR 0011
  # §3). A request past the bound of the set runs, but its id stays out of
  # the set, so its call shows no blocks; from then on the session cannot
  # tell a call of the provider from a Helyx call, so it drops every
  # provider block that names a call (`helyx_calls_refused`).

  import Helyx.Session.Server.Events, only: [emit: 3]

  alias Helyx.Session.Server.{Asks, State, Wait}
  alias Helyx.Session.{Transcript, Turn}

  require Asks

  @typedoc "A block of `ui_blocks`: its pair of call id and key, and the block."
  @type entry :: {{String.t() | nil, String.t()}, Helyx.UIBlock.t()}

  @max_keys Helyx.UIBlock.max_keys()
  @max_turn_blocks Helyx.UIBlock.max_turn_blocks()
  # The Helyx call ids of one turn: a count, and the bytes of the ids
  # together, because a call id has no bound of its own. A provider id is
  # about 30 bytes, so 256 ids of 256 bytes each fit.
  @max_calls 256
  @max_call_bytes 65_536

  # A Helyx tool request of the turn: its id joins `helyx_calls`. A call
  # with blocks that is not in the set has blocks of the provider, so the
  # provider ran it itself: it names it in a request too, a contract break
  # (`:shown`), and the session stops the provider. A second request for a
  # call in the set runs (#369). A request past the bound of the set runs
  # too, with its id out of the set: its Task shows no block and its result
  # keeps none (`tool_block/5`, `result/3`).
  def request(%State{activity: %Turn{helyx_calls: calls} = turn} = state, call_id) do
    cond do
      is_map_key(calls, call_id) ->
        {:ok, state}

      Enum.any?(turn.ui_blocks, &of_call?(&1, call_id)) ->
        :shown

      map_size(calls) >= @max_calls or
          Enum.sum_by(calls, fn {id, true} -> byte_size(id) end) + byte_size(call_id) >
            @max_call_bytes ->
        {:ok, %{state | activity: %{turn | helyx_calls_refused: true}}}

      true ->
        {:ok, %{state | activity: %{turn | helyx_calls: Map.put(calls, call_id, true)}}}
    end
  end

  # The result of a Helyx call from the hands, with its blocks. They wait
  # for the provider's result event when they fit the blocks of the turn,
  # else the result keeps none, as it keeps none for a call whose id is out
  # of `helyx_calls`. A second run of the call replaces the
  # entry of the first, the reused call id of #369. A call that the
  # transcript answered already, as at a taken steer, keeps nothing: its
  # result does not join again, or, when a reused call id (#369) opens the
  # call again, it joins with no blocks.
  def result(%State{activity: %Turn{} = turn} = state, call_id, blocks) do
    turn = %{turn | held_results: Map.delete(turn.held_results, call_id)}

    keep? =
      blocks != [] and is_map_key(turn.helyx_calls, call_id) and
        length(blocks) <= @max_turn_blocks - count(turn) and
        not Transcript.answered?(state.transcript, turn.partial, call_id)

    held = if keep?, do: Map.put(turn.held_results, call_id, blocks), else: turn.held_results
    %{state | activity: %{turn | held_results: held}}
  end

  # The blocks that the result message of the call gets.
  def result_blocks(%State{activity: %Turn{held_results: held}}, call_id),
    do: Map.get(held, call_id, [])

  def result_blocks(_state, _call_id), do: []

  # The result of the call joined the transcript: its blocks leave.
  def call_end(%State{activity: %Turn{} = turn} = state, call_id) do
    blocks = Enum.reject(turn.ui_blocks, &of_call?(&1, call_id))

    %{
      state
      | activity: %{
          turn
          | ui_blocks: blocks,
            held_results: Map.delete(turn.held_results, call_id)
        }
    }
  end

  def call_end(state, _call_id), do: state

  # A block of a Helyx call (`Helyx.Tool.show/2`) from the Task `pid`,
  # which waits for the reply: `:ok`, `{:error, :not_running}`,
  # `{:error, :too_many_blocks}` for a new block past the blocks of the
  # turn and for any block of a call whose id is out of `helyx_calls` (its
  # request was past the bound of the set), or `:too_many` for a new key
  # past the count, on which the caller
  # raises. The session takes a block only from the call's own Task while
  # it has a record, as it takes an ask: the record ends when the call's
  # result joins the transcript.
  def tool_block(%State{activity: %Turn{} = turn} = state, pid, call_id, _key, _block)
      when Asks.caller?(turn, pid, {:tool, call_id}) and not is_map_key(turn.helyx_calls, call_id),
      do: {:reply, {:error, :too_many_blocks}, state}

  def tool_block(%State{activity: %Turn{} = turn} = state, pid, call_id, key, block)
      when Asks.caller?(turn, pid, {:tool, call_id}) do
    case put(state, call_id, key, block) do
      {:ok, state} -> {:reply, :ok, state}
      :too_many -> {:reply, :too_many, state}
      :full -> {:reply, {:error, :too_many_blocks}, state}
    end
  end

  def tool_block(state, _pid, _call_id, _key, _block),
    do: {:reply, {:error, :not_running}, state}

  # A block of the provider of the turn. A call id that does not name an
  # open call of the turn that the provider runs itself drops the block: it
  # can be on its way when its call ends. A new block past the blocks of
  # the turn is dropped. A new key past the count is a contract break:
  # `{:error, reason}`, and the session stops the provider.
  def provider_block(%State{} = state, call_id, key, block) do
    if call_id == nil or provider_call?(state, call_id) do
      case put(state, call_id, key, block) do
        {:ok, state} -> {:ok, state}
        :full -> {:ok, state}
        :too_many -> {:error, {:too_many_ui_block_keys, @max_keys}}
      end
    else
      {:ok, state}
    end
  end

  defp provider_call?(%State{activity: %Turn{} = turn} = state, call_id) do
    not turn.helyx_calls_refused and not is_map_key(turn.helyx_calls, call_id) and
      Transcript.open_call?(state.transcript, turn.partial, call_id)
  end

  # A new pair of call id and key past the keys of its call id is
  # `:too_many`, and past the blocks of the turn `:full`; a block that
  # replaces the block of its pair is neither.
  defp put(%State{activity: %Turn{ui_blocks: blocks} = turn} = state, call_id, key, block) do
    pair = {call_id, key}
    new? = not List.keymember?(blocks, pair, 0)

    cond do
      new? and Enum.count(blocks, &of_call?(&1, call_id)) >= @max_keys ->
        :too_many

      new? and count(turn) >= @max_turn_blocks ->
        :full

      true ->
        blocks = List.keystore(blocks, pair, 0, {pair, block})
        state = %{state | activity: %{turn | ui_blocks: blocks}}
        {:ok, emit(state, :ui_block, %{call_id: call_id, key: key, block: block})}
    end
  end

  defp of_call?({{id, _key}, _block}, call_id), do: id == call_id

  # The blocks of the turn: of its events, and of the results it holds.
  defp count(%Turn{ui_blocks: blocks, held_results: held}),
    do: length(blocks) + Enum.sum_by(held, fn {_id, blocks} -> length(blocks) end)

  # The blocks of a snapshot, each as the data of its event: of the running
  # turn, or of the turn whose `turn_end` waits for the hands.
  def snapshot(%State{activity: %Turn{ui_blocks: blocks}}), do: data(blocks)

  def snapshot(%State{activity: %Wait{turn_end: data, ui_blocks: blocks}}) when data != nil,
    do: data(blocks)

  def snapshot(_state), do: []

  defp data(blocks) do
    for {{call_id, key}, block} <- blocks, do: %{call_id: call_id, key: key, block: block}
  end
end
