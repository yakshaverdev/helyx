defmodule Helyx.Test.Hands do
  @moduledoc false
  # Fake hands for a tool or a provider that runs outside a session:
  # `Helyx.Tool.hold/1` exits outside the hands. The fake acknowledges each
  # hold and unhold of the caller, keeps the held handles for `held/0`, and
  # sends {:held, handle} to `test` when given. It ends with the caller,
  # and it is not linked, so the links of the caller stay its own.
  import ExUnit.Assertions

  def fake(test \\ nil) do
    caller = self()
    Process.put(:helyx_hands, spawn(fn -> ack(Process.monitor(caller), test, []) end))
    :ok
  end

  # The handles that the fake of the caller holds.
  def held, do: GenServer.call(Process.get(:helyx_hands), :held)

  # Asserts that the fake holds `handles`, the handles of the provider
  # state. `started` is the monotonic ms before the step that launched the
  # last program. When that step took less than the release deadline, it
  # also asserts the command and watchdog of one program only. A slower
  # step can skip a probe of the release, and the handle stays held (#739).
  def assert_one_program(handles, started) do
    in_time? = System.monotonic_time(:millisecond) - started < Helyx.HarnessIO.let_go_ms()
    held = Enum.sort(held())
    assert held == Enum.sort(handles)
    if in_time?, do: assert([command: _, watchdog: _] = held)
  end

  defp ack(ref, test, held) do
    receive do
      {:"$gen_call", from, {:hold, handle}} ->
        if test, do: send(test, {:held, handle})
        GenServer.reply(from, :ok)
        ack(ref, test, [handle | held])

      {:"$gen_call", from, {:unhold, handles}} ->
        GenServer.reply(from, :ok)
        ack(ref, test, held -- handles)

      {:"$gen_call", from, :held} ->
        GenServer.reply(from, held)
        ack(ref, test, held)

      {:DOWN, ^ref, :process, _pid, _reason} ->
        :ok
    end
  end
end
