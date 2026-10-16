defmodule Helyx.Session.Hands.Release do
  @moduledoc false
  # The release of the handles of `Helyx.Session.Hands`: one call of each
  # tool's `release/3`, with one deadline, and the rule of what it confirms
  # (docs/features/tool-resource-release.md).

  # Calls `release/3` of each tool with its handles, one Task per tool, in
  # parallel, with one deadline. A Task that is still running at the
  # deadline is killed, and the wait returns only when it is gone. Returns
  # the handles still held, per tool. A reply that arrives before the kill
  # counts, because the release did return. A release that raises, exits, times
  # out, or returns anything but a proper list of given handles confirms
  # none of them. A tool with no handles gets no call.
  def run(by_tool, mode, ms, core) do
    deadline = System.monotonic_time(:millisecond) + ms
    supervisor = Helyx.Core.task_supervisor(core)

    tasks =
      for {tool, handles} <- by_tool, handles != [] do
        {tool, handles,
         Task.Supervisor.async(supervisor, tool, :release, [handles, mode, deadline])}
      end

    timeout = max(deadline - System.monotonic_time(:millisecond), 0)

    results =
      Task.yield_many(Enum.map(tasks, &elem(&1, 2)), timeout: timeout, on_timeout: :kill_task)

    for {{tool, handles, _task}, {_task2, result}} <- Enum.zip(tasks, results),
        left = still_held(result, handles),
        left != [],
        into: %{},
        do: {tool, left}
  end

  defp still_held({:ok, left}, handles) when is_list(left) do
    if List.improper?(left) or left -- handles != [], do: handles, else: left
  end

  defp still_held(_failed, handles), do: handles

  def add(a, b), do: Map.merge(a, b, fn _tool, x, y -> x ++ y end)

  def error(left) when left == %{}, do: nil

  # The handles are plugin terms, so they go to the log, not to the text.
  def error(left) do
    Helyx.Reason.log("a resource could not be released", left)
    {:error, "a resource of the call could not be released"}
  end
end
