defmodule Helyx.Test.Tool.Block do
  @moduledoc false
  # Sends `{:blocked, session_id}` to the process registered as `to`, then
  # sleeps, so a test holds a child session's turn open.
  @behaviour Helyx.Tool

  @impl true
  def name, do: "block"
  @impl true
  def description, do: "Blocks."
  @impl true
  def parameters, do: %{"type" => "object"}

  # run/2 never returns; a kill of its Task ends it.
  @dialyzer {:nowarn_function, run: 2}
  @impl true
  def run(%{"to" => to}, _cwd) do
    send(String.to_existing_atom(to), {:blocked, Helyx.Tool.context().session_id})
    Process.sleep(:infinity)
  end
end
