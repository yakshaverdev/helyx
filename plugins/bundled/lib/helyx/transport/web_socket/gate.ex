defmodule Helyx.Transport.WebSocket.Gate do
  @moduledoc false
  # The cap of connections of one server. A connection process enters once
  # at its upgrade, and its place is free when it exits.

  use GenServer

  def start_link(max), do: GenServer.start_link(__MODULE__, max)

  # `:ok`, or `:full` at the cap.
  def enter(gate), do: GenServer.call(gate, :enter)

  # Closes the gate, so a later `enter/1` gets `:full`, and gives the
  # connection processes inside: the gate monitors only them.
  def close(gate), do: GenServer.call(gate, :close)

  @impl true
  def init(max), do: {:ok, {max, MapSet.new()}}

  @impl true
  def handle_call(:enter, {pid, _tag}, {max, inside}) do
    if MapSet.size(inside) < max,
      do: {:reply, :ok, {max, MapSet.put(inside, Process.monitor(pid))}},
      else: {:reply, :full, {max, inside}}
  end

  def handle_call(:close, _from, {_max, inside}) do
    {:monitors, monitors} = Process.info(self(), :monitors)
    {:reply, for({:process, pid} <- monitors, do: pid), {0, inside}}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, {max, inside}),
    do: {:noreply, {max, MapSet.delete(inside, ref)}}
end
