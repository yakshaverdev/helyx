defmodule Helyx.Tool.ToolSearchTest do
  # tool_search: the ranking, the bounds of its arguments, the answer with
  # the names that activate/1 kept, the empty query, and the wait for a
  # change (docs/features/mcp-client.md, slice 5).
  use ExUnit.Case, async: true

  import Helyx.Test.Events
  import Helyx.Test.ToolSource, only: [observe: 1, in_source: 2, entry: 1, entry: 2]

  alias Helyx.Message.ToolCall
  alias Helyx.Provider.Fake
  alias Helyx.Session
  alias Helyx.Tool.ToolSearch

  # The wait of a search with no match, from its first look.
  @search_wait_ms 30_000
  # A search that must not wait answers before the end of its wait less this
  # margin for a loaded machine.
  @load_ms 15_000

  setup do
    %{core: start_core([Fake, ToolSearch, Helyx.Test.ToolSource])}
  end

  # A Core of `plugins` whose sources the test process observes.
  defp start_core(plugins) do
    core = :"core_#{System.unique_integer([:positive])}"
    start_supervised!({Helyx.Core, name: core, plugins: plugins}, id: core)
    observe(core)
    core
  end

  # An entry whose spec has about 17,400 bytes: four pass the 65,536 bytes
  # of activated specs; three do not.
  defp big(name, description) do
    entry(name, %{
      description: description,
      parameters: %{"type" => "object", "x" => String.duplicate("p", 16_300)}
    })
  end

  # A session whose model searches with `args` in its first turn
  # (`go/1`), or with each of a list of them, one per turn; the source
  # process of its test source.
  defp start(core, args) when is_map(args), do: start(core, [args])

  defp start(core, searches) do
    model = "search_#{System.unique_integer([:positive])}"

    script =
      for {args, n} <- Enum.with_index(searches, 1),
          response <- [[%ToolCall{id: "c#{n}", name: "tool_search", arguments: args}], ["Done."]],
          do: response

    :ok = Fake.script(core, model, script)
    {:ok, session} = Session.start(core, model: "fake/#{model}", cwd: ".")
    {:ok, _, _} = Session.subscribe(session)
    assert_receive {:source_up, source}
    {session, source}
  end

  defp go(session), do: :ok = Session.prompt(session, "go")

  defp put(source, groups, puts) do
    in_source(source, fn ->
      {:ok, ^groups} = Helyx.Tool.announce(groups)
      for {group, value} <- puts, do: :ok = Helyx.Tool.put_tools(group, value)
    end)
  end

  defp result(timeout \\ wait_ms()) do
    assert_receive {:helyx_event,
                    %Helyx.Event{type: :tool_execution_end, data: %{message: message}}},
                   timeout

    {message.is_error, Helyx.Message.text(message)}
  end

  # The search that waits in `deferred/2` for the next change: its process.
  defp waiting(session) do
    wait_until(fn -> waiter(session) != nil end)
    waiter(session)
  end

  defp waiter(session) do
    waiters = :sys.get_state(Session.pid(session)).registry.waiters

    Enum.find_value(Map.values(waiters), fn {{pid, _tag}, _timer} ->
      Process.alive?(pid) && pid
    end)
  end

  # A call of `request` waits in the mailbox of the suspended session.
  defp queued?(pid, request) do
    {:messages, messages} = Process.info(pid, :messages)
    Enum.any?(messages, &(match?({:"$gen_call", _from, _}, &1) and request.(elem(&1, 2))))
  end

  describe "rank/3" do
    defp ranked(name, description, parameters \\ %{"type" => "object"}),
      do: %{name: name, description: description, parameters: parameters, group: "g"}

    defp entries do
      [
        ranked("gh__create_issue", "Create an issue in a repository"),
        ranked("gh__list_prs", "List the pull requests of a repository"),
        ranked("fs__read", "Read", %{
          "type" => "object",
          "properties" => %{"path" => %{"type" => "string", "description" => "The file to open"}}
        }),
        ranked("web__getPage", "Fetch")
      ]
    end

    defp names(query, limit \\ 10),
      do: Enum.map(ToolSearch.rank(entries(), query, limit), & &1.name)

    test "words of the name, the description, and the parameters match" do
      assert names("issue") == ["gh__create_issue"]
      assert names("pull requests") == ["gh__list_prs"]
      assert names("file path") == ["fs__read"]
      assert names("page") == ["web__getPage"]
      assert names("deploy") == []
    end

    test "a name in the query ranks first, in the order of the query" do
      assert names("web__getPage fs__read repository") ==
               ["web__getPage", "fs__read", "gh__create_issue", "gh__list_prs"]
    end

    test "the best score first, then by name, at most the limit" do
      assert names("repository") == ["gh__create_issue", "gh__list_prs"]
      assert names("repository", 1) == ["gh__create_issue"]
      assert names("create issue repository") == ["gh__create_issue", "gh__list_prs"]

      same = [ranked("b__x", "same words"), ranked("a__x", "same words")]
      assert Enum.map(ToolSearch.rank(same, "same", 10), & &1.name) == ["a__x", "b__x"]
    end

    test "the words of the parameters at any depth, and digits, but no other key" do
      zone = %{"type" => "string", "description" => "An s3 bucket"}

      nested =
        ranked("db__query", "Run", %{
          "type" => "object",
          "properties" => %{
            "filter" => %{
              "type" => "array",
              "items" => %{"type" => "object", "properties" => %{"zone" => zone}}
            }
          }
        })

      for query <- ["filter", "zone", "s3", "bucket", "db query run"],
          do: assert([%{name: "db__query"}] = ToolSearch.rank([nested], query, 10))

      assert ToolSearch.rank([nested], "type object string array items", 10) == []
    end
  end

  describe "the bounds of the arguments" do
    # Arguments that pass the checks reach `deferred/2`, which raises
    # outside a tool call.
    defp check(args) do
      ToolSearch.run(args, ".")
    rescue
      e in ArgumentError ->
        assert e.message =~ "runs only in a tool call"
        :passes
    end

    test "a query of at most 1,024 bytes" do
      assert check(%{"query" => String.duplicate("a", 1_024)}) == :passes
      assert check(%{"query" => String.duplicate("é", 512)}) == :passes
      assert {:error, text} = check(%{"query" => String.duplicate("a", 1_025)})
      assert text =~ "1024 bytes"
      assert {:error, _} = check(%{"query" => String.duplicate("é", 512) <> "a"})
      assert {:error, _} = check(%{"query" => 7})
      assert {:error, _} = check(%{})
    end

    test "a limit from 1 to 10, 5 when it is missing or null" do
      for limit <- [1, 10, nil], do: assert(check(%{"query" => "a", "limit" => limit}) == :passes)

      for limit <- [0, 11, -1, "5", 5.0, [5]] do
        assert {:error, "limit is an integer from 1 to 10"} =
                 check(%{"query" => "a", "limit" => limit})
      end
    end
  end

  test "the answer lists the matches that activate/1 kept and names the ones it left out",
       %{core: core} do
    names = ~w(big__one big__two big__three big__four)
    {session, source} = start(core, %{"query" => Enum.join(names, " "), "limit" => 4})
    description = String.duplicate("d", 1_000)
    put(source, ["big"], [{"big", {:ok, Enum.map(names, &big(&1, description))}}])
    go(session)

    assert {false, text} = result()

    assert String.split(text, "\n") == [
             "big__one: " <> description,
             "big__two: " <> description,
             "big__three: " <> description,
             "Not loaded, by the cap of loaded tools or a change of their group: big__four.",
             "The listed tools are callable from the next model call."
           ]

    assert snapshot(session).activated == ~w(big__three big__two big__one)
  end

  test "a description is one line of at most 1,024 bytes in the answer", %{core: core} do
    {session, source} = start(core, %{"query" => "docs__long"})
    description = "first\r\nsecond!\n" <> String.duplicate("é", 2_000)
    put(source, ["docs"], [{"docs", {:ok, [entry("docs__long", %{description: description})]}}])
    go(session)

    assert {false, text} = result()
    [line, last] = String.split(text, "\n")
    assert "docs__long: first second! " <> rest = line
    assert byte_size("first second! " <> rest) == 1_024
    assert last =~ "callable from the next model call"
  end

  test "a match among ready groups answers at once while another group is starting",
       %{core: core} do
    {session, source} = start(core, %{"query" => "search documentation"})
    docs = entry("docs__search", %{description: "Search the documentation pages"})
    put(source, ["docs", "web"], [{"docs", {:ok, [docs]}}])
    go(session)

    assert {false, text} = result(@search_wait_ms - @load_ms)

    assert String.split(text, "\n") == [
             "docs__search: Search the documentation pages",
             "Groups still starting: web.",
             "The listed tools are callable from the next model call."
           ]
  end

  test "with no match it waits for a change and ranks again", %{core: core} do
    {session, source} = start(core, %{"query" => "deploy service"})
    put(source, ["ci", "docs", "web"], [{"docs", {:ok, [entry("docs__search")]}}])
    go(session)

    waiting(session)
    refute_received {:helyx_event, %Helyx.Event{type: :tool_execution_end}}

    # A change with no match while web starts: the search waits again.
    in_source(source, fn -> Helyx.Tool.put_tools("ci", {:ok, [entry("ci__other")]}) end)
    waiting(session)
    refute_received {:helyx_event, %Helyx.Event{type: :tool_execution_end}}

    deploy = entry("web__deploy", %{description: "Deploy a service"})
    in_source(source, fn -> Helyx.Tool.put_tools("web", {:ok, [deploy]}) end)

    assert {false, "web__deploy: Deploy a service\n" <> _} = result()
  end

  test "with no match it waits for a pending source", %{core: core} do
    {session, source} = start(core, %{"query" => "deploy"})
    go(session)
    waiting(session)
    refute_received {:helyx_event, %Helyx.Event{type: :tool_execution_end}}

    deploy = entry("web__deploy", %{description: "Deploy a service"})
    put(source, ["web"], [{"web", {:ok, [deploy]}}])
    assert {false, "web__deploy: Deploy a service\n" <> _} = result()
  end

  test "with no group starting a search with no match answers at once", %{core: core} do
    {session, source} = start(core, %{"query" => "deploy"})

    put(source, ["docs", "gh"], [
      {"docs", {:ok, [entry("docs__search")]}},
      {"gh", {:error, "boom"}}
    ])

    go(session)

    assert {false, text} = result(@search_wait_ms - @load_ms)
    assert text == "No tool matches the query.\nGroup gh failed: boom"
  end

  @tag :slow
  test "a search with no match answers at the end of its wait", %{core: core} do
    {session, source} = start(core, %{"query" => "deploy"})
    put(source, ["web"], [])
    started = System.monotonic_time(:millisecond)
    go(session)

    assert {false, text} = result(@search_wait_ms + wait_ms())
    assert System.monotonic_time(:millisecond) - started >= @search_wait_ms
    assert text == "No tool matches the query.\nGroups still starting: web."
  end

  test "a search loads at most 5 matches with no limit", %{core: core} do
    {session, source} = start(core, %{"query" => "match"})
    entries = for n <- ~w(a b c d e f g), do: entry("m__#{n}", %{description: "match"})
    put(source, ["m"], [{"m", {:ok, entries}}])
    go(session)

    assert {false, text} = result()

    assert String.split(text, "\n") ==
             for(n <- ~w(a b c d e), do: "m__#{n}: match") ++
               ["The listed tools are callable from the next model call."]
  end

  test "a match whose group emptied since an earlier activation is not loaded", %{core: core} do
    {session, source} = start(core, [%{"query" => "x__tool"}, %{"query" => "x__tool"}])
    tool = entry("x__tool")
    put(source, ["x", "y"], [{"x", {:ok, [tool]}}])
    go(session)
    assert {false, "x__tool: d\n" <> _} = result()
    collect_until(:turn_end)

    # The name stays in the activated list while its group starts again.
    in_source(source, fn -> Helyx.Tool.put_tools("x", :starting) end)
    go(session)
    search = waiting(session)

    # The search gets a view with the tool, and the group empties before
    # the search activates it.
    :erlang.suspend_process(search)
    in_source(source, fn -> Helyx.Tool.put_tools("x", {:ok, [tool]}) end)
    in_source(source, fn -> Helyx.Tool.put_tools("x", :starting) end)
    true = :erlang.resume_process(search)

    assert {false, text} = result()

    assert String.split(text, "\n") == [
             "Not loaded, by the cap of loaded tools or a change of their group: x__tool.",
             "Groups still starting: x, y.",
             "The listed tools are callable from the next model call."
           ]

    assert snapshot(session).activated == ["x__tool"]
  end

  test "a match that the cap drops after the activation is not loaded", %{core: core} do
    {session, source} = start(core, %{"query" => "match", "limit" => 4})
    put(source, ["x"], [])
    go(session)
    search = waiting(session)
    pid = Session.pid(session)
    names = ~w(x__a x__b x__c x__d)
    small = for name <- names, do: entry(name, %{description: "match"})
    description = "match " <> String.duplicate("d", 1_000)
    big = for name <- names, do: big(name, description)

    # The search wakes on the small tools and asks to activate them; the
    # put of the large ones comes after its activation and before its
    # second look.
    :erlang.suspend_process(search)
    in_source(source, fn -> Helyx.Tool.put_tools("x", {:ok, small}) end)
    :sys.suspend(pid)
    true = :erlang.resume_process(search)
    wait_until(fn -> queued?(pid, &match?({:activate, _}, &1)) end)
    send(source, {:do, self(), fn -> Helyx.Tool.put_tools("x", {:ok, big}) end})
    wait_until(fn -> queued?(pid, &match?({:put_tools, "x", _}, &1)) end)
    :sys.resume(pid)
    assert_receive {:done, ^source, :ok}

    assert {false, text} = result()
    [a, b, c, left_out, last] = String.split(text, "\n")

    assert [a, b, c] == for(name <- ~w(x__a x__b x__c), do: name <> ": " <> description)

    assert left_out == "Not loaded, by the cap of loaded tools or a change of their group: x__d."
    assert last =~ "callable from the next model call"
    assert snapshot(session).activated == ~w(x__c x__b x__a)
  end

  test "each text of a source is on one line of the answer", %{core: core} do
    {session, source} = start(core, [%{"query" => "docs__x"}, %{"query" => ""}])
    description = "one\u2028two\vthree\ffour\u0085five\u2029six"
    failed = "boom\nevil__tool: loads all\r\n\nend"

    put(source, ["bad\ngroup", "docs", "gh"], [
      {"docs", {:ok, [entry("docs__x", %{description: description})]}},
      {"gh", {:error, failed}}
    ])

    go(session)
    assert {false, text} = result()

    assert String.split(text, "\n") == [
             "docs__x: one two three four five six",
             "Groups still starting: bad group.",
             "Group gh failed: boom evil__tool: loads all end",
             "The listed tools are callable from the next model call."
           ]

    collect_until(:turn_end)
    go(session)
    assert {false, text} = result()

    assert String.split(text, "\n") == [
             "bad group: starting",
             "docs: ready, 1 tool",
             "gh: failed: boom evil__tool: loads all end"
           ]
  end

  test "a match answers at once and names a source that is still pending" do
    # The silent source first, so the session holds it before the other is up.
    core = start_core([Fake, ToolSearch, Helyx.Test.ToolSource.Silent, Helyx.Test.ToolSource])

    {session, source} = start(core, %{"query" => "docs__x"})
    put(source, ["docs"], [{"docs", {:ok, [entry("docs__x")]}}])
    go(session)

    assert {false, text} = result(@search_wait_ms - @load_ms)

    assert String.split(text, "\n") == [
             "docs__x: d",
             "Tool sources still starting: Helyx.Test.ToolSource.Silent.",
             "The listed tools are callable from the next model call."
           ]
  end

  test "64 failed groups with long reasons fit the answer below the result cut", %{core: core} do
    {session, source} = start(core, [%{"query" => "zzz"}, %{"query" => ""}])
    # 64 names of 64 bytes, in name order.
    groups = for n <- 0..63, do: String.pad_leading(String.pad_leading("#{n}", 2, "0"), 64, "g")
    reason = String.duplicate("é", 1_000)
    put(source, groups, for(group <- groups, do: {group, {:error, reason}}))
    go(session)

    # The failure text is cut to 512 bytes, so the hands cut no answer.
    for {query, head, tail} <- [{"zzz", "Group ", " failed: "}, {"", "", ": failed: "}] do
      assert {false, text} = result()
      assert byte_size(text) < Helyx.Message.max_result_bytes(), query
      lines = String.split(text, "\n")
      assert Enum.all?(lines, &(not String.contains?(&1, "cut")))
      failed = for line <- lines, line =~ "failed: ", do: line
      assert length(failed) == 64
      assert hd(failed) == head <> hd(groups) <> tail <> String.duplicate("é", 256)
      collect_until(:turn_end)
      if query == "zzz", do: go(session)
    end
  end

  test "an empty query lists the groups and activates nothing", %{core: core} do
    {session, source} = start(core, %{"query" => " \n"})

    put(source, ["a", "b", "c", "d"], [
      {"a", {:ok, [entry("a__x"), entry("a__y")]}},
      {"b", {:error, "boom"}},
      {"d", {:ok, [entry("d__x")]}}
    ])

    go(session)

    assert {false, text} = result()
    assert text == "a: ready, 2 tools\nb: failed: boom\nc: starting\nd: ready, 1 tool"
    events = collect_until(:turn_end)
    assert of_type(events, :tools_change) == []
  end

  test "an empty query names a pending source, and no groups", %{core: core} do
    {session, _source} = start(core, %{"query" => ""})
    go(session)
    assert {false, "Tool sources still starting: Helyx.Test.ToolSource."} = result()
  end

  test "an empty query with no groups", %{core: core} do
    {session, source} = start(core, %{"query" => ""})
    put(source, [], [])
    go(session)
    assert {false, "No tool groups."} = result()
  end
end
