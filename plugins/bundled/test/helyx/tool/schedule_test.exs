defmodule Helyx.Tool.ScheduleTest do
  # The schedule tools over a Hub (`docs/features/coordinator.md`). Not
  # async: the tools read the application env of `helyx_plugins`.
  use ExUnit.Case, async: false

  import Helyx.Test.Events, only: [collect_until: 1]

  alias Helyx.{Event, Hub, Message, Session}
  alias Helyx.Message.ToolCall
  alias Helyx.Provider.Fake
  alias Helyx.Test.HubWake

  @moduletag :tmp_dir

  @missing "AAAAAAAAAAAA"
  @tools [
    Helyx.Tool.Schedule,
    Helyx.Tool.ScheduleList,
    Helyx.Tool.ScheduleDelete
  ]

  setup %{tmp_dir: dir} do
    data = Path.join(dir, "data")
    File.mkdir_p!(data)
    File.chmod!(data, 0o700)
    core = :"core_#{System.unique_integer([:positive])}"

    start_supervised!({Helyx.Core, name: core, plugins: [Fake | @tools], sessions_dir: data},
      id: :core
    )

    hub =
      start_supervised!(
        Supervisor.child_spec({Hub, [core: core, default_owner: "owner"]}, id: :hub)
      )

    {:ok, users} = Hub.users(hub)
    owner = Enum.find(users, &(&1.name == "owner")).id
    {:ok, %{id: ann}} = Hub.add_user(hub, "ann")
    {:ok, %{id: bob}} = Hub.add_user(hub, "bob")

    Application.put_env(:helyx_plugins, :coordinator_hubs, %{core => hub})

    Application.put_env(:helyx_plugins, :coordinator_modes, %{
      "echo" => [model: "fake/echo", tools: []]
    })

    on_exit(fn ->
      Application.delete_env(:helyx_plugins, :coordinator_hubs)
      Application.delete_env(:helyx_plugins, :coordinator_modes)
    end)

    %{core: core, hub: hub, owner: owner, ann: ann, bob: bob, dir: dir}
  end

  # Runs the calls in one coordinator session that `user` started through
  # Hub, each in its own response, and gives the result messages.
  defp coordinate(context, user, calls) do
    model = "coord_#{System.unique_integer([:positive])}"
    :ok = Fake.script(context.core, model, Enum.map(calls, &[&1]) ++ [["Done."]])
    opts = [model: "fake/#{model}", cwd: context.dir]
    {:ok, session} = Hub.start_session(context.hub, user, opts)
    {:ok, _, _} = Session.subscribe(session)
    :ok = Session.prompt(session, "go")
    results(collect_until(:turn_end))
  end

  defp results(events) do
    for %Event{type: :tool_execution_end, data: %{message: message}} <- events, do: message
  end

  defp call(name, args),
    do: %ToolCall{id: "c#{System.unique_integer([:positive])}", name: name, arguments: args}

  defp target(context, user) do
    {:ok, session} = Hub.start_session(context.hub, user, model: "fake/echo", cwd: context.dir)
    session
  end

  defp created_id(%Message{is_error: false} = result) do
    [_, id] = Regex.run(~r/^schedule (\S+):/, Message.text(result))
    id
  end

  defp create(context, user, session, prompt \\ "wake") do
    [created] =
      coordinate(context, user, [
        call("schedule", %{
          "id" => session.id,
          "at" => System.os_time(:second) + 600,
          "prompt" => prompt
        })
      ])

    created
  end

  test "schedule_list shows the schedules, all of them or one session", context do
    session = target(context, context.ann)
    created = create(context, context.ann, session)
    id = created_id(created)

    [all] = coordinate(context, context.ann, [call("schedule_list", %{})])
    assert Message.text(all) =~ "schedule #{id}: session #{session.id}"
    assert Message.text(all) =~ "once"
    assert Message.text(all) =~ "prompt \"wake\""

    [one] = coordinate(context, context.ann, [call("schedule_list", %{"id" => session.id})])
    assert Message.text(one) == Message.text(all)
  end

  test "schedule_list is empty, and it refuses a session that the user may not read", context do
    [empty] = coordinate(context, context.ann, [call("schedule_list", %{})])
    assert Message.text(empty) == "no schedules"

    session = target(context, context.ann)

    [other, missing] =
      coordinate(context, context.bob, [
        call("schedule_list", %{"id" => session.id}),
        call("schedule_list", %{"id" => @missing})
      ])

    assert Message.text(other) == Message.text(missing)
    assert Message.text(other) =~ "no such session runs"
  end

  test "schedule_list shows a prompt with a control byte as escaped text", context do
    session = target(context, context.ann)
    create(context, context.ann, session, "deploy\x01 the build")

    [list] = coordinate(context, context.ann, [call("schedule_list", %{})])
    assert Message.text(list) =~ ~S(prompt "deploy\x01 the build")
  end

  test "schedule_list cuts each prompt to 256 bytes", context do
    session = target(context, context.ann)
    create(context, context.ann, session, String.duplicate("a", 300))

    [list] = coordinate(context, context.ann, [call("schedule_list", %{})])

    assert Message.text(list) =~
             "prompt \"" <> String.duplicate("a", 256) <> "\" (cut, 300 bytes)"

    # A prompt of 256 bytes is whole; a cut inside a character drops it.
    whole = String.duplicate("b", 254) <> "é"
    split = String.duplicate("c", 255) <> "é"
    create(context, context.ann, session, whole)
    create(context, context.ann, session, split)
    [list] = coordinate(context, context.ann, [call("schedule_list", %{})])
    assert Message.text(list) =~ ~r/prompt "b{254}é"$/mu

    assert Message.text(list) =~
             "prompt \"" <> String.duplicate("c", 255) <> "\" (cut, 257 bytes)"

    refute Message.text(list) =~ String.duplicate("a", 257)
  end

  test "schedule_delete removes the schedule; another user gets the text of a missing one",
       context do
    session = target(context, context.ann)
    created = create(context, context.ann, session)
    id = created_id(created)

    [deleted] = coordinate(context, context.ann, [call("schedule_delete", %{"schedule" => id})])
    assert Message.text(deleted) == "deleted schedule #{id}"

    [empty] = coordinate(context, context.ann, [call("schedule_list", %{})])
    assert Message.text(empty) == "no schedules"

    [theirs, missing] =
      coordinate(context, context.bob, [
        call("schedule_delete", %{"schedule" => id}),
        call("schedule_delete", %{"schedule" => @missing})
      ])

    assert Message.text(theirs) == Message.text(missing)
    assert Message.text(theirs) =~ "no such schedule"
  end

  test "bad arguments give an error result", context do
    [bad_id, bad_list, bad_key] =
      coordinate(context, context.ann, [
        call("schedule_delete", %{"schedule" => 7}),
        call("schedule_list", %{"id" => 7}),
        call("schedule_list", %{"other" => 1})
      ])

    assert Message.text(bad_id) =~ "the id must be a schedule id"
    assert Message.text(bad_list) =~ "the id must be a session id"
    assert Message.text(bad_key) =~ "it takes only the optional id of a session"
  end

  test "schedule_list stays under the result bound at the cap of a user", context do
    # 16 sessions of 16 schedules, each prompt of control bytes that
    # `inspect` makes four times longer.
    prompt = String.duplicate("\x01", 300)
    at = System.os_time(:second) + 600

    for _ <- 1..16 do
      session = target(context, context.ann)

      for _ <- 1..16 do
        params = %{"session" => session.id, "at" => at, "prompt" => prompt}
        {:ok, _} = Hub.schedule(context.hub, context.ann, params)
      end
    end

    [list] = coordinate(context, context.ann, [call("schedule_list", %{})])
    text = Message.text(list)
    assert byte_size(text) <= Message.max_result_bytes()
    # Each prompt shows as escaped text, four bytes for each control byte.
    assert text =~ "prompt \"" <> String.duplicate("\\x01", 256) <> "\""
    [_, shown, rest] = Regex.run(~r/\A(.*)\n(\d+) more not shown/s, text)
    assert length(String.split(shown, "\n")) + String.to_integer(rest) == 256
  end

  test "schedule_list shows the last outcome of a schedule", context do
    session = target(context, context.ann)
    id = HubWake.due(context, context.ann, session.id)
    HubWake.poll(context.hub)
    row = HubWake.wait_row(context.hub, id, &(&1.last_outcome == "delivered"))

    [list] = coordinate(context, context.ann, [call("schedule_list", %{})])
    assert Message.text(list) =~ "schedule #{id}: "
    assert Message.text(list) =~ "ended, last run delivered at #{row.last_at}, "
  end
end
