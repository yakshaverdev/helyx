defmodule Helyx.Test.Idle do
  @moduledoc false
  # The setup and the helpers of the tests of the idle stop
  # (docs/features/idle-unload.md): the short idle time, the margin of a wait
  # that must not happen, a subscriber in its own process, and the `:DOWN` of
  # a session.

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

  # The reason of the end of the session, after its `:DOWN`.
  def down(session) do
    pid = Session.pid(session)
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, reason}
    reason
  end
end
