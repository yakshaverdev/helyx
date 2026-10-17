defmodule Helyx.Transport.WebSocket.Gate do
  @moduledoc false
  # The cap of connections of one server. A connection process enters once
  # at its upgrade, and its place is free when it exits.

  use GenServer

  def start_link(max), do: GenServer.start_link(__MODULE__, max)

  # `:ok`, or `:full` at the cap.
  def enter(gate), do: GenServer.call(gate, :enter)

  @impl true
  def init(max), do: {:ok, {max, MapSet.new()}}

  @impl true
  def handle_call(:enter, {pid, _tag}, {max, inside}) do
    if MapSet.size(inside) < max,
      do: {:reply, :ok, {max, MapSet.put(inside, Process.monitor(pid))}},
      else: {:reply, :full, {max, inside}}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, {max, inside}),
    do: {:noreply, {max, MapSet.delete(inside, ref)}}
end
