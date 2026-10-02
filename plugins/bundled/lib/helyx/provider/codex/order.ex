defmodule Helyx.Provider.Codex.Order do
  @moduledoc false
  # Codex runs tool items side by side, and the session gives every call
  # that is still open an `aborted` result at a `message_end`
  # (`Helyx.Provider`), so a call of a sent message can still run when the
  # next message closes. Such a `message_end`, and every event after it, is
  # held until the results of the sent calls are out; a result of a sent
  # call goes out at once. An event waits only for an open tool item, and a
  # turn that ends with one stops the provider process, so a turn that ends
  # holds nothing. More than `@held_max` held events stop the provider
  # process.
  #
  # `waiting` holds the ids of the calls of sent messages with no result
  # yet, and `held` the events that wait for those results.
  defstruct waiting: MapSet.new(), held: :queue.new()

  # The most events held at once.
  @held_max 10_000

  # Gives the events to send now, in order, the order, and nil or the stop
  # reason of an event over `@held_max` held events. The events after that
  # one are dropped.
  def put(events, order) do
    {out, order, stop} = Enum.reduce(events, {[], order, nil}, &order_one/2)
    {Enum.reverse(out), order, stop}
  end

  def empty?(order), do: :queue.is_empty(order.held)

  defp order_one(_event, {_out, _order, {_, _}} = acc), do: acc

  # `:queue.len/1` costs O(held), as a held result's insert does; the cap
  # bounds both.
  defp order_one(event, {out, order, nil}) do
    cond do
      waiting_result?(event, order) ->
        {out, order} = flush(emit(event, {out, order}))
        {out, order, nil}

      :queue.is_empty(order.held) and not blocked?(event, order) ->
        {out, order} = emit(event, {out, order})
        {out, order, nil}

      :queue.len(order.held) >= @held_max ->
        {out, order, {:held_over_limit, @held_max}}

      true ->
        {out, %{order | held: hold(event, order.held)}, nil}
    end
  end

  # A held result goes right after its own `message_end` and the results
  # there, so a later `message_end` cannot hold it back. A result with no
  # held `message_end`, such as a repeat, goes to the end. Each insert
  # costs O(held), and `@held_max` bounds the held events.
  defp hold({:tool_result, id, _result} = event, held) do
    {before, rest} = Enum.split_while(:queue.to_list(held), &(not closes?(&1, id)))

    case rest do
      [close | tail] ->
        {results, later} = Enum.split_while(tail, &match?({:tool_result, _, _}, &1))
        :queue.from_list(before ++ [close | results] ++ [event | later])

      [] ->
        :queue.in(event, held)
    end
  end

  defp hold(event, held), do: :queue.in(event, held)

  defp closes?({:close, ids, _event}, id), do: id in ids
  defp closes?(_event, _id), do: false

  defp waiting_result?({:tool_result, id, _result}, order), do: MapSet.member?(order.waiting, id)
  defp waiting_result?(_event, _order), do: false

  # A `user_message` also closes the message in the session, and gives its
  # open calls an `aborted` result, so it waits as a `message_end` does.
  defp blocked?({:close, _ids, _event}, order), do: MapSet.size(order.waiting) > 0
  defp blocked?({:user_message, _id, _text}, order), do: MapSet.size(order.waiting) > 0
  defp blocked?(_event, _order), do: false

  defp emit({:close, ids, event}, {out, order}),
    do: {[event | out], %{order | waiting: MapSet.new(ids)}}

  defp emit({:tool_result, id, _result} = event, {out, order}),
    do: {[event | out], %{order | waiting: MapSet.delete(order.waiting, id)}}

  defp emit(event, {out, order}), do: {[event | out], order}

  # Sends the held events from the front up to a `message_end` that waits.
  defp flush({out, order}) do
    case :queue.out(order.held) do
      {{:value, event}, rest} ->
        if blocked?(event, order),
          do: {out, order},
          else: flush(emit(event, {out, %{order | held: rest}}))

      {:empty, _rest} ->
        {out, order}
    end
  end
end
