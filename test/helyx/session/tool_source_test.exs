defmodule Helyx.Session.ToolSourceTest do
  # Tool sources in Core: the source process, the registry, `launch/1`,
  # and the ends (docs/features/mcp-client.md, slice 2).
  use ExUnit.Case, async: true

  import Helyx.Test.Events
  import Helyx.Test.SessionCase, only: [start_core: 1, start_core: 2, final_text: 1]
  import Helyx.Test.SourceCase

  alias Helyx.Session
  alias Helyx.Test.Source

  @plugins [Helyx.Test.Provider, Helyx.Test.Tool.Upcase, Source]

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    core = start_core(@plugins, sessions_dir: dir)
    observe(core)
    %{core: core}
  end

  # A session of `model` and its source process.
  defp start(core, model \\ "test/tools") do
    {:ok, session} = Session.start(core, model: model)
    id = session.id
    cwd = File.cwd!()
    assert_receive {:source_up, src, %{session_id: ^id, core: ^core, cwd: ^cwd}}
    {:ok, _snapshot, _ref} = Session.subscribe(session)
    {session, src}
  end

  defp hands(session), do: :sys.get_state(Session.pid(session)).hands

  # A server Task of `src` that holds `handle`, then runs `then`.
  defp launch(src, handle, then \\ fn -> Process.sleep(:infinity) end) do
    test = self()

    ref =
      in_source(src, fn ->
        Helyx.Tool.launch(fn ->
          Helyx.Tool.hold(handle)
          send(test, {:held, self()})
          then.()
        end)
      end)

    assert_receive {:source_got, ^src, {^ref, {:ok, pid}}}
    assert_receive {:held, ^pid}
    {ref, pid}
  end

  test "a put tool reaches the next context and runs on its source", %{core: core} do
    {session, src} = start(core)
    assert :ok = put(src, "g", [entry("g__echo")])

    assert turn_text(session) == "g__echo,upcase"
    :ok = Session.set_model(session, "test/call.g__echo")
    assert turn_text(session) == "ran g__echo from #{inspect(src)}"
  end

  test "the hands know a tool before any context holds it", %{core: core} do
    {session, src} = start(core, "test/call.g__now")
    assert :ok = put(src, "g", [entry("g__now")])
    # The first context that holds the tool is of this turn.
    assert turn_text(session) == "ran g__now from #{inspect(src)}"
  end

  test "an entry over a bound is rejected alone, with one notice", %{core: core} do
    {session, src} = start(core)
    long = String.duplicate("x", 53)

    entries = [
      entry("g__ok"),
      entry(String.duplicate("n", 52)),
      entry("g__é"),
      entry(long),
      entry("g__bad.name"),
      entry("g__desc", %{description: String.duplicate("é", 2_049)}),
      entry("g__desc_bytes", %{description: <<"d", 255>>}),
      entry("g__desc_max", %{description: String.duplicate("d", 4_096)}),
      entry("g__desc_over", %{description: String.duplicate("d", 4_097)}),
      entry("g__desc_multi", %{description: String.duplicate("é", 2_048)}),
      entry("g__params", %{parameters: %{"type" => "string"}}),
      entry("g__params_big", %{
        parameters: %{"type" => "object", "x" => String.duplicate("p", 16_384)}
      }),
      entry("g__params_atom", %{parameters: %{type: "object"}}),
      entry("g__exposure", %{exposure: :hidden}),
      %{name: "g__partial"},
      :not_a_map
    ]

    assert :ok = put(src, "g", entries)
    text = notice()

    assert turn_text(session) ==
             "g__desc_max,g__desc_multi,g__ok,#{String.duplicate("n", 52)},upcase"

    assert text =~ "tool group g: 12 tools were left out"
    assert text =~ "g__desc: a description"
    assert text =~ "g__params_big: parameters"
    assert text =~ "g__exposure: an exposure"
    refute text =~ long
  end

  test "a name clash keeps the earlier tool", %{core: core} do
    {session, src} = start(core)

    assert :ok =
             in_source(src, fn ->
               {:ok, ["a", "b"]} = Helyx.Tool.announce(["a", "b"])
               :ok = Helyx.Tool.put_tools("a", {:ok, [entry("shared"), entry("shared")]})
               Helyx.Tool.put_tools("b", {:ok, [entry("upcase"), entry("shared")]})
             end)

    a = notice()
    b = notice()
    assert a =~ "tool group a: 1 tools were left out: shared: the name is taken"
    assert b =~ "tool group b: 2 tools were left out"

    # `upcase` is still the fixed tool, and `shared` the tool of group a.
    tools = :sys.get_state(hands(session)).tools
    assert tools["upcase"] == Helyx.Test.Tool.Upcase
    assert tools["shared"] == Source
    assert map_size(tools) == 2
  end

  test "a group that would pass 1,024 source tools is rejected whole", %{core: core} do
    {session, src} = start(core)
    names = for n <- 1..1_024, do: entry("a__#{n}")

    assert :ok =
             in_source(src, fn ->
               {:ok, ["a", "b"]} = Helyx.Tool.announce(["a", "b"])
               :ok = Helyx.Tool.put_tools("a", {:ok, names})
               Helyx.Tool.put_tools("b", {:ok, [entry("b__one")]})
             end)

    assert notice() == "tool group b: the session holds at most 1024 source tools"
    tools = String.split(turn_text(session), ",")
    assert length(tools) == 1_025
    refute "b__one" in tools
  end

  test "past 64 groups the first by name order stay, with a notice", %{core: core} do
    {_session, src} = start(core)
    groups = for n <- 1..66, do: "g#{String.pad_leading("#{n}", 2, "0")}"

    assert {:ok, kept} = in_source(src, fn -> Helyx.Tool.announce(Enum.reverse(groups)) end)
    assert kept == Enum.take(groups, 64)
    assert notice() =~ "2 tool groups over the cap of 64 were left out: g65, g66"

    # A group that was not kept is a contract break.
    monitor = Process.monitor(src)
    send(src, {:do, self(), fn -> Helyx.Tool.put_tools("g65", :starting) end})
    assert_receive {:DOWN, ^monitor, :process, ^src, {:bad_source_call, :put_tools}}
  end

  test "a second announce, a put before it, and a bad value exit the source", %{core: core} do
    for request <- [
          fn -> {:ok, ["g"]} = Helyx.Tool.announce(["g"]) && Helyx.Tool.announce(["h"]) end,
          fn -> Helyx.Tool.put_tools("g", :starting) end,
          fn ->
            {:ok, ["g"]} = Helyx.Tool.announce(["g"]) && Helyx.Tool.put_tools("g", :ready)
          end,
          fn -> Helyx.Tool.announce(["g", "g"]) end,
          fn -> Helyx.Tool.announce(["", "g"]) end,
          fn -> Helyx.Tool.announce([String.duplicate("g", 65)]) end,
          fn -> Helyx.Tool.announce([String.duplicate("é", 32) <> "g"]) end,
          fn -> Helyx.Tool.announce([<<"g", 255>>]) end,
          fn -> Helyx.Tool.announce("g") end,
          fn -> Helyx.Tool.announce(["g" | "h"]) end,
          fn ->
            {:ok, ["g"]} = Helyx.Tool.announce(["g"]) && Helyx.Tool.put_tools("g", {:ok, :x})
          end,
          fn ->
            {:ok, ["g"]} = Helyx.Tool.announce(["g"]) && Helyx.Tool.put_tools("g", {:error, :x})
          end,
          fn -> Helyx.Tool.notice(<<"a", 255>>) end,
          fn -> Helyx.Tool.notice(:text) end
        ] do
      {session, src} = start(core)
      monitor = Process.monitor(src)
      send(src, {:do, self(), request})
      assert_receive {:DOWN, ^monitor, :process, ^src, {:bad_source_call, _}}
      GenServer.stop(Session.pid(session))
    end
  end

  test "a source's notice is an event with no turn id, cut to 2,000 bytes", %{core: core} do
    {_session, src} = start(core)
    send(src, {:do, self(), fn -> Helyx.Tool.notice("the config was refused") end})
    assert notice() == "the config was refused"
    send(src, {:do, self(), fn -> Helyx.Tool.notice(String.duplicate("é", 1_500)) end})
    text = notice()
    assert byte_size(text) == 2_000 and String.valid?(text)
  end

  test "a call outside a source process exits" do
    assert catch_exit(Helyx.Tool.notice("x")) == :not_a_tool_source
    assert catch_exit(Helyx.Tool.announce(["g"])) == :not_a_tool_source
    assert catch_exit(Helyx.Tool.put_tools("g", :starting)) == :not_a_tool_source
    assert catch_exit(Helyx.Tool.launch(fn -> :ok end)) == :not_a_tool_source
  end

  test "a source crash removes its groups and releases its handles", %{core: core} do
    {session, src} = start(core)

    assert :ok =
             in_source(src, fn ->
               {:ok, ["g", "h"]} = Helyx.Tool.announce(["g", "h"])
               :ok = Helyx.Tool.put_tools("g", {:ok, [entry("g__one")]})
               Helyx.Tool.put_tools("h", {:ok, [entry("h__one")]})
             end)

    {_ref, server} = launch(src, {:test, self(), :server})
    monitor = Process.monitor(server)

    test = self()
    in_source(src, fn -> Helyx.Tool.hold({:test, test, :source}) end)
    send(src, {:do, self(), fn -> raise "boom" end})

    assert_receive {:DOWN, ^monitor, :process, ^server, _reason}
    assert_receive {:released, :server, :deliver}
    assert_receive {:released, :source, :deliver}
    assert notice() == "tool group g ended: its tools left the session"
    assert notice() == "tool group h ended: its tools left the session"
    assert turn_text(session) == "upcase"
  end

  test "a hold in a server Task is kept and released when the Task ends", %{core: core} do
    {_session, src} = start(core)
    {ref, server} = launch(src, {:test, self(), :one}, fn -> :done end)
    assert_receive {:released, :one, :deliver}
    assert_receive {:source_got, ^src, {^ref, :released, :ok}}
    refute Process.alive?(server)
  end

  test "an unconfirmed handle of a server Task refuses the next launch", %{core: core} do
    {_session, src} = start(core)
    {ref, _server} = launch(src, {:stuck, :one}, fn -> :done end)
    assert_receive {:source_got, ^src, {^ref, :released, :unconfirmed}}

    ref = in_source(src, fn -> Helyx.Tool.launch(fn -> :ok end) end)
    assert_receive {:source_got, ^src, {^ref, {:error, :unconfirmed}}}
  end

  test "a 17th live server Task gives too_many_tasks", %{core: core} do
    {_session, src} = start(core)
    for n <- 1..16, do: launch(src, {:test, self(), n})
    ref = in_source(src, fn -> Helyx.Tool.launch(fn -> :ok end) end)
    assert_receive {:source_got, ^src, {^ref, {:error, :too_many_tasks}}}
  end

  test "a launch during a long release of the hands returns at once", %{core: core} do
    {_session, src} = start(core)
    {_ref, blocker} = launch(src, {:block, self(), :slow})

    # The hands release the blocker's handle in their own process.
    Process.exit(blocker, :kill)
    assert_receive {:releasing, :slow, release}

    # The source is free: the launch returns, and the source answers.
    ref = in_source(src, fn -> Helyx.Tool.launch(fn -> Process.sleep(:infinity) end) end)
    assert in_source(src, fn -> :pong end) == :pong
    refute_received {:source_got, ^src, {^ref, _}}

    send(release, :go)
    assert_receive {:released, :slow, :deliver}
    assert_receive {:source_got, ^src, {^ref, {:ok, late}}}

    # A late Task that the source kills goes, and its release follows.
    in_source(src, fn -> Process.exit(late, :kill) end)
    assert_receive {:source_got, ^src, {^ref, :released, :ok}}
    refute Process.alive?(late)
  end

  test "the release message comes only after the hands ran the release", %{core: core} do
    {_session, src} = start(core)
    {ref, old} = launch(src, {:block, self(), :old})

    Process.exit(old, :kill)
    # The source sees the end at once, through the link.
    assert_receive {:source_got, ^src, {:EXIT, ^old, :killed}}
    assert_receive {:releasing, :old, release}
    refute_received {:source_got, ^src, {^ref, :released, _}}

    send(release, :go)
    assert_receive {:source_got, ^src, {^ref, :released, :ok}}
  end

  test "a source that dies ends its blocked server Task through the link", %{core: core} do
    {session, src} = start(core)
    {_ref, server} = launch(src, {:test, self(), :blocked})
    :erlang.suspend_process(server)
    Process.exit(src, :kill)

    assert_receive {:released, :blocked, :deliver}
    refute Process.alive?(server)
    assert Process.alive?(Session.pid(session))
  end

  for {how, stop} <- [returns: :return, exits_normal: {:do, :exit_normal}] do
    test "a source that #{how} ends with :shutdown and ends its server Tasks", %{core: core} do
      {_session, src} = start(core)
      {_ref, server} = launch(src, {:test, self(), :blocked})
      :erlang.suspend_process(server)
      monitor = Process.monitor(src)

      case unquote(stop) do
        :return -> send(src, :return)
        {:do, :exit_normal} -> send(src, {:do, self(), fn -> exit(:normal) end})
      end

      assert_receive {:DOWN, ^monitor, :process, ^src, :shutdown}
      assert_receive {:released, :blocked, :deliver}
      refute Process.alive?(server)
    end
  end

  test "the stop of the session releases the source's handles", %{core: core} do
    {session, src} = start(core)
    {_ref, _server} = launch(src, {:test, self(), :server})
    test = self()
    in_source(src, fn -> Helyx.Tool.hold({:test, test, :source}) end)

    :ok = Helyx.Sessions.stop(session)
    assert_receive {:released, :server, :cancel}
    assert_receive {:released, :source, :cancel}
  end

  test "a session that names its tools opens no source", %{core: core} do
    {:ok, session} = Session.start(core, model: "test/tools", tools: ["upcase"])
    tasks = :sys.get_state(hands(session)).tasks
    refute Enum.any?(tasks, fn {_ref, entry} -> match?({:source, _plugin}, entry.kind) end)
    refute_received {:source_up, _, _}
  end

  defmodule Neither do
    @moduledoc false
    @behaviour Helyx.Tool
    @impl true
    def run(_args, _cwd), do: {:ok, ""}
  end

  defmodule Both do
    @moduledoc false
    @behaviour Helyx.Tool
    @impl true
    def name, do: "both"
    @impl true
    def description, do: "d"
    @impl true
    def parameters, do: %{}
    @impl true
    def source(_info), do: :ok
    @impl true
    def run(_args, _cwd), do: {:ok, ""}
  end

  defmodule NoDescription do
    @moduledoc false
    @behaviour Helyx.Tool
    @impl true
    def name, do: "nodesc"
    @impl true
    def parameters, do: %{}
    @impl true
    def run(_args, _cwd), do: {:ok, ""}
  end

  test "Core refuses a Tool plugin that is neither kind" do
    # Tool plugins with no `run/2`, whose missing callback warns at compile,
    # and a source that also exports `description/0`.
    no_run =
      plugin(
        NoRun,
        quote(
          do:
            (
              def name, do: "norun"
              def description, do: "d"
              def parameters, do: %{}
            )
        )
      )

    source_no_run = plugin(SourceNoRun, quote(do: def(source(_info), do: :ok)))

    source_description =
      plugin(
        SourceDescription,
        quote(
          do:
            (
              def source(_info), do: :ok
              def description, do: "d"
              def run(_a, _c), do: {:ok, ""}
            )
        )
      )

    for plugin <- [Neither, Both, NoDescription, no_run, source_no_run, source_description] do
      assert {:error, {:invalid_tool_plugin, ^plugin}} =
               Helyx.Core.start_link(
                 name: :"bad_#{System.unique_integer([:positive])}",
                 plugins: [Helyx.Test.Provider, plugin]
               )
    end
  end

  defp plugin(name, body) do
    {{:module, module, _, _}, _warnings} =
      Code.with_diagnostics(fn ->
        Module.create(
          Module.concat(__MODULE__, name),
          quote(
            do:
              (
                @behaviour Helyx.Tool
                unquote(body)
              )
          ),
          Macro.Env.location(__ENV__)
        )
      end)

    module
  end

  defmodule Unavailable do
    @moduledoc false
    # A tool source whose `check/0` fails.
    @behaviour Helyx.Tool
    @impl true
    def source(_info), do: Process.sleep(:infinity)
    @impl true
    def check, do: {:error, "the program is missing"}
    @impl true
    def run(_args, _cwd), do: {:ok, ""}
  end

  defmodule SourceOfCall do
    @moduledoc false
    use Helyx.Test.Tool, name: "source_of_call", description: "Gives the source of its call."

    @impl true
    def run(_args, _cwd), do: {:ok, inspect(Helyx.Tool.context().source)}
  end

  test "the check/0 of a tool source runs at the start" do
    core = start_core([Helyx.Test.Provider, Unavailable])

    assert Session.start(core, model: "test/ok") ==
             {:error, {:tool_unavailable, inspect(Unavailable), "the program is missing"}}
  end

  test "a fixed tool's call has no source" do
    core = start_core([Helyx.Test.Provider, SourceOfCall])
    {:ok, session} = Session.start(core, model: "test/call.source_of_call")
    {:ok, _snapshot, _ref} = Session.subscribe(session)
    assert turn_text(session) == "nil"
  end

  test "an error and a start put remove the group's tools", %{core: core} do
    {session, src} = start(core)
    assert :ok = put(src, "g", [entry("g__one")])
    assert turn_text(session) == "g__one,upcase"

    assert :ok =
             in_source(src, fn ->
               Helyx.Tool.put_tools("g", {:error, String.duplicate("é", 1_500)})
             end)

    assert turn_text(session) == "upcase"

    assert :ok = in_source(src, fn -> Helyx.Tool.put_tools("g", {:ok, [entry("g__two")]}) end)
    assert :ok = in_source(src, fn -> Helyx.Tool.put_tools("g", :starting) end)
    assert turn_text(session) == "upcase"
    assert map_size(:sys.get_state(hands(session)).tools) == 1
  end

  test "parameters of 16,384 bytes of JSON pass, of 16,385 do not", %{core: core} do
    {session, src} = start(core)
    # `{"type":"object","x":""}` is 24 bytes; `é` is 2 bytes and 2 in JSON.
    params = fn pad -> %{"type" => "object", "x" => pad} end

    assert :ok =
             put(src, "g", [
               entry("g__at", %{parameters: params.(String.duplicate("p", 16_360))}),
               entry("g__under", %{parameters: params.(String.duplicate("p", 16_359))}),
               entry("g__over", %{parameters: params.(String.duplicate("p", 16_361))}),
               entry("g__multi", %{parameters: params.(String.duplicate("é", 8_180))}),
               entry("g__multi_over", %{parameters: params.(String.duplicate("é", 8_180) <> "p")})
             ])

    assert turn_text(session) == "g__at,g__multi,g__under,upcase"
  end

  test "a group name of 64 bytes passes, multibyte too", %{core: core} do
    {session, src} = start(core)
    groups = [String.duplicate("g", 64), String.duplicate("é", 32), "g"]
    assert in_source(src, fn -> Helyx.Tool.announce(groups) end) == {:ok, Enum.sort(groups)}

    # Each starts as `:starting`, with no tools.
    registry = :sys.get_state(Session.pid(session)).registry

    for group <- groups,
        do: assert(registry.groups[{Source, group}] == %{state: :starting, entries: []})
  end

  test "exactly 64 groups need no notice, and 65 leave one out", %{core: core} do
    {_session, src} = start(core)
    groups = for n <- 1..64, do: "g#{n}"
    assert in_source(src, fn -> Helyx.Tool.announce(groups) end) == {:ok, Enum.sort(groups)}
    refute_receive {:helyx_event, %Helyx.Event{type: :notice}}, 100

    {_session, src} = start(core)

    assert in_source(src, fn -> Helyx.Tool.announce(["z" | groups]) end) ==
             {:ok, Enum.sort(groups)}

    assert notice() =~ "1 tool groups over the cap of 64 were left out: z"
  end

  test "1,024 source tools pass, and the cap counts only the kept entries", %{core: core} do
    {session, src} = start(core)
    names = for n <- 1..1_023, do: entry("a__#{n}")

    assert :ok =
             in_source(src, fn ->
               {:ok, ["a", "b"]} = Helyx.Tool.announce(["a", "b"])
               :ok = Helyx.Tool.put_tools("a", {:ok, names})
               Helyx.Tool.put_tools("b", {:ok, [entry("b__one"), entry("b.bad")]})
             end)

    assert notice() =~ "tool group b: 1 tools were left out"
    assert length(String.split(turn_text(session), ",")) == 1_025
  end

  test "a notice is valid UTF-8 of at most 2,000 bytes", %{core: core} do
    {_session, src} = start(core)
    group = String.duplicate("é", 32)
    taken = for _ <- 1..200, do: entry("upcase")
    assert :ok = put(src, group, taken)
    text = notice()
    assert byte_size(text) <= 2_000
    assert byte_size(text) > 1_990
    assert String.valid?(text)
  end

  test "a resume starts the tool source again", %{core: core} do
    dir = Helyx.Core.config(core, :sessions_dir)
    {:ok, session} = Session.start(core, model: "test/ok", sessions_dir: dir)
    assert_receive {:source_up, _src, %{session_id: id}}
    assert id == session.id
    :ok = Helyx.Sessions.stop(session)

    {:ok, resumed} = Session.resume(core, sessions_dir: dir, id: id)
    assert_receive {:source_up, _src, %{session_id: ^id}}
    assert Process.alive?(Session.pid(resumed))
  end

  test "an abort leaves the source and its server Tasks running", %{core: core} do
    {session, src} = start(core, "test/hang")
    {_ref, server} = launch(src, {:test, self(), :server})
    :ok = Session.prompt(session, "go")
    assert_receive {:helyx_event, %Helyx.Event{type: :turn_start}}
    :ok = Session.abort(session)
    assert Process.alive?(src)
    assert Process.alive?(server)
    refute_received {:released, :server, _}
  end

  test "a source tool is never concurrent", %{core: core} do
    {session, src} = start(core)
    assert :ok = put(src, "g", [entry("g__one")])
    assert :sys.get_state(Session.pid(session)).registry.tools["g__one"] == {Source, false}
  end

  test "a launch whose source ended before the hands took it runs nothing", %{core: core} do
    {_session, src} = start(core)
    {_ref, blocker} = launch(src, {:block, self(), :slow})
    Process.exit(blocker, :kill)
    assert_receive {:releasing, :slow, release}

    test = self()
    in_source(src, fn -> Helyx.Tool.launch(fn -> send(test, :ran) end) end)
    Process.exit(src, :kill)
    send(release, :go)

    assert_receive {:released, :slow, :deliver}
    refute_receive :ran, 200
  end

  test "a kill of the hands ends the source, which traps exits", %{core: core} do
    {session, src} = start(core)
    monitor = Process.monitor(src)
    Process.exit(hands(session), :kill)
    assert_receive {:DOWN, ^monitor, :process, ^src, :killed}
  end

  test "a call that the hands take after the end of its source is unknown", %{core: core} do
    {session, src} = start(core, "test/call.g__echo")
    assert :ok = put(src, "g", [entry("g__echo")])
    # The provider process runs before the hands are held: the hands start it.
    assert turn_text(session) == "ran g__echo from #{inspect(src)}"
    {_ref, blocker} = launch(src, {:block, self(), :slow})
    hands = hands(session)

    # The hands release in their own process; the end of the source and the
    # call wait behind it, in that order.
    Process.exit(blocker, :kill)
    assert_receive {:releasing, :slow, release}
    Process.exit(src, :kill)
    :ok = Session.prompt(session, "go")
    wait_for_run(hands)
    send(release, :go)

    assert final_text(collect_until(:turn_end)) ==
             "ran g__echo from #{inspect(src)}|unknown tool: g__echo"
  end

  defp wait_for_run(hands) do
    {:messages, messages} = Process.info(hands, :messages)

    unless Enum.any?(messages, &match?({:"$gen_cast", {:run, _, _, _}}, &1)) do
      Process.sleep(10)
      wait_for_run(hands)
    end
  end

  defmodule OtherSource do
    @moduledoc false
    # A second tool source, driven as `Helyx.Test.Source`.
    @behaviour Helyx.Tool
    @impl true
    defdelegate source(info), to: Source
    @impl true
    defdelegate run(args, cwd), to: Source
    @impl true
    defdelegate release(handles, mode, deadline), to: Source
  end

  test "a tool map that names a source that ended runs none of its tools" do
    core = start_core([Helyx.Test.Provider, Source, OtherSource])
    observe(core)
    {:ok, session} = Session.start(core, model: "test/call.a__echo")
    assert_receive {:source_up, one, _}
    assert_receive {:source_up, two, _}
    {:ok, _snapshot, _ref} = Session.subscribe(session)
    sources = :sys.get_state(Session.pid(session)).sources
    [a, b] = Enum.sort_by([one, two], &(sources[&1] == OtherSource))

    assert :ok = put(a, "a", [entry("a__echo")])
    assert turn_text(session) == "ran a__echo from #{inspect(a)}"

    # The hands are held in a release: the end of a, a tool map of the
    # session that still names its tool, and the call wait behind it, in
    # that order.
    {_ref, blocker} = launch(b, {:block, self(), :slow})
    Process.exit(blocker, :kill)
    assert_receive {:releasing, :slow, release}
    monitor = Process.monitor(a)
    Process.exit(a, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^a, :killed}
    assert :ok = put(b, "b", [entry("b__one")])
    :ok = Session.prompt(session, "go")
    wait_for_run(hands(session))
    send(release, :go)

    assert final_text(collect_until(:turn_end)) ==
             "ran a__echo from #{inspect(a)}|unknown tool: a__echo"
  end

  defp two_sources do
    core = start_core([Helyx.Test.Provider, Source, OtherSource])
    observe(core)
    {:ok, session} = Session.start(core, model: "test/tools")
    assert_receive {:source_up, one, _}
    assert_receive {:source_up, two, _}
    {:ok, _snapshot, _ref} = Session.subscribe(session)
    sources = :sys.get_state(Session.pid(session)).sources
    [a, b] = Enum.sort_by([one, two], &(sources[&1] == OtherSource))
    {session, a, b}
  end

  test "the 64-group cap counts the groups of every source", %{core: _core} do
    {session, a, b} = two_sources()
    a_groups = for n <- 1..60, do: "a#{n}"
    b_groups = for n <- 1..10, do: "b#{String.pad_leading("#{n}", 2, "0")}"

    assert in_source(a, fn -> Helyx.Tool.announce(a_groups) end) == {:ok, Enum.sort(a_groups)}
    assert {:ok, kept} = in_source(b, fn -> Helyx.Tool.announce(b_groups) end)
    assert kept == ["b01", "b02", "b03", "b04"]

    assert notice() ==
             "6 tool groups over the cap of 64 were left out: b05, b06, b07, b08, b09, b10"

    # A source puts only to the groups that it kept.
    assert in_source(b, fn -> Helyx.Tool.put_tools("b04", {:ok, [entry("b04__one")]}) end) == :ok
    assert turn_text(session) == "b04__one"
  end

  test "a long left-out list gives a notice of at most 2,000 bytes with the full count" do
    {_session, a, b} = two_sources()
    assert {:ok, _kept} = in_source(a, fn -> Helyx.Tool.announce(for n <- 1..64, do: "a#{n}") end)
    groups = for n <- 1..10_000, do: "b#{String.pad_leading("#{n}", 5, "0")}"

    assert in_source(b, fn -> Helyx.Tool.announce(groups) end) == {:ok, []}
    text = notice()
    assert text =~ "10000 tool groups over the cap of 64 were left out: b00001, b00002"
    assert byte_size(text) <= 2_000 and String.valid?(text)
    # Only whole names, a prefix of the left-out list.
    [_head, names] = String.split(text, ": ", parts: 2)
    listed = String.split(names, ", ")
    assert listed == Enum.take(groups, length(listed))
    assert byte_size(text) + byte_size(", b00000") > 2_000
  end

  test "a left-out name that does not fit whole is not in the notice" do
    {_session, a, b} = two_sources()

    assert {:ok, _kept} =
             in_source(a, fn -> Helyx.Tool.announce(["k" | for(n <- 1..63, do: "a#{n}")]) end)

    long =
      for n <- 1..29, do: "j#{String.pad_leading("#{n}", 2, "0")}" <> String.duplicate("x", 61)

    groups = long ++ ["j99" <> String.duplicate("y", 31), "k" <> String.duplicate("z", 63)]

    assert in_source(b, fn -> Helyx.Tool.announce(groups) end) == {:ok, []}
    text = notice()
    [_head, names] = String.split(text, ": ", parts: 2)
    listed = String.split(names, ", ")
    assert Enum.all?(listed, &(&1 in groups))
  end

  test "a kept error text is valid UTF-8 cut to 2,000 bytes", %{core: core} do
    {session, src} = start(core)
    assert :ok = put(src, "g", [entry("g__one")])

    assert in_source(src, fn ->
             Helyx.Tool.put_tools("g", {:error, "a" <> String.duplicate("é", 1_500)})
           end) == :ok

    # The cut at 2,000 bytes falls inside a 2-byte character, which goes.
    {:error, kept} = :sys.get_state(Session.pid(session)).registry.groups[{Source, "g"}].state
    assert byte_size(kept) == 1_999
    assert String.valid?(kept)
  end

  test "an exit signal of another process reaches the source as a message", %{core: core} do
    {_session, src} = start(core)
    Process.exit(src, {:shutdown, :elsewhere})
    assert_receive {:source_got, ^src, {:EXIT, _pid, {:shutdown, :elsewhere}}}
    assert Process.alive?(src)
  end

  test "a left-out name that ends the notice at exactly 2,000 bytes is in it" do
    {_session, a, b} = two_sources()
    assert {:ok, _kept} = in_source(a, fn -> Helyx.Tool.announce(for n <- 1..64, do: "a#{n}") end)

    long =
      for n <- 1..29, do: "j#{String.pad_leading("#{n}", 2, "0")}" <> String.duplicate("x", 61)

    head = "30 tool groups over the cap of 64 were left out: "
    last = "jz" <> String.duplicate("y", 2_000 - byte_size(head) - 29 * 66 - 2)

    assert in_source(b, fn -> Helyx.Tool.announce(long ++ [last]) end) == {:ok, []}
    text = notice()
    assert byte_size(text) == 2_000
    assert String.ends_with?(text, ", " <> last)
  end
end
