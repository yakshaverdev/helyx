defmodule Helyx.Test.Hands do
  @moduledoc false
  # Fake hands for a tool or a provider that runs outside a session:
  # `Helyx.Tool.hold/1` exits outside the hands. The fake acknowledges each
  # hold of the caller, and sends {:held, handle} to `test` when given. It
  # ends with the caller, and it is not linked, so the links of the caller
  # stay its own.

  def fake(test \\ nil) do
    caller = self()
    Process.put(:helyx_hands, spawn(fn -> ack(Process.monitor(caller), test) end))
    :ok
  end

  defp ack(ref, test) do
    receive do
      {:"$gen_call", from, {:hold, handle}} ->
        if test, do: send(test, {:held, handle})
        GenServer.reply(from, :ok)
        ack(ref, test)

      {:DOWN, ^ref, :process, _pid, _reason} ->
        :ok
    end
  end
end
