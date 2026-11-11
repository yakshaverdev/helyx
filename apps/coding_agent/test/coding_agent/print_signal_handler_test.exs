defmodule CodingAgent.Print.SignalHandlerTest do
  use ExUnit.Case, async: true

  alias CodingAgent.Print.Signal

  test "a signal during the stop cannot overwrite the first status" do
    test = self()
    halt = &send(test, {:halt, &1})
    {:ok, state} = Signal.init({halt, nil})

    assert {:ok, stopped} = Signal.handle_event(:sigterm, state)
    assert stopped.phase == {:stopping, 143}
    assert_receive {:halt, 143}

    assert {:ok, ^stopped} = Signal.handle_event(:sigquit, stopped)
    assert {:ok, ^stopped} = Signal.handle_event(:sigusr1, stopped)
    assert {:ok, ^stopped} = Signal.handle_event(:sigterm, stopped)
    refute_receive {:halt, 0}
    assert {:ok, :stopping, ^stopped} = Signal.handle_call(:finish, stopped)
  end

  test "a run that finished first owns the status" do
    {:ok, state} = Signal.init({fn _status -> :ok end, nil})
    assert {:ok, :ok, done} = Signal.handle_call(:finish, state)
    assert done.phase == :finished
  end

  # The handler calls the function that `run/5` registers once, and the
  # halt follows it with the status of the first signal.
  test "the first signal calls the registered end once, and halts with 143" do
    test = self()
    halt = &send(test, {:halt, &1})
    {:ok, state} = Signal.init({halt, nil})
    stop = fn -> send(test, :ended) end
    assert {:ok, :ok, state} = Signal.handle_call({:session, stop}, state)

    assert {:ok, stopped} = Signal.handle_event(:sigterm, state)
    assert stopped.phase == {:stopping, 143}
    assert_receive :ended
    assert_receive {:halt, 143}

    assert {:ok, ^stopped} = Signal.handle_event(:sighup, stopped)
    refute_receive :ended
    refute_receive {:halt, 129}
  end
end
