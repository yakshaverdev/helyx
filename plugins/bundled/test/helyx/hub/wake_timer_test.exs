defmodule Helyx.Hub.WakeTimerTest do
  # The app env is global: the other tests of the Hub run with the timer off.
  use ExUnit.Case, async: false

  import Helyx.Test.HubWake

  alias Helyx.Test.Events

  @moduletag :tmp_dir

  setup do
    Application.put_env(:helyx_plugins, :hub_poll_timer, true)
    on_exit(fn -> Application.put_env(:helyx_plugins, :hub_poll_timer, false) end)
  end

  # The timer of the next poll: armed for at most 1,000 ms. `false` when it
  # fired while this read ran; its poll then comes next.
  defp armed(hub) do
    {timer, ms} = in_hub(hub, &{&1.wake.poll, Process.read_timer(&1.wake.poll)})
    assert ms == false or ms in 0..1_000
    timer
  end

  # The poll at the start runs before the schedule is due, so a poll of the
  # timer sends it; each poll after it finds no row and arms the timer again.
  @tag :slow
  test "the Hub polls by its own timer and arms it again at each poll", context do
    context = serve(context)
    {:ok, session} = Helyx.Sessions.start(context.core, cwd: File.cwd!(), model: "fake/echo")
    id = due(context, context.owner, session.id)
    wait_row(context.hub, id, &(&1.last_outcome == "delivered"))
    assert [{"wake up", _}] = woken(context.core, session.id)

    for _ <- 1..2 do
      timer = armed(context.hub)
      Events.wait_until(fn -> in_hub(context.hub, & &1.wake.poll) != timer end)
    end

    armed(context.hub)
  end
end
