defmodule Helyx.Provider.ClaudeCode.ProgramTurnTest do
  # Program turns, which the program starts by itself when a background task ends.
  use ExUnit.Case, async: true

  import Helyx.Test.ClaudeCodeFake
  import Helyx.Test.Events
  import Helyx.Test.HarnessDriver

  alias Helyx.{Message, Session}
  alias Helyx.Provider.ClaudeCode

  @moduletag :tmp_dir

  setup {Helyx.Test.ClaudeCodeFake, :setup_fake}

  test "a prompt during a program turn gets its own answer, not the program's",
       %{bin: bin, work: work} do
    turn(bin, 1, 1, reply("first"))
    # Observed order: the line is queued at once, the program turn ends,
    # then the line starts as a turn of its own. The program turn's `init`
    # came before the line; the tool call in it was not observed.
    turn(bin, 1, 2, [
      lifecycle("queued"),
      init(),
      delta("program"),
      tool_use("p1", %{command: "ls"}),
      call("n1", 1, "p1"),
      tool_result("p1", "out"),
      program_result("program"),
      lifecycle("started"),
      init(),
      delta("mine"),
      assistant(%{type: "text", text: "mine"}),
      result("mine")
    ])

    {_from, actions, state} =
      request(harness(work), {:turn, "t1", %Helyx.Context{messages: [Message.user("a")]}})

    {_actions, state} = pump(ClaudeCode, state, actions, &ended?/1)
    context = %Helyx.Context{messages: [Message.user("a"), Message.user("b")]}
    {_from, actions, state} = request(state, {:turn, "t2", context})
    {actions, state} = pump(ClaudeCode, state, actions, &ended?/1)

    assert [{:text_delta, "mine"}, {:done, _}] = events_of(actions)
    # A Helyx tool call of the program turn runs nothing.
    :ok = closed(state)
    assert %{"result" => %{"isError" => true}} = answers(bin, 1)["n1"]
  end

  # #240: an `init` with no Helyx turn starts a program turn.
  defp note,
    do: j(%{type: "system", subtype: "task_notification", task_id: "b1", status: "completed"})

  defp saw?(event), do: &Enum.any?(&1, fn action -> match?({:event, _, ^event}, action) end)

  # One turn, then a program turn that the program starts by itself and
  # that is still open after `lines`.
  defp program_turn(bin, work, lines) do
    turn(bin, 1, 1, reply("first") ++ [note(), init() | lines])
    context = %Helyx.Context{messages: [Message.user("a")]}
    {_from, actions, state} = request(harness(work), {:turn, "t1", context})
    {actions, state} = pump(ClaudeCode, state, actions, saw?(:turn_start))
    {actions, state} = pump(ClaudeCode, state, actions, saw?({:text_delta, "program"}))
    [id] = for {:event, id, :turn_start} <- actions, do: id
    {id, state}
  end

  test "a program turn gives its own turn id, its events, and its terminal",
       %{bin: bin, work: work} do
    turn(
      bin,
      1,
      1,
      reply("first") ++ [note(), init(), delta("program"), program_result("program")]
    )

    context = %Helyx.Context{messages: [Message.user("a")]}
    {_from, actions, state} = request(harness(work), {:turn, "t1", context})

    {actions, state} =
      pump(ClaudeCode, state, actions, &(length(Enum.filter(&1, fn a -> ended?([a]) end)) == 2))

    assert [
             {:event, id, :turn_start},
             {:event, id, {:text_delta, "program"}},
             {:event, id, {:done, _}}
           ] =
             Enum.drop_while(actions, &(not match?({:event, _, :turn_start}, &1)))

    assert id =~ ~r/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/
    assert %{turn: nil, notified?: false} = state
  end

  test "a session shows a program turn after its turn, with origin :provider",
       %{bin: bin} = ctx do
    program = [delta("done"), assistant(%{type: "text", text: "done"}), program_result("done")]
    turn(bin, 1, 1, reply("first") ++ [note(), init() | program])

    session = start(ctx)
    prompt(session, "a")
    events = collect_until(:turn_end)

    assert [%{origin: :provider}] = of_type(events, :turn_start)
    assert [%Message{role: :assistant, content: [%Message.Text{text: "done"}]}] = messages(events)

    assert [:user, :assistant, :assistant] =
             Enum.map(:sys.get_state(Session.pid(session)).transcript, & &1.role)
  end

  test "a turn while a program turn runs replaces it, and the program turn's text is lost",
       %{bin: bin, work: work} do
    {id, state} = program_turn(bin, work, [delta("program")])

    turn(bin, 1, 2, [
      lifecycle("queued"),
      delta(" more"),
      program_result("program"),
      lifecycle("started"),
      init(),
      delta("mine"),
      assistant(%{type: "text", text: "mine"}),
      result("mine")
    ])

    context = %Helyx.Context{messages: [Message.user("a"), Message.user("b")]}
    {_from, actions, state} = request(state, {:turn, "t2", context})
    {actions, _state} = pump(ClaudeCode, state, actions, &ended?/1)

    assert [{:text_delta, "mine"}, {:done, _}] = events_of(actions)
    refute Enum.any?(actions, &match?({:event, ^id, _}, &1))
  end

  test "an interrupt of a program turn writes the interrupt with its id",
       %{bin: bin, work: work} do
    {id, state} = program_turn(bin, work, [delta("program")])
    script(bin, "ctl.1", [interrupted(), program_result("")])

    {from, [], state} = request(state, {:interrupt, id})
    {actions, _state} = pump(ClaudeCode, state, [], replied?(from))

    assert {:reply, ^from, :ok} = List.last(actions)
    assert %{"request_id" => "interrupt_" <> ^id} = List.last(stdin(bin, 1))
  end

  # The session was in its idle close wait when the program turn started,
  # so it dropped it; the program turn keeps the program.
  test "an idle close during a program turn answers :busy", %{bin: bin, work: work} do
    {_id, state} = program_turn(bin, work, [delta("program")])
    assert {_from, [{:reply, _, :busy}], _state} = request(state, :idle_close)
  end

  test "end of input during a program turn still gives its terminal, then the close",
       %{bin: bin, work: work} do
    {id, state} = program_turn(bin, work, [delta("program")])
    script(bin, "eof.1", [program_result("program")])

    {from, [], state} = request(state, :close)
    {actions, _state} = pump(ClaudeCode, state, [], replied?(from))
    assert [{:event, ^id, {:done, _}}, {:reply, ^from, :ok}] = actions
  end
end
