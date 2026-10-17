defmodule Helyx.Session.HandsTest do
  # The hands' handle bookkeeping, driven directly with the test process as
  # the session. The hold test tools release, keep, or fail on the handles
  # they get, so no OS resource is needed.
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog, only: [with_log: 1]
  import Helyx.Test.Events, only: [wait_ms: 0]

  alias Helyx.Message.ToolCall
  alias Helyx.Test.Gate
  alias Helyx.Test.Released

  setup do
    core = :"core_#{System.unique_integer([:positive])}"

    plugins = [
      Helyx.Test.Provider,
      Helyx.Test.Tool.Hold,
      Helyx.Test.Tool.HoldTwo,
      Helyx.Test.Tool.HoldBare,
      Helyx.Test.Tool.Raise,
      Helyx.Test.Tool.Odd,
      Helyx.Test.Tool.Upcase,
      Helyx.Test.Tool.Background
    ]

    start_supervised!({Helyx.Core, name: core, plugins: plugins})
    %{core: core}
  end

  defp start_hands(core, opts \\ []) do
    {:ok, tools} = Helyx.Tool.specs(core)

    opts =
      [
        core: core,
        cwd: File.cwd!(),
        background_dir:
          Path.join(System.tmp_dir!(), "helyx-hands-#{System.unique_integer([:positive])}"),
        session: self(),
        tools: Map.new(tools, fn {tool, spec} -> {spec.name, tool} end)
      ] ++ opts

    {:ok, hands} = Helyx.Session.Hands.start_link(opts)
    # `await_held/2` waits for the hold calls that the trace shows.
    :erlang.trace(hands, true, [:receive])
    hands
  end

  defp call(id, name, arguments), do: %ToolCall{id: id, name: name, arguments: arguments}

  defp cancel(hands, turn_id) do
    request = Helyx.Session.Hands.request_cancel(hands, turn_id)
    {:reply, result} = :gen_server.receive_response(request, :infinity)
    result
  end

  defp upcase(hands, id) do
    :ok = Helyx.Session.Hands.run(hands, "t1", call(id, "upcase", %{"text" => "hi"}))
    assert_receive {:tool_result, "t1", ^id, result}
    result
  end

  test "a handle that the tool let go of gets no release", %{core: core} do
    hands = start_hands(core)
    arguments = %{"handles" => [{:report, self()}, :keep], "unhold" => [:keep, :never_held]}
    :ok = Helyx.Session.Hands.run(hands, "t1", call("c1", "hold", arguments))
    assert_receive {:tool_result, "t1", "c1", {:ok, "held"}}
    assert [{:deliver, [{:report, _pid}]}] = Released.take()
  end

  test "an unconfirmed handle gives an error result and refuses every later call",
       %{core: core} do
    hands = start_hands(core)
    handles = [:keep, {:report, self()}]

    # The handle is a plugin term: the log has it, the text does not.
    {text, log} =
      with_log(fn ->
        :ok = Helyx.Session.Hands.run(hands, "t1", call("c1", "hold", %{"handles" => handles}))
        assert_receive {:tool_result, "t1", "c1", {:error, text}}
        text
      end)

    assert text == "a resource of the call could not be released"
    assert log =~ ":keep"
    assert [{:deliver, _handles}] = Released.take()

    # Each later call and provider start is refused, with a text with no
    # handle, and the kept handle gets no second release.
    for id <- ["c2", "c3"] do
      assert {:error, text} = upcase(hands, id)
      assert text == "a resource from an earlier call could not be released; the call was not run"

      ref = Helyx.Session.Hands.start_provider(hands, Helyx.Test.Provider, & &1)
      assert_receive {:provider_start, ^ref, {:error, ^text}}
    end

    assert Released.take() == []
  end

  test "cancel releases with :cancel and reports an unconfirmed handle", %{core: core} do
    hands = start_hands(core)
    handles = [:keep, {:report, self()}]

    :ok =
      Helyx.Session.Hands.run(
        hands,
        "t1",
        call("c1", "hold", %{"handles" => handles, "ms" => 60_000})
      )

    # The tool holds its two handles in two calls; a cancel between them
    # releases only the first.
    await_held(hands, 2)

    {result, log} = with_log(fn -> cancel(hands, "t1") end)
    assert {:error, "a resource of the call could not be released"} = result
    assert log =~ ":keep"
    assert [{:cancel, _handles}] = Released.take()

    assert {:error, text} = upcase(hands, "c2")
    assert text =~ "earlier call"
  end

  # A release that blocks the hands holds the answer to a provider start
  # past any call timeout (#677); the cast leaves the caller free.
  test "a provider start is answered after a release that blocks the hands", %{core: core} do
    hands = start_hands(core)
    arguments = %{"handles" => [%{"gate" => Gate.open()}]}
    :ok = Helyx.Session.Hands.run(hands, "t1", call("c1", "hold", arguments))
    assert_receive {:waiting, release}

    ref = Helyx.Session.Hands.start_provider(hands, Helyx.Test.Provider, & &1)
    send(release, :go)

    # The hands send both, so the result of the call came first.
    assert_receive {:provider_start, ^ref, {:ok, _pid}}
    assert_received {:tool_result, "t1", "c1", {:ok, "held"}}
  end

  # The release ends 1,750 ms before its deadline: room for load.
  test "a release before the deadline confirms its handles", %{core: core} do
    hands = start_hands(core, release_ms: 2_000)
    :ok = Helyx.Session.Hands.run(hands, "t1", call("c1", "hold", %{"handles" => [{:slow, 250}]}))
    assert_receive {:tool_result, "t1", "c1", {:ok, "held"}}
    assert upcase(hands, "c2") == {:ok, "HI"}
  end

  test "a release past the deadline is killed and confirms nothing", %{core: core} do
    hands = start_hands(core, release_ms: 300)

    :ok =
      Helyx.Session.Hands.run(hands, "t1", call("c1", "hold", %{"handles" => [{:slow, 60_000}]}))

    # A kill after the end of the release would confirm the handle, so the
    # error shows that the kill came first. No bound on the time is needed.
    assert_receive {:tool_result, "t1", "c1", {:error, text}}
    assert text =~ "could not be released"

    # The release Task is gone; only the ending tool Task can be left, and
    # it ends.
    for pid <- Task.Supervisor.children(Helyx.Core.task_supervisor(core)) do
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}
    end
  end

  test "a release that raises, exits, or returns a bad value confirms nothing", %{core: core} do
    for handle <- [:raise, :exit, :bad, :improper] do
      hands = start_hands(core)
      :ok = Helyx.Session.Hands.run(hands, "t1", call("c1", "hold", %{"handles" => [handle]}))
      assert_receive {:tool_result, "t1", "c1", {:error, text}}
      assert text =~ "could not be released"
      assert {:error, text} = upcase(hands, "c2")
      assert text =~ "earlier call"
    end
  end

  test "an abort releases the handles of each tool in parallel", %{core: core} do
    hands = start_hands(core)
    arguments = %{"handles" => [%{"gate" => Gate.open()}], "ms" => 60_000}
    :ok = Helyx.Session.Hands.run(hands, "t1", call("c1", "hold", arguments))
    :ok = Helyx.Session.Hands.run(hands, "t1", call("c2", "hold_two", arguments))
    await_held(hands, 2)

    # One after the other, the second release would start only after the
    # first got :go.
    cancel = Task.async(fn -> cancel(hands, "t1") end)
    assert_receive {:waiting, first}
    assert_receive {:waiting, second}
    send(first, :go)
    send(second, :go)
    assert Task.await(cancel, wait_ms()) == :ok
    assert upcase(hands, "c3") == {:ok, "HI"}
  end

  test "a tool without release/3 cannot hold a handle", %{core: core} do
    hands = start_hands(core)
    :ok = Helyx.Session.Hands.run(hands, "t1", call("c1", "hold_bare", %{}))
    assert_receive {:tool_result, "t1", "c1", {:error, text}}
    assert text =~ "release/3"
    assert upcase(hands, "c2") == {:ok, "HI"}
  end

  @max_result_bytes 65_536

  test "an unknown tool with a 100 KB name gets a bounded result and no Task", %{core: core} do
    supervisor = GenServer.whereis(Helyx.Core.task_supervisor(core))
    :erlang.trace(supervisor, true, [:procs])
    name = String.duplicate("n", 100_000)

    :ok = Helyx.Session.Hands.run(start_hands(core), "t1", call("c1", name, %{}))
    assert_receive {:tool_result, "t1", "c1", {:error, result}}
    assert result =~ "unknown tool: nnn"
    assert byte_size(result) <= @max_result_bytes

    # Every trace message of the supervisor so far is in the mailbox.
    ref = :erlang.trace_delivered(supervisor)
    assert_receive {:trace_delivered, _, ^ref}
    refute_received {:trace, ^supervisor, :spawn, _, _}
  end

  test "a tool that raises gives its message, cut to the 4000 bytes of an error text",
       %{core: core} do
    hands = start_hands(core)

    for {bytes, expected} <- [
          {10, String.duplicate("x", 10)},
          {200_000, String.duplicate("x", 4000)}
        ] do
      :ok = Helyx.Session.Hands.run(hands, "t1", call("c1", "raise", %{"bytes" => bytes}))
      assert_receive {:tool_result, "t1", "c1", {:error, ^expected}}
    end
  end

  defp odd(hands, what) do
    with_log(fn ->
      :ok = Helyx.Session.Hands.run(hands, "t1", call("c1", "odd", %{"do" => what}))
      assert_receive {:tool_result, "t1", "c1", {:error, result}}, wait_ms()
      result
    end)
  end

  # A stack frame of a test tool shows as its file, a pid as `#PID<`. The
  # log has the term; the result has a short or a fixed text.
  test "a crash or a bad return of a tool gives no stack frame and no pid", %{core: core} do
    hands = start_hands(core)
    assert {"tool crashed: linked crash", log} = odd(hands, "link_crash")
    assert log =~ "interfaces.ex"

    assert {"the tool returned a value outside its contract", log} = odd(hands, "weird")
    assert log =~ "#PID<"
  end

  # A thrown or exited value gives its cleaned term, as a turn error does:
  # a pid in it shows as characters, a stack frame does not.
  test "a throw or an exit of a tool gives its value with no stack frame", %{core: core} do
    hands = start_hands(core)

    for kind <- ["throw", "exit"] do
      {result, log} = odd(hands, kind)
      assert result =~ ~r/^\{:#{kind}, \{:#{kind}\w*, #PID<[\d.]+>\}\}$/
      assert log =~ "interfaces.ex"
    end
  end

  # No boundary caps a thrown value, so the text and the log cap it:
  # `inspect` of this integer takes seconds.
  test "a tool that throws a huge integer gives the digit marker", %{core: core} do
    {result, log} = odd(start_hands(core), "huge")
    assert result == "{:throw, \"integer of more than 100 digits removed\"}"
    assert log =~ "integer of more than 100 digits removed"
  end

  # Waits until the hands got `n` hold calls, then until they handled them,
  # and asserts that they hold the handles, so cancel finds them.
  defp await_held(hands, n) do
    for _ <- 1..n do
      assert_receive {:trace, ^hands, :receive, {:"$gen_call", {_task, _}, {:hold, _}}}
    end

    :erlang.trace(hands, false, [:receive])
    assert :sys.get_state(hands).held |> Map.values() |> List.flatten() |> length() >= n
  end

  describe "background runs" do
    @describetag :tmp_dir

    setup %{tmp_dir: tmp_dir}, do: %{dir: Path.join(tmp_dir, "background"), gate: Gate.open()}

    defp background(hands, id, args) do
      :ok = Helyx.Session.Hands.run(hands, "t1", call(id, "background", args))
    end

    test "the start answer is the result, the Task leaves its turn, and its end comes after",
         %{core: core, dir: dir, gate: gate} do
      hands = start_hands(core, background_dir: dir)
      background(hands, "c1", %{"gate" => gate, "handles" => [{:report, self()}]})

      assert_receive {:tool_result, "t1", "c1", {:started, start}}

      [_, id, path] =
        Regex.run(
          ~r/\A<background id="(.{12})" status="started">\nstarted (.*)\n<\/background>\z/,
          start
        )

      assert path == Path.join(dir, id)
      assert File.stat!(dir).access == :read_write
      assert Bitwise.band(File.stat!(dir).mode, 0o777) == 0o700

      assert_receive {:waiting, pid}
      # An abort of the turn does not reach the run, nor release it.
      assert cancel(hands, "t1") == :ok
      assert Process.alive?(pid)
      refute_received {:release, _mode, _handles}

      send(pid, :go)
      assert_receive {:release, :deliver, _handles}
      assert_receive {:background_end, finish}
      assert finish.origin == %{kind: :background, id: id}

      assert Helyx.Message.text(finish) ==
               ~s(<background id="#{id}" status="done">\ndone\n</background>)
    end

    test "a crash of the run ends it with an error", %{core: core, dir: dir, gate: gate} do
      hands = start_hands(core, background_dir: dir)
      background(hands, "c1", %{"gate" => gate})
      assert_receive {:tool_result, "t1", "c1", {:started, _start}}
      assert_receive {:waiting, pid}

      {_, log} =
        with_log(fn ->
          Process.exit(pid, :kill)
          assert_receive {:background_end, finish}

          assert Helyx.Message.text(finish) =~
                   ~r/\A<background id=".{12}" status="error">\ntool crashed: /
        end)

      assert log =~ "tool crashed"
    end

    test "16 runs are live at most; a start over that runs nothing", %{
      core: core,
      dir: dir,
      gate: gate
    } do
      hands = start_hands(core, background_dir: dir)

      pids =
        for n <- 1..16 do
          background(hands, "c#{n}", %{"gate" => gate})
          assert_receive {:tool_result, "t1", _, {:started, _start}}
          assert_receive {:waiting, pid}
          pid
        end

      background(hands, "c17", %{"gate" => gate})
      assert_receive {:tool_result, "t1", "c17", {:error, text}}

      assert text ==
               "16 background runs are live or have an end that no turn took; " <>
                 "a turn must take an end before another run starts"

      refute_received {:waiting, _pid}

      # An end keeps its place until a turn takes it (#587); an unknown id,
      # such as the id of a lost run, frees nothing.
      send(hd(pids), :go)
      assert_receive {:background_end, finish}
      :ok = Helyx.Session.Hands.taken(hands, "unknown_id_x")
      background(hands, "c18", %{"gate" => gate})
      assert_receive {:tool_result, "t1", "c18", {:error, ^text}}

      :ok = Helyx.Session.Hands.taken(hands, finish.origin.id)
      background(hands, "c19", %{"gate" => gate})
      assert_receive {:tool_result, "t1", "c19", {:started, _start}}
    end

    # 15 ends wait, so one place is left. A second call of the Task that
    # holds it gives a new id in that place; another Task gets no place.
    test "a second place call at the limit keeps the place of its Task", %{
      core: core,
      dir: dir,
      gate: gate
    } do
      hands = start_hands(core, background_dir: dir)

      for n <- 1..15 do
        background(hands, "c#{n}", %{"gate" => gate})
        assert_receive {:tool_result, "t1", _, {:started, _start}}
        assert_receive {:waiting, pid}
        send(pid, :go)
        assert_receive {:background_end, _finish}
      end

      background(hands, "c16", %{"gate" => gate, "twice" => true})
      assert_receive {:tool_result, "t1", "c16", {:started, _start}}

      background(hands, "c17", %{"gate" => gate})
      assert_receive {:tool_result, "t1", "c17", {:error, "16 background runs" <> _}}
    end

    test "a start answer needs a place", %{core: core, dir: dir, gate: gate} do
      hands = start_hands(core, background_dir: dir)

      {_, _log} =
        with_log(fn ->
          background(hands, "c1", %{"unplaced" => true})
          assert_receive {:tool_result, "t1", "c1", {:error, text}}
          assert text =~ "started/1 needs a place from background/0"
        end)

      # It took no place: all 16 are free.
      for n <- 1..16 do
        background(hands, "d#{n}", %{"gate" => gate})
        assert_receive {:tool_result, "t1", _, {:started, _start}}
      end
    end

    # The start answer is cut to 4,096 bytes, also inside a character; the
    # cut of every result repairs it, so each kept byte gives at most 3.
    test "the start answer leaves the hands as valid UTF-8 of at most 12,288 bytes",
         %{core: core, dir: dir, gate: gate} do
      hands = start_hands(core, background_dir: dir)

      for {start, body} <- [
            {String.duplicate("a", 4095) <> "é", String.duplicate("a", 4095) <> "\uFFFD"},
            {String.duplicate(<<255>>, 5000), String.duplicate("\uFFFD", 4096)}
          ] do
        background(hands, "c1", %{"gate" => gate, "start" => start})
        assert_receive {:tool_result, "t1", "c1", {:started, answer}}
        [id] = Regex.run(~r/\A<background id="(.{12})"/, answer, capture: :all_but_first)
        assert answer == ~s(<background id="#{id}" status="started">\n#{body}\n</background>)
        assert byte_size(body) <= 12_288
      end
    end

    test "a folder that cannot be made gives an error and starts nothing",
         %{core: core, gate: gate, tmp_dir: tmp_dir} do
      file = Path.join(tmp_dir, "file")
      File.write!(file, "")
      hands = start_hands(core, background_dir: Path.join(file, "sub"))

      background(hands, "c1", %{"gate" => gate})

      assert_receive {:tool_result, "t1", "c1",
                      {:error, "the background folder could not be made: " <> _}}

      refute_received {:waiting, _pid}
    end

    # The Task dies before its start answer, by the cancel, and never
    # delivers: the cancel frees its place.
    test "a cancel between the place and the start answer frees the place", %{
      core: core,
      dir: dir,
      gate: gate
    } do
      hands = start_hands(core, background_dir: dir)

      for n <- 1..16 do
        turn = "t#{n}"

        :ok =
          Helyx.Session.Hands.run(
            hands,
            turn,
            call("c", "background", %{"gate" => gate, "unstarted" => true})
          )

        assert_receive {:waiting, _pid}
        assert cancel(hands, turn) == :ok
      end

      for n <- 1..16 do
        background(hands, "d#{n}", %{"gate" => gate})
        assert_receive {:tool_result, "t1", _, {:started, _start}}
      end
    end

    test "outside the hands a place and a start answer exit, as a hold does" do
      assert {:noproc, _} = catch_exit(Helyx.Tool.background())
      assert {:noproc, _} = catch_exit(Helyx.Tool.started("no hands"))
    end
  end
end
