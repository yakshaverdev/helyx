defmodule Helyx.Test.Burst do
  @moduledoc false
  # A burst of text deltas for a provider stream that runs in the model Task
  # of `Helyx.Provider.Loop`. Before each step of 500 deltas it waits until
  # the session and the provider process each hold fewer than 500 messages,
  # so the burst never meets the bound of 10,000 waiting messages of
  # `Helyx.Session.Stream.send_checked/3`, also on a loaded machine. The
  # subscribers still get the events as fast as the session sends them.

  @step 500

  # `n` deltas of one byte, then done; `opts` are the opts of `stream/3`.
  def stream(n, opts) do
    session = Helyx.Session.pid(%Helyx.Session{id: opts[:session_id], core: opts[:core]})
    [provider | _] = Process.get(:"$callers")

    deltas =
      1..n//1
      |> Stream.chunk_every(@step)
      |> Stream.flat_map(fn step ->
        Enum.each([session, provider], &settle/1)
        Enum.map(step, fn _ -> {:text_delta, "x"} end)
      end)

    Stream.concat(deltas, [{:done, %{stop_reason: :end_turn, usage: nil}}])
  end

  defp settle(pid) do
    case Process.info(pid, :message_queue_len) do
      {:message_queue_len, len} when len >= @step ->
        Process.sleep(1)
        settle(pid)

      _ ->
        :ok
    end
  end
end
