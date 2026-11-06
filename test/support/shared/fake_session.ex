defmodule Helyx.Test.FakeSession do
  @moduledoc false
  # A session for hands that a test starts with no session process: it
  # lets each call and hook Task run, as the session does once it handled
  # the record of the Task (`{:asker, turn_id, pid, kind}`,
  # docs/features/hooks.md), and a background run go on after its start
  # answer, and forwards every other message to `test` in the order it
  # got them. It is linked to the caller.
  def start(test \\ self()), do: spawn_link(fn -> loop(test) end)

  defp loop(test) do
    receive do
      {:asker, _turn_id, pid, _kind} ->
        send(pid, :helyx_go)

      {:tool_result, _turn_id, _call_id, {:started, _result, pid}} = message ->
        send(pid, :helyx_go)
        send(test, message)

      message ->
        send(test, message)
    end

    loop(test)
  end
end
