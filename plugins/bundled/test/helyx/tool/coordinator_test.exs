defmodule Helyx.Tool.CoordinatorTest do
  # The coordinator tools over a Hub (`docs/features/coordinator.md`). Not
  # async: the tools read the application env of `helyx_plugins`.
  use ExUnit.Case, async: false

  import Helyx.Test.Events, only: [collect_until: 1]
  import Helyx.Test.HubWake, only: [in_hub: 2]

  alias Helyx.{Event, Hub, Message, Session}
  alias Helyx.Message.ToolCall
  alias Helyx.Provider.Fake
  alias Helyx.Test.Tool.Block

  @moduletag :tmp_dir

  @missing "AAAAAAAAAAAA"
  @tools [
    Helyx.Tool.SessionCreate,
    Helyx.Tool.SessionSend,
    Helyx.Tool.SessionRead,
    Helyx.Tool.SessionWait,
    Helyx.Tool.Schedule,
    Helyx.Tool.ScheduleList,
    Helyx.Tool.ScheduleDelete
  ]

  setup %{tmp_dir: dir} = context do
    data = Path.join(dir, "data")
    File.mkdir_p!(data)
    File.chmod!(data, 0o700)
    core = :"core_#{System.unique_integer([:positive])}"
    plugins = [Fake, Block | @tools]
    core_opts = if ms = context[:idle_stop_ms], do: [idle_stop_ms: ms], else: []

    start_supervised!(
      {Helyx.Core, [name: core, plugins: plugins, sessions_dir: data] ++ core_opts},
      id: :core
    )

    hub_opts = [
      core: core,
      default_owner: "owner",
      max_live_sessions: Map.get(context, :max_live, 64)
    ]

    hub = start_supervised!(Supervisor.child_spec({Hub, hub_opts}, id: :hub))
    {:ok, users} = Hub.users(hub)
    owner = Enum.find(users, &(&1.name == "owner")).id
    {:ok, %{id: ann}} = Hub.add_user(hub, "ann")
    {:ok, %{id: bob}} = Hub.add_user(hub, "bob")

    Application.put_env(:helyx_plugins, :coordinator_hubs, %{core => hub})

    Application.put_env(:helyx_plugins, :coordinator_modes, %{
      "echo" => [model: "fake/echo", tools: []],
      "broken" => [tools: "all"]
    })

    on_exit(fn ->
      Application.delete_env(:helyx_plugins, :coordinator_hubs)
      Application.delete_env(:helyx_plugins, :coordinator_modes)
    end)

    %{core: core, hub: hub, owner: owner, ann: ann, bob: bob, dir: dir}
  end

  # Runs the calls in one coordinator session that `user` started through
  # Hub (nil: the default owner), each in its own response, and gives the
  # result messages.
  defp coordinate(context, user, calls, extra \\ []) do
    session = coordinator(context, user || context.owner, calls, extra)
    run(session)
  end

  defp coordinator(context, user, calls, extra \\ []) do
    model = "coord_#{System.unique_integer([:positive])}"
    :ok = Fake.script(context.core, model, Enum.map(calls, &[&1]) ++ extra ++ [["Done."]])
    opts = [model: "fake/#{model}", cwd: context.dir]
    {:ok, session} = Hub.start_session(context.hub, user, opts)
    session
  end

  defp run(session) do
    {:ok, _, _} = Session.subscribe(session)
    :ok = Session.prompt(session, "go")
    results(collect_until(:turn_end))
  end

  defp results(events) do
    for %Event{type: :tool_execution_end, data: %{message: message}} <- events, do: message
  end

  defp call(name, args),
    do: %ToolCall{id: "c#{System.unique_integer([:positive])}", name: name, arguments: args}

  defp create(args),
    do: call("session_create", Map.merge(%{"mode" => "echo", "prompt" => "hello there"}, args))

  defp created_id(%Message{is_error: false} = result) do
    [_, id] = Regex.run(~r/^session (\S+) started/, Message.text(result))
    id
  end

  # A session of `user` (nil: the default owner's) that echoes, idle after
  # its first turn. A Task of its own subscribes, so no event of the
  # session reaches the test process.
  defp echo_session(context, user) do
    opts = [model: "fake/echo", cwd: context.dir]

    {:ok, session} =
      if user,
        do: Hub.start_session(context.hub, user, opts),
        else: Session.start(context.core, opts)

    Task.await(
      Task.async(fn ->
        {:ok, _, _} = Session.subscribe(session)
        :ok = Session.prompt(session, "first words")
        collect_until(:turn_end)
      end)
    )

    session
  end

  # A session of `user` whose one turn is held by a blocked call: the test
  # gets `{:blocked, id}` when the call runs, and the turn holds the session
  # (docs/features/idle-unload.md).
  defp blocked_session(context, user) do
    holder = :"block_#{System.unique_integer([:positive])}"
    Process.register(self(), holder)

    :ok =
      Fake.script(context.core, "block", [
        [
          %Message.ToolCall{
            id: "b1",
            name: "block",
            arguments: %{"to" => Atom.to_string(holder)}
          }
        ]
      ])

    opts = [model: "fake/block", cwd: context.dir]
    {:ok, session} = Hub.start_session(context.hub, user, opts)
    session
  end

  # The messages of a session, read by a Task of its own.
  defp messages(session) do
    Task.await(
      Task.async(fn ->
        {:ok, snapshot, _} = Session.subscribe(session)
        snapshot.messages
      end)
    )
  end

  describe "session_create" do
    test "starts a session of the user in the folder with the mode; it outlives the call",
         context do
      [result] = coordinate(context, context.ann, [create(%{"folder" => context.dir})])
      id = created_id(result)
      assert Message.text(result) =~ "and it got the prompt"
      assert Hub.owner(context.hub, id) == {:ok, context.ann}

      session = %Session{id: id, core: context.core}
      assert is_pid(Session.pid(session))

      assert [%{cwd: cwd, model: "fake/echo"}] =
               Enum.filter(Helyx.Sessions.list_live(context.core), &(&1.id == id))

      assert cwd == context.dir
    end

    test "a bad mode, a bad folder, or a bad mode setup gives an error and starts nothing",
         context do
      calls = [
        create(%{"folder" => context.dir, "mode" => "nope"}),
        create(%{"folder" => "relative/folder"}),
        create(%{"folder" => Path.join(context.dir, "missing")}),
        create(%{"folder" => context.dir, "mode" => "broken"}),
        call("session_create", %{"mode" => "echo", "folder" => 1, "prompt" => ""})
      ]

      texts = context |> coordinate(context.ann, calls) |> Enum.map(&Message.text/1)
      assert Enum.at(texts, 0) =~ "no mode nope; the modes are: broken, echo"
      assert Enum.at(texts, 1) =~ "the folder must be the absolute path"
      assert Enum.at(texts, 2) =~ "the folder must be the absolute path"
      assert Enum.at(texts, 3) =~ "the mode broken is not set up right"
      assert Enum.at(texts, 4) =~ "folder must be a string"
      assert length(Helyx.Sessions.list_live(context.core)) == 1
    end

    @tag max_live: 2
    test "the cap of the user gives an error result", context do
      calls = [create(%{"folder" => context.dir}), create(%{"folder" => context.dir})]
      [first, second] = coordinate(context, context.ann, calls)
      refute first.is_error
      assert second.is_error
      assert Message.text(second) =~ "you run as many sessions as you may"
    end

    test "an empty prompt sends none", context do
      [result] = coordinate(context, nil, [create(%{"folder" => context.dir, "prompt" => ""})])
      assert Message.text(result) =~ ~r/^session \S+ started in .* with the mode echo\.$/
    end

    test "with worktree, the session starts in the new worktree", context do
      repo = git_repo(Path.join(context.dir, "repo"))
      sub = Path.join(repo, "apps/web")
      File.mkdir_p!(sub)
      File.write!(Path.join(sub, "keep"), "")
      script = Path.join([repo, ".helyx", "worktree-setup"])
      File.mkdir_p!(Path.dirname(script))
      File.write!(script, "echo ok\n")
      git!(repo, ["add", "."])
      git!(repo, ["commit", "-m", "script"])
      worktree_root(context)

      [rooted, nested] =
        coordinate(context, context.ann, [
          create(%{"folder" => repo, "worktree" => %{"branch" => "task"}}),
          create(%{"folder" => sub, "worktree" => %{"branch" => "nested"}})
        ])

      refute rooted.is_error
      refute nested.is_error

      rooted_text = Message.text(rooted)
      assert rooted_text =~ "on the branch helyx/task (setup ran)"
      [_, root] = Regex.run(~r/in the worktree (\S+) on the branch helyx\/task/, rooted_text)

      [_, path] =
        Regex.run(~r/in the worktree (\S+) on the branch helyx\/nested/, Message.text(nested))

      refute path == root
      assert File.dir?(root)

      live = Helyx.Sessions.list_live(context.core)
      assert [%{cwd: ^root}] = Enum.filter(live, &(&1.id == created_id(rooted)))
      assert [%{cwd: cwd}] = Enum.filter(live, &(&1.id == created_id(nested)))
      assert cwd == Path.join(path, "apps/web")
    end

    @tag max_live: 1
    test "a failure after the add names the worktree, which stays", context do
      repo = git_repo(Path.join(context.dir, "repo"))
      worktree_root(context)

      [result] =
        coordinate(context, context.ann, [
          create(%{"folder" => repo, "worktree" => %{"branch" => "left"}})
        ])

      assert result.is_error
      text = Message.text(result)
      assert text =~ "you run as many sessions as you may"
      [_, path] = Regex.run(~r/the worktree (\S+) on the branch helyx\/left stays/, text)
      assert File.dir?(path)
    end

    test "a mode that does not exist makes no worktree", context do
      repo = git_repo(Path.join(context.dir, "repo"))
      root = worktree_root(context)

      [result] =
        coordinate(context, context.ann, [
          create(%{"folder" => repo, "mode" => "nope", "worktree" => %{"branch" => "none"}})
        ])

      assert Message.text(result) =~ "no mode nope"
      refute File.exists?(root)
    end

    test "a worktree with an unknown key, no branch, or a bad name is refused by its checks",
         context do
      calls = [
        create(%{"folder" => context.dir, "worktree" => %{"branch" => "task", "extra" => 1}}),
        create(%{"folder" => context.dir, "worktree" => %{}}),
        create(%{"folder" => context.dir, "worktree" => %{"branch" => "Bad"}})
      ]

      texts = context |> coordinate(context.ann, calls) |> Enum.map(&Message.text/1)
      assert Enum.at(texts, 0) =~ "worktree.extra is not an argument"
      assert Enum.at(texts, 1) =~ "worktree.branch is required"
      assert Enum.at(texts, 2) =~ "the branch must be 1 to 64 bytes"
    end

    test "its record names the calling session as a thread", context do
      session = coordinator(context, context.owner, [create(%{"folder" => context.dir})])
      [result] = run(session)
      id = created_id(result)

      row =
        in_hub(context.hub, fn state ->
          {:ok, row} = state.store.record(state.db, id)
          row
        end)

      assert %{parent_id: parent_id, parent_kind: "thread"} = row
      assert parent_id == session.id
    end
  end

  test "no Hub for the Core gives an error result", context do
    Application.put_env(:helyx_plugins, :coordinator_hubs, %{})
    [result] = coordinate(context, nil, [create(%{"folder" => context.dir})])
    assert result.is_error
    assert Message.text(result) =~ "no Hub serves this server"
  end

  describe "the user of a coordinator session" do
    test "a session that Hub did not start acts for no user", context do
      model = "around_#{System.unique_integer([:positive])}"
      :ok = Fake.script(context.core, model, [[create(%{"folder" => context.dir})], ["Done."]])
      {:ok, session} = Session.start(context.core, model: "fake/#{model}", cwd: context.dir)
      [result] = run(session)
      assert Message.text(result) =~ "this session acts for no user"
      assert length(Helyx.Sessions.list_live(context.core)) == 1
    end

    test "a deleted record or a removed user takes the rights of the session; the default owner's do not pass to it",
         context do
      secret = echo_session(context, nil)
      read = call("session_read", %{"id" => secret.id})
      {Helyx.Hub.Access, arg} = Hub.authority(context.hub)

      deleted = coordinator(context, context.ann, [read])

      assert {:ok, %{}} =
               Helyx.Hub.Access.run(
                 arg,
                 %{user: context.ann, token: nil},
                 "hub.records.delete",
                 %{
                   "session" => deleted.id
                 }
               )

      removed = coordinator(context, context.bob, [read])
      :ok = Hub.remove_user(context.hub, context.bob)

      for session <- [deleted, removed] do
        [result] = run(session)
        assert Message.text(result) =~ "this session acts for no user"
        refute Message.text(result) =~ "first words"
      end
    end
  end

  describe "session_send" do
    test "prompts a session of the user; another user gets the answer of a missing one",
         context do
      session = echo_session(context, context.ann)

      [sent] =
        coordinate(context, context.ann, [
          call("session_send", %{"id" => session.id, "text" => "again"})
        ])

      assert Message.text(sent) == "sent to session #{session.id} as prompt"

      # The echo turn of the text ran; the text has the product origin.
      wait_until(fn -> length(messages(session)) == 4 end)
      assert [_, _, %Message{origin: %{kind: :product}, role: :user}, _] = messages(session)

      calls = [
        call("session_send", %{"id" => session.id, "text" => "x"}),
        call("session_send", %{"id" => @missing, "text" => "x"}),
        call("session_send", %{"id" => session.id, "text" => "x", "disposition" => "shout"})
      ]

      [other, missing, bad] = coordinate(context, context.bob, calls)
      assert Message.text(other) == Message.text(missing)
      assert Message.text(other) =~ "no such session runs"
      assert Message.text(bad) =~ "disposition must be one of"
    end

    test "a text over the bound of a prompt gives an error", context do
      session = echo_session(context, context.ann)
      text = String.duplicate("a", Session.max_text_bytes() + 1)

      [result] =
        coordinate(context, context.ann, [
          call("session_send", %{"id" => session.id, "text" => text})
        ])

      assert Message.text(result) =~ "text must be a string of at most"
    end

    test "a null disposition is an absent one, so it is the default", context do
      session = echo_session(context, context.ann)

      [sent] =
        coordinate(context, context.ann, [
          call("session_send", %{"id" => session.id, "text" => "x", "disposition" => nil})
        ])

      assert Message.text(sent) == "sent to session #{session.id} as prompt"
    end

    # A coordinator could reach a session that it started at any later time
    # before the idle stop; the load keeps that (docs/features/idle-unload.md).
    # The target's turn is held by a blocked call, so nothing in the test
    # races the idle stop.
    @tag idle_stop_ms: Helyx.Test.Idle.idle_ms()
    test "a session that its idle stop unloaded gets the text, and keeps the starter", context do
      session = blocked_session(context, context.ann)
      wait_until(fn -> Session.pid(session) == nil end, 500)

      [sent, missing] =
        coordinate(context, context.ann, [
          call("session_send", %{"id" => session.id, "text" => "again"}),
          call("session_send", %{"id" => @missing, "text" => "x"})
        ])

      assert Message.text(sent) == "sent to session #{session.id} as prompt"
      assert Message.text(missing) =~ "no such session runs"

      # The load took the place of the user and bound the starter, as the
      # wire `resume` does.
      assert Hub.actor(context.hub, session.id) == {:ok, context.ann}

      # The turn of the text runs in the loaded session.
      assert_receive {:blocked, id}
      assert id == session.id
    end
  end

  describe "session_read" do
    # A session that a stop unloaded is read from its file, and a wait on it
    # answers at once, as on a live idle session (docs/features/idle-unload.md).
    test "a stopped session is read from its file, and a wait answers at once", context do
      session = echo_session(context, context.ann)
      :ok = Helyx.Sessions.stop(session)

      [read, wait] =
        coordinate(context, context.ann, [
          call("session_read", %{"id" => session.id}),
          call("session_wait", %{"ids" => [session.id]})
        ])

      text = Message.text(read)
      assert text =~ "session #{session.id}, no turn runs"
      assert text =~ "user: first words"
      assert text =~ "assistant: first words"
      assert Message.text(wait) =~ "no turn runs"
    end

    test "the transcript of a session; another user gets the answer of a missing one", context do
      session = echo_session(context, context.ann)
      [read] = coordinate(context, context.ann, [call("session_read", %{"id" => session.id})])
      text = Message.text(read)
      assert text =~ "session #{session.id}, no turn runs"
      assert text =~ "user: first words"
      assert text =~ "assistant: first words"

      [other, missing] =
        coordinate(context, context.bob, [
          call("session_read", %{"id" => session.id}),
          call("session_read", %{"id" => @missing})
        ])

      assert Message.text(other) == Message.text(missing)
    end

    test "a null question is an absent one, so no child reads the transcript", context do
      session = echo_session(context, context.ann)

      [read] =
        coordinate(context, context.ann, [
          call("session_read", %{"id" => session.id, "question" => nil})
        ])

      assert Message.text(read) =~ "session #{session.id}, no turn runs"
    end

    test "with a question, a child reads the transcript and gives its answer", context do
      session = echo_session(context, context.ann)
      question = call("session_read", %{"id" => session.id, "question" => "what was said?"})
      # The child has the coordinator's model, so it takes the next response.
      [answer] = coordinate(context, context.ann, [question], [["Two words."]])
      assert Message.text(answer) == "Two words."
    end

    test "the render keeps the newest messages within the budget" do
      messages = for n <- 1..50, do: Message.user("message #{n} " <> String.duplicate("é", 100))
      snapshot = %{messages: messages, older: 0, turn: nil}

      for budget <- [300, 1_000, 5_000] do
        text = Helyx.Tool.SessionRead.render("id", snapshot, budget)
        assert byte_size(text) <= budget
        assert String.valid?(text)
        assert text =~ "[earlier messages left out]"
        assert String.ends_with?(text, "\n\n")
        assert text =~ "message 50"
      end

      all = Helyx.Tool.SessionRead.render("id", snapshot, 1_000_000)
      refute all =~ "left out"
      assert all =~ "message 1 "
    end
  end

  describe "session_wait" do
    test "an idle session answers at once; a turn end ends the wait", context do
      idle = echo_session(context, nil)
      Process.register(self(), :"wait_#{context.core}")
      model = "blocked_#{System.unique_integer([:positive])}"
      blocker = call("block", %{"to" => "wait_#{context.core}"})
      :ok = Fake.script(context.core, model, [[blocker]])
      {:ok, busy} = Session.start(context.core, model: "fake/#{model}", cwd: context.dir)
      :ok = Session.prompt(busy, "go")
      assert_receive {:blocked, _}

      task =
        Task.async(fn ->
          coordinate(context, nil, [
            call("session_wait", %{"ids" => [idle.id]}),
            call("session_wait", %{"ids" => [busy.id], "deadline" => 60})
          ])
        end)

      # The wait subscribed: the busy session has its subscriber.
      wait_until(fn -> map_size(:sys.get_state(Session.pid(busy)).subscribers) == 1 end)
      :ok = Session.abort(busy)
      [first, second] = Task.await(task)
      assert Message.text(first) == "session #{idle.id}: no turn runs"
      assert Message.text(second) == "session #{busy.id}: the turn ended (aborted)"
    end

    @tag :slow
    test "a wait past its deadline tells the model to wait again", context do
      Process.register(self(), :"late_#{context.core}")
      model = "late_#{System.unique_integer([:positive])}"
      :ok = Fake.script(context.core, model, [[call("block", %{"to" => "late_#{context.core}"})]])
      {:ok, busy} = Session.start(context.core, model: "fake/#{model}", cwd: context.dir)
      :ok = Session.prompt(busy, "go")
      assert_receive {:blocked, _}
      started = System.monotonic_time(:millisecond)
      wait = call("session_wait", %{"ids" => [busy.id], "deadline" => 1})
      [result] = coordinate(context, nil, [wait])
      assert Message.text(result) =~ "within 1 s; call session_wait again"
      assert System.monotonic_time(:millisecond) - started >= 1_000
    end

    test "a null deadline is an absent one, so it is the default", context do
      idle = echo_session(context, context.ann)

      [wait] =
        coordinate(context, context.ann, [
          call("session_wait", %{"ids" => [idle.id], "deadline" => nil})
        ])

      assert Message.text(wait) == "session #{idle.id}: no turn runs"
    end

    test "bad ids or a bad deadline give an error; another user gets the answer of a missing one",
         context do
      session = echo_session(context, context.ann)

      calls = [
        call("session_wait", %{"ids" => []}),
        call("session_wait", %{"ids" => List.duplicate(session.id, 65)}),
        call("session_wait", %{"ids" => [session.id], "deadline" => 0}),
        call("session_wait", %{"ids" => [session.id], "deadline" => 3_601}),
        call("session_wait", %{"ids" => [session.id]}),
        call("session_wait", %{"ids" => [@missing]})
      ]

      texts = context |> coordinate(context.bob, calls) |> Enum.map(&Message.text/1)
      assert Enum.at(texts, 0) =~ "ids must be a list of 1 to 64"
      assert Enum.at(texts, 1) =~ "ids must be a list of 1 to 64"
      assert Enum.at(texts, 2) =~ "deadline must be"
      assert Enum.at(texts, 3) =~ "deadline must be"

      assert String.replace(Enum.at(texts, 4), session.id, "X") ==
               String.replace(Enum.at(texts, 5), @missing, "X")
    end
  end

  describe "schedule" do
    test "a wake-up of a session of the user; the Hub rules hold", context do
      session = echo_session(context, context.ann)
      at = System.os_time(:second) + 600

      calls = [
        call("schedule", %{"id" => session.id, "at" => at, "prompt" => "wake"}),
        call("schedule", %{"id" => session.id, "at" => at, "prompt" => "wake", "every" => 300}),
        call("schedule", %{"id" => session.id, "at" => at - 1_200, "prompt" => "wake"})
      ]

      [once, every, past] = coordinate(context, context.ann, calls)
      assert Message.text(once) =~ ~r/^schedule \S+: session #{session.id} at #{at} once$/
      assert Message.text(every) =~ "each 300 s"
      assert Message.text(past) =~ "at must be from now to 366 days on"

      [other] =
        coordinate(context, context.bob, [
          call("schedule", %{"id" => session.id, "at" => at, "prompt" => "x"})
        ])

      assert Message.text(other) =~ "no such session runs"
    end
  end

  defp wait_until(fun, tries \\ 200) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("the condition did not hold")
      true -> Process.sleep(10) && wait_until(fun, tries - 1)
    end
  end

  defp git_repo(dir) do
    File.mkdir_p!(dir)
    git!(dir, ["init"])
    git!(dir, ["commit", "--allow-empty", "-m", "one"])
    dir
  end

  # The worktree root of the test, put back at its end. The tools read the
  # application env of `helyx_plugins`.
  defp worktree_root(context) do
    root = Path.join(context.dir, "worktrees")
    previous = Application.get_env(:helyx_plugins, :worktree_root)
    Application.put_env(:helyx_plugins, :worktree_root, root)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:helyx_plugins, :worktree_root, previous),
        else: Application.delete_env(:helyx_plugins, :worktree_root)
    end)

    root
  end

  defp git!(dir, args) do
    {out, 0} =
      System.cmd("git", ["-c", "user.name=t", "-c", "user.email=t@t" | args],
        cd: dir,
        stderr_to_stdout: true
      )

    out
  end
end
