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
end
