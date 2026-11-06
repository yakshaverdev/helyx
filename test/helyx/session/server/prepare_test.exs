defmodule Helyx.Session.Server.PrepareTest do
  # The `:deadline` option of the prepare Task (#835): the ModelContext and
  # the Compaction plugin read the monotonic time in ms of its kill
  # (docs/features/session-lifecycle.md).
  use ExUnit.Case, async: true

  import Helyx.Test.Events, only: [collect_until: 1]
  import Helyx.Test.SessionCase, only: [start_core: 1, final_text: 1]

  alias Helyx.Session

  # The budget of the prepare Task in this test, and the time that the
  # build leaves before the deadline: the margin for load of the steps
  # after the build, the compaction and the reply.
  @prepare_ms 600
  @load_margin_ms 300

  defmodule DeadlineContext do
    @moduledoc false
    # Sends its `:deadline` and the time of the read to the process
    # registered as `name(core)`. A last message "until <ms>" waits
    # until `ms` before the deadline, then returns.
    @behaviour Helyx.ModelContext

    @impl true
    def build(context, opts) do
      now = System.monotonic_time(:millisecond)
      send(Helyx.Session.Server.PrepareTest.name(opts[:core]), {:build, opts[:deadline], now})

      case Helyx.Message.text(List.last(context.messages)) do
        "until " <> margin ->
          Process.sleep(max(opts[:deadline] - String.to_integer(margin) - now, 0))

        _ ->
          :ok
      end

      %{context | system: "built"}
    end
  end

  defmodule DeadlineCompaction do
    @moduledoc false
    # Sends its `:deadline` as `DeadlineContext` does, and keeps the context.
    @behaviour Helyx.Compaction

    @impl true
    def compact(context, opts) do
      send(Helyx.Session.Server.PrepareTest.name(opts[:core]), {:compact, opts[:deadline]})
      context
    end
  end

  def name(core), do: :"deadline_#{core}"

  setup do
    core = start_core([Helyx.Test.Provider, DeadlineContext, DeadlineCompaction])
    Process.register(self(), name(core))
    %{core: core}
  end

  defp start(core, prepare_ms) do
    {:ok, session} = Session.start(core, model: "test/system")

    :sys.replace_state(Session.pid(session), fn state ->
      put_in(state.deadline_ms.prepare, prepare_ms)
    end)

    {:ok, _, _} = Session.subscribe(session)
    session
  end

  test "both plugins of one prepare Task get its deadline, the start plus the budget",
       %{core: core} do
    # The moduledocs of the two interfaces name this budget.
    assert Session.Server.State.prepare_ms() == 10_000
    session = start(core, Session.Server.State.prepare_ms())
    before = System.monotonic_time(:millisecond)
    :ok = Session.prompt(session, "one")

    assert_receive {:build, deadline, read}
    assert_receive {:compact, ^deadline}
    assert is_integer(deadline)
    # The Task starts after `before` and before the read in the build: an
    # order of two instants, which load cannot break.
    # credo:disable-for-next-line Helyx.Credo.WallClockUpperBound
    assert deadline >= before + Session.Server.State.prepare_ms()
    assert deadline <= read + Session.Server.State.prepare_ms()
    assert final_text(collect_until(:turn_end)) == "built"

    # The next prepare Task has its own deadline.
    before = System.monotonic_time(:millisecond)
    :ok = Session.prompt(session, "two")
    assert_receive {:build, next, _read}
    assert_receive {:compact, ^next}
    # credo:disable-for-next-line Helyx.Credo.WallClockUpperBound
    assert next >= before + Session.Server.State.prepare_ms()
    assert final_text(collect_until(:turn_end)) == "built"
  end

  test "a build that returns before its deadline less a margin does not fail the turn",
       %{core: core} do
    session = start(core, @prepare_ms)
    :ok = Session.prompt(session, "until #{@load_margin_ms}")

    assert_receive {:build, deadline, _read}
    assert_receive {:compact, ^deadline}
    assert System.monotonic_time(:millisecond) >= deadline - @load_margin_ms
    assert final_text(collect_until(:turn_end)) == "built"
  end
end
