defmodule Helyx.Tool.SubscriptionTest do
  # The coordinator tools `subscription_list` and `subscription_delete`
  # (`docs/features/coordinator.md`, decision 11; `docs/features/hub.md`,
  # decision 17). Not async: the tools read the application env of
  # `helyx_plugins`.
  use ExUnit.Case, async: false

  import Helyx.Test.Events, only: [collect_until: 1]

  alias Helyx.{Event, Hub, Message, Session}
  alias Helyx.Message.ToolCall
  alias Helyx.Provider.Fake

  @moduletag :tmp_dir

  @tools [Helyx.Tool.SubscriptionList, Helyx.Tool.SubscriptionDelete]
  @max_template 16_384

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
        Supervisor.child_spec({Hub, core: core, default_owner: "owner"}, id: :hub)
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

  defp call(name, args),
    do: %ToolCall{id: "c#{System.unique_integer([:positive])}", name: name, arguments: args}

  defp coordinate(context, user, calls) do
    model = "coord_#{System.unique_integer([:positive])}"
    :ok = Fake.script(context.core, model, Enum.map(calls, &[&1]) ++ [["Done."]])
    opts = [model: "fake/#{model}", cwd: context.dir]
    {:ok, session} = Hub.start_session(context.hub, user, opts)

    Task.await(
      Task.async(fn ->
        {:ok, _, _} = Session.subscribe(session)
        :ok = Session.prompt(session, "go")

        for %Event{type: :tool_execution_end, data: %{message: message}} <-
              collect_until(:turn_end),
            do: message
      end)
    )
  end

  defp subscribed(context, user) do
    opts = [model: "fake/echo", cwd: context.dir]
    {:ok, session} = Hub.start_session(context.hub, user, opts)

    {:ok, %{subscription: subscription}} =
      Hub.subscribe(context.hub, user, %{
        "session" => session.id,
        "prompt" => "event: {{payload}}",
        "label" => "hook"
      })

    {session, subscription}
  end

  test "subscription_list shows the subscriptions of the user, never the secret", context do
    {_session, subscription} = subscribed(context, context.ann)

    [result] = coordinate(context, context.ann, [call("subscription_list", %{})])
    assert %Message{is_error: false} = result
    text = Message.text(result)

    assert text =~ "subscription #{subscription.id}"
    assert text =~ "session #{subscription.session}"
    assert text =~ "label hook"
    assert text =~ "endpoint: /hooks/#{subscription.id}"
    assert text =~ "event: {{payload}}"

    # The list of one session.
    [one] =
      coordinate(context, context.ann, [
        call("subscription_list", %{"id" => subscription.session})
      ])

    assert Message.text(one) =~ subscription.id

    # Another user sees none of ann's subscriptions.
    [other] = coordinate(context, context.bob, [call("subscription_list", %{})])
    assert Message.text(other) == "no event subscriptions"
  end

  test "subscription_delete deletes a subscription of the user", context do
    {_session, subscription} = subscribed(context, context.ann)
    {_bob_session, bob_subscription} = subscribed(context, context.bob)

    [other] =
      coordinate(context, context.ann, [
        call("subscription_delete", %{"id" => bob_subscription.id})
      ])

    assert %Message{is_error: true} = other
    assert Message.text(other) =~ "no such event subscription"

    [result] =
      coordinate(context, context.ann, [call("subscription_delete", %{"id" => subscription.id})])

    assert %Message{is_error: false} = result
    assert Message.text(result) == "subscription #{subscription.id} deleted"

    assert {:ok, []} = Hub.subscriptions(context.hub, context.ann, nil)
  end

  test "the list stays under the result bound at the 256-subscription cap", context do
    template = String.duplicate("p", @max_template - 11) <> "{{payload}}"

    for _ <- 1..16 do
      {:ok, session} =
        Hub.start_session(context.hub, context.ann, model: "fake/echo", cwd: context.dir)

      for _ <- 1..16 do
        {:ok, _} =
          Hub.subscribe(context.hub, context.ann, %{
            "session" => session.id,
            "prompt" => template
          })
      end
    end

    [result] = coordinate(context, context.ann, [call("subscription_list", %{})])
    assert %Message{is_error: false} = result
    text = Message.text(result)

    assert byte_size(text) < 60_100
    assert text =~ ~r/\n\d+ more not shown; list the subscriptions of one session/
    assert text =~ "(cut, 16384 bytes)"
  end

  test "a cut template is escaped and marked", context do
    template = "line\n\"q\" " <> String.duplicate("p", 300) <> "{{payload}}"

    {:ok, session} =
      Hub.start_session(context.hub, context.ann, model: "fake/echo", cwd: context.dir)

    {:ok, _} =
      Hub.subscribe(context.hub, context.ann, %{"session" => session.id, "prompt" => template})

    [result] = coordinate(context, context.ann, [call("subscription_list", %{})])
    assert %Message{is_error: false} = result
    text = Message.text(result)

    assert text =~ "(cut, #{byte_size(template)} bytes)"
    assert text =~ ~S(line\n\"q\")
  end
end
