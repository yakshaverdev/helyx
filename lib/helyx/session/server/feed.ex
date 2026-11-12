defmodule Helyx.Session.Server.Feed do
  @moduledoc false
  # The session feed of a Core (docs/features/session-feed.md): the Live of
  # a session at its open and at each change of status or model, and each
  # event to the watchers of its type. It runs in the session process, a send
  # never blocks, and the session keeps no state for each watcher.

  alias Helyx.{Event, ModelRef}
  alias Helyx.Session.Server.{Flow, State}

  # The mailbox length of a watcher at which the session drops a notice and
  # counts it (session-feed.md, "Bounds").
  @max_queue 256
  def max_queue, do: @max_queue

  def live(%State{} = state) do
    %Helyx.Sessions.Live{
      id: state.id,
      instance_id: state.instance_id,
      cwd: state.cwd,
      model: ModelRef.to_string(state.model),
      status: if(Flow.idle?(state.phase), do: :idle, else: :running)
    }
  end

  # Before the open the session has no instance and sends nothing. The key
  # holds the ModelRef, not its text, so the compare builds nothing.
  def sync(%State{instance_id: nil} = state), do: state

  def sync(%State{} = state) do
    key = {state.instance_id, Flow.idle?(state.phase), state.model}

    if key == state.fed do
      state
    else
      dispatch(state.core, :live, live(state))
      %{state | fed: key}
    end
  end

  def event(core, %Event{type: type} = event), do: dispatch(core, type, event)

  defp dispatch(core, key, payload) do
    Registry.dispatch(Helyx.Core.feed_registry(core), key, fn entries ->
      for {pid, dropped} <- entries, do: deliver(pid, dropped, {:helyx_feed, self(), payload})
    end)
  end

  # The count of the drops is the counter that `Helyx.Sessions.watch/2` gave
  # the watcher; a watcher that is gone leaves its entries to the Registry.
  defp deliver(pid, dropped, message) do
    case Process.info(pid, :message_queue_len) do
      {:message_queue_len, n} when n < @max_queue -> send(pid, message)
      {:message_queue_len, _n} -> :counters.add(dropped, 1, 1)
      nil -> :ok
    end
  end
end
