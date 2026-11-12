defmodule Helyx.SendTest do
  # The one sender of a text to a session that a stop may unload
  # (docs/features/idle-unload.md): it sends again only when the first send
  # proves that the session took nothing.
  use ExUnit.Case, async: true

  import Helyx.Test.Idle

  alias Helyx.Send
  alias Helyx.Session

  @session %Session{id: "idle_unload1", core: __MODULE__}

  # A send that answers the first value and then `:ok`, with the count of its
  # calls, and a load that counts its calls.
  defp sends(first) do
    counter = :counters.new(2, [])

    send = fn _session ->
      :counters.add(counter, 1, 1)
      if :counters.get(counter, 1) == 1, do: first, else: :ok
    end

    load = fn ->
      :counters.add(counter, 2, 1)
      {:ok, @session}
    end

    {send, load, counter}
  end

  defp count(counter, index), do: :counters.get(counter, index)

  for reason <- [:noproc, {:shutdown, :idle}] do
    test "sends again when the session took nothing: #{inspect(reason)}" do
      {send, load, counter} = sends({:error, {:stopped, unquote(reason)}})

      assert Send.text(@session, send, load) == :ok
      assert count(counter, 1) == 2
      assert count(counter, 2) == 1
    end
  end

  # A session that died in its handler, or a killed one, may have taken the
  # text: no second send (docs/features/hub.md, decision 12).
  for reason <- [:killed, :normal, {:shutdown, :boom}, {:badmatch, :boom}] do
    test "sends once when the session may have taken it: #{inspect(reason)}" do
      {send, load, counter} = sends({:error, {:stopped, unquote(reason)}})

      assert Send.text(@session, send, load) == {:error, :session_not_found}
      assert count(counter, 1) == 1
      assert count(counter, 2) == 0
    end
  end

  test "sends once when the call timed out or the send failed for another reason" do
    {send, load, counter} = sends({:error, :turn_running})
    assert Send.text(@session, send, load) == {:error, :turn_running}
    assert count(counter, 1) == 1 and count(counter, 2) == 0

    {send, load, counter} = sends(:exit)
    assert Send.text(@session, send, load) == :exit
    assert count(counter, 1) == 1 and count(counter, 2) == 0
  end

  test "a failed load is the error of the caller" do
    send = fn _session -> {:error, {:stopped, :noproc}} end
    load = fn -> {:error, :too_many_sessions} end

    assert Send.text(@session, send, load) == {:error, :too_many_sessions}
  end

  # The exact exit reason that the idle stop gives a caller that waits: the
  # sender matches this value, not a guess (docs/features/idle-unload.md).
  @tag :tmp_dir
  test "the exit reason of the idle stop is {:shutdown, :idle}", %{tmp_dir: dir} do
    core = start_core(dir)

    {:ok, session} =
      Helyx.Sessions.start(core, cwd: File.cwd!(), model: "fake/echo")

    arm_timer(session)
    pid = Session.pid(session)
    ref = Process.monitor(pid)
    :sys.suspend(pid)
    Process.sleep(idle_ms() + load_ms())

    call = Task.async(fn -> Session.send_text(session, :prompt, "hi", []) end)
    Helyx.Test.Events.wait_until(fn -> mailbox(pid) == 2 end)
    :sys.resume(pid)

    assert_receive {:DOWN, ^ref, :process, ^pid, {:shutdown, :idle}}
    assert Task.await(call) == {:error, {:stopped, {:shutdown, :idle}}}
  end

  defp start_core(dir) do
    core = :"core_#{System.unique_integer([:positive])}"

    start_supervised!(
      {Helyx.Core, name: core, plugins: [Helyx.Provider.Fake], sessions_dir: dir},
      id: :core
    )

    core
  end

  defp mailbox(pid) do
    {:message_queue_len, n} = Process.info(pid, :message_queue_len)
    n
  end
end
