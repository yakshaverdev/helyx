defmodule Helyx.Test.LateClient do
  @moduledoc false
  # A second client of a session: a linked process that subscribes, sends
  # the test its snapshot and then each event, steers on request, and ends
  # on :disconnect.
  import ExUnit.Assertions

  alias Helyx.{Event, Session}

  # Starts the client; returns its pid and its snapshot.
  def connect(session) do
    test = self()

    client =
      spawn_link(fn ->
        {:ok, snapshot} = Session.subscribe(session)
        send(test, {:snapshot, self(), snapshot})
        serve(session, test)
      end)

    assert_receive {:snapshot, ^client, snapshot}
    {client, snapshot}
  end

  # The client sends a steer, and the test checks its reply.
  def steer(client, text) do
    send(client, {:steer, text})
    assert_receive {:steered, ^client, :ok}
  end

  # The events of the client up to and including an agent_end.
  def events_to_end(client, acc \\ []) do
    receive do
      {:event, ^client, %Event{type: :agent_end} = event} -> Enum.reverse([event | acc])
      {:event, ^client, event} -> events_to_end(client, [event | acc])
    after
      Helyx.Test.Events.turn_ms() -> flunk("the second client got no agent_end")
    end
  end

  # Ends the client and waits until it is gone.
  def disconnect(client) do
    ref = Process.monitor(client)
    send(client, :disconnect)
    assert_receive {:DOWN, ^ref, :process, ^client, _reason}
  end

  defp serve(session, test) do
    receive do
      {:helyx_event, %Event{} = event} ->
        send(test, {:event, self(), event})
        serve(session, test)

      {:steer, text} ->
        send(test, {:steered, self(), Session.steer(session, text)})
        serve(session, test)

      :disconnect ->
        :ok
    end
  end
end
