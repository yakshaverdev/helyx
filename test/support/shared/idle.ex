defmodule Helyx.Test.Idle do
  @moduledoc false
  # The setup and the helpers of the tests of the idle stop
  # (docs/features/idle-unload.md): the short idle time, the margin of a wait
  # that must not happen, a subscriber in its own process, the monitor of a
  # session, and the test seam that arms the timer when the test is ready.

  import ExUnit.Assertions

  alias Helyx.Session

  # The idle stop of a test: short, so a stop comes at once.
  @idle_ms 100
  def idle_ms, do: @idle_ms
  # The margin of a wait that must not happen: the stop of the session and
  # load on the machine.
  @load_ms 250
  def load_ms, do: @load_ms

  def start(core, opts), do: Helyx.Sessions.start(core, Keyword.merge([model: "test/ok"], opts))

  def state(session), do: :sys.get_state(Session.pid(session))

  # The idle stop of the session, set when the test is ready. A test starts
  # its Core with no idle option, so the open arms nothing, and no step of
  # the test races the wait. `quiet/2` arms the timer now: the session's
  # `{:unsubscribe, pid}` is a fact change that arms it, and no test depends
  # on the 100 ms (AGENTS.md, #193).
  def set_idle(session, ms \\ idle_ms()) do
    :sys.replace_state(Session.pid(session), fn state ->
      put_in(state.deadline_ms.idle_stop, ms)
    end)
  end

  def quiet(session, ms \\ idle_ms()) do
    set_idle(session, ms)
    send(Session.pid(session), {:unsubscribe, self()})

    Helyx.Test.Events.wait_until(
      fn -> state(session).idle_stop != nil end,
      Helyx.Test.Events.wait_ms(),
      "the idle stop to arm"
    )
  end

  # The timer of the idle stop, armed by the test with the session's message,
  # so a test can suspend the session and let the timer fire into its mailbox
  # before a call. `set_idle` stays nil: the stop does not need the option.
  def arm_timer(session, ms \\ idle_ms()) do
    pid = Session.pid(session)
    ref = :erlang.start_timer(ms, pid, :idle_stop)
    :sys.replace_state(pid, fn state -> %{state | idle_stop: ref} end)
    ref
  end

  # A subscriber in its own process, so that a test ends the subscription
  # without ending itself. It forwards the events to the test. `:stop` ends
  # it, and its `:DOWN` removes the entry of the session.
  def watch(session, opts \\ []) do
    test = self()

    pid =
      spawn_link(fn ->
        {:ok, _snapshot, _ref} = Session.subscribe(session, opts)
        send(test, {:watching, self()})
        forward(test)
      end)

    assert_receive {:watching, ^pid}
    pid
  end

  defp forward(test) do
    receive do
      {:helyx_event, _event} = message ->
        send(test, message)
        forward(test)

      :stop ->
        :ok
    end
  end

  # Ends the subscription and waits until the session removed the entry.
  def unwatch(watcher, session) do
    send(watcher, :stop)

    Helyx.Test.Events.wait_until(
      fn -> state(session).subscribers == %{} end,
      Helyx.Test.Events.wait_ms(),
      "the subscriber entry to leave"
    )
  end

  # The monitor of the session, taken before the step that makes it quiet: a
  # session that stops at that step gives its `:DOWN` to it, and a test never
  # reads the pid after the stop.
  def monitor(session) do
    pid = Session.pid(session)
    {pid, Process.monitor(pid)}
  end

  # The reason of the end of the session, from the monitor taken before the
  # step that made it quiet.
  def down({pid, ref}) do
    assert_receive {:DOWN, ^ref, :process, ^pid, reason}
    reason
  end
end
