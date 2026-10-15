defmodule Helyx.Test.Released do
  @moduledoc false
  # The record of the test releases of `{:report, pid}` handles. A release
  # writes its row, then sends `{:release, mode, handles}` to `pid`. The
  # message comes from a release Task and has no order with the reply of
  # another process, so a test that checks a release at the return of a
  # call reads the row with `take/0` (#592). The table is made in
  # `test_helper.exs`. A row that no test takes stays until the run ends:
  # one small row per release of a `{:report, pid}` handle.

  @table :helyx_test_released

  def new, do: :ets.new(@table, [:named_table, :public, :duplicate_bag])

  def report(handles, mode) do
    for {:report, pid} <- handles do
      :ets.insert(@table, {pid, mode, handles})
      send(pid, {:release, mode, handles})
    end
  end

  # The releases reported to the calling process so far, as
  # `{mode, handles}`, and deletes them.
  def take, do: for({_pid, mode, handles} <- :ets.take(@table, self()), do: {mode, handles})
end
