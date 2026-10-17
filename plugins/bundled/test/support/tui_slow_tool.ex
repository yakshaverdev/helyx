defmodule Helyx.TUI.Test.Tool.Slow do
  @moduledoc false
  # Sleeps, so a TUI test can hold a turn open: while it fills the
  # queues, or while it switches the session.
  @behaviour Helyx.Tool

  @impl true
  def name, do: "slow"
  @impl true
  def description, do: "Sleeps, then echoes."
  @impl true
  def parameters, do: %{"type" => "object"}
  @impl true
  def run(%{"ms" => ms, "text" => text}, _cwd) do
    Process.sleep(ms)
    {:ok, text}
  end
end
