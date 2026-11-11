defmodule Helyx.ModelContext.CoordinatorTest do
  # The system prompt of the coordinator mode (`docs/features/coordinator.md`).
  # Not async: the modes come from the application env of `helyx_plugins`.
  use ExUnit.Case, async: false

  alias Helyx.ModelContext.Coordinator

  setup do
    on_exit(fn -> Application.delete_env(:helyx_plugins, :coordinator_modes) end)
  end

  defp build(session_id \\ "abc") do
    {:ok, model} = Helyx.ModelRef.parse("fake/echo")
    opts = [model: model, session_id: session_id, cwd: "/nowhere"]
    Coordinator.build(%Helyx.Context{messages: []}, opts).system
  end

  test "the base prompt, the modes, the model, the session, and the time to the minute" do
    Application.put_env(:helyx_plugins, :coordinator_modes, %{"review" => [], "coding" => []})
    system = build()
    assert system =~ "You are a coordinator."

    for tool <- ~w(session_create session_wait session_read session_send schedule schedule_list
                   schedule_delete),
        do: assert(system =~ "\n- #{tool} ")

    assert system =~ "\nModes: coding, review\n"
    assert system =~ "\nModel: fake/echo\n"
    assert system =~ "\nSession id: abc\n"
    [_, iso, posix] = Regex.run(~r/\nTime: (\S+), POSIX (\d+)$/, system)
    {:ok, at, 0} = DateTime.from_iso8601(iso)
    assert at.second == 0
    assert DateTime.to_unix(at) == String.to_integer(posix)
  end

  test "no modes, and a value of many lines stays one capped line" do
    assert build() =~ "\nModes: none\n"
    system = build(String.duplicate("x\n", 5_000))
    [line] = Regex.run(~r/Session id: [^\n]*/, system)
    assert byte_size(line) <= byte_size("Session id: ") + 4_096
  end
end
