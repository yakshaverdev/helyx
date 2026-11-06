defmodule Helyx.SessionsEditCopyTest do
  # The mode of the copy of a removal (#833, docs/features/session-edit.md,
  # "Ownership"). It traces calls of every new process, so it runs alone.
  use ExUnit.Case, async: false

  alias Helyx.{Message, Sessions}
  alias Helyx.Session.File, as: SessionFile

  @moduletag :tmp_dir

  test "the copy has mode 0600 before its first byte", %{tmp_dir: dir} do
    core = :"core_#{System.unique_integer([:positive])}"

    start_supervised!(
      {Helyx.Core, name: core, plugins: [Helyx.Test.Provider], sessions_dir: dir},
      id: core
    )

    id = Helyx.Session.Id.new()
    {:ok, file} = SessionFile.create(dir, id, "/repo", "test/ok")

    [a, b] =
      for text <- ["a", "b"],
          do: %{Message.user(text) | id: Helyx.Session.Id.new()}

    file |> SessionFile.append_message(a) |> SessionFile.append_message(b)
    File.chmod!(file.path, 0o644)
    tmp = file.path <> ".tmp"

    :erlang.trace_pattern({File, :chmod, 2}, true, [:global])
    :erlang.trace_pattern({:file, :write, 2}, true, [:global])
    :erlang.trace(:new_processes, true, [:call])

    try do
      assert Sessions.remove_message(core, id, a.id) == {:ok, [a.id]}
    after
      :erlang.trace(:new_processes, false, [:call])
      :erlang.trace_pattern({File, :chmod, 2}, false, [:global])
      :erlang.trace_pattern({:file, :write, 2}, false, [:global])
    end

    # The trace of one process is in order: the chmod of the copy to 0600
    # comes before the first write of the Task.
    events = for {:trace, _pid, :call, _call} = event <- messages(), do: event
    assert [{:trace, task, :call, _} | _] = Enum.drop_while(events, &(not chmod?(&1, tmp)))

    assert [{:trace, ^task, :call, {File, :chmod, [^tmp, 0o600]}} | _] =
             Enum.filter(
               events,
               &(match?({:trace, ^task, :call, {:file, :write, _}}, &1) or chmod?(&1, tmp))
             )

    assert Enum.any?(events, &match?({:trace, ^task, :call, {:file, :write, _}}, &1))
    assert File.stat!(file.path).mode |> Bitwise.band(0o777) == 0o644
  end

  defp chmod?(event, tmp), do: match?({:trace, _, :call, {File, :chmod, [^tmp, _]}}, event)

  defp messages, do: elem(Process.info(self(), :messages), 1)
end
