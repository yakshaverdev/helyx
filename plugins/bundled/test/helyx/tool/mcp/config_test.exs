defmodule Helyx.Tool.MCP.ConfigTest do
  # The MCP config: the file checks, the server checks at each bound, the
  # cap of servers, and the tool names (docs/features/mcp-client.md,
  # slice 7).
  use ExUnit.Case, async: true

  alias Helyx.Tool.MCP.Config

  @moduletag :tmp_dir

  defp write(dir, config, mode \\ 0o600) do
    path = Path.join(dir, "mcp.json")
    File.write!(path, if(is_binary(config), do: config, else: JSON.encode!(config)))
    File.chmod!(path, mode)
    path
  end

  defp servers(dir, servers), do: Config.read(write(dir, %{"mcpServers" => servers}))

  defp server(fields \\ %{}), do: Map.merge(%{"command" => "srv"}, fields)

  # The one server `name` of a config with `fields`: its struct, or its notice.
  defp one(dir, fields, name \\ "s") do
    case servers(dir, %{name => server(fields)}) do
      {[server], []} -> server
      {[], [notice]} -> notice
    end
  end

  describe "the file" do
    test "a missing file names no server and gives no notice", %{tmp_dir: dir} do
      assert Config.read(Path.join(dir, "none.json")) == {[], []}
    end

    test "a file writable by its group or others is refused", %{tmp_dir: dir} do
      for mode <- [0o620, 0o602, 0o622] do
        assert {[], [notice]} =
                 Config.read(write(dir, %{"mcpServers" => %{"s" => server()}}, mode))

        assert notice =~ "is writable by others; no MCP server starts"
      end

      assert {[%Config{name: "s"}], []} =
               Config.read(write(dir, %{"mcpServers" => %{"s" => server()}}, 0o644))
    end

    test "at most 64 KiB, a regular file", %{tmp_dir: dir} do
      config = JSON.encode!(%{"mcpServers" => %{"s" => server()}})
      pad = &(config <> String.duplicate(" ", &1 - byte_size(config)))
      assert {[_], []} = Config.read(write(dir, pad.(65_536)))
      assert {[], [notice]} = Config.read(write(dir, pad.(65_537)))
      assert notice =~ "over the 65536-byte limit"

      # The folder's mode comes from the umask: its own check comes first.
      File.chmod!(dir, 0o700)
      assert {[], [notice]} = Config.read(dir)
      assert notice =~ "not a regular file"

      assert {[], [notice]} = Config.read(write(dir, <<"{", 255, "}">>))
      assert notice =~ "binary file"
      assert {[_], []} = Config.read(write(dir, pad.(65_535)))
    end

    test "the notice of a long path keeps its reason", %{tmp_dir: dir} do
      assert {[], [notice]} = Config.read(Path.join(dir, String.duplicate("d", 2_000)))
      assert notice =~ "MCP config cannot be read: "
      assert notice =~ "; no MCP server starts: "
      assert byte_size(notice) == 2_000
    end

    test "JSON with no repeated key at any depth", %{tmp_dir: dir} do
      repeated = ~s({"mcpServers": {"s": {"command": "a"}, "s": {"command": "b"}}})
      assert {[], [notice]} = Config.read(write(dir, repeated))
      assert notice =~ "repeats a key"

      nested = ~s({"mcpServers": {"s": {"command": "a", "env": {"A": "1", "A": "2"}}}})
      assert {[], [_]} = Config.read(write(dir, nested))

      assert {[], [notice]} = Config.read(write(dir, "{"))
      assert notice =~ "is not JSON"
      assert {[], [notice]} = Config.read(write(dir, "[]"))
      assert notice =~ "is no JSON object"
      assert {[], [notice]} = Config.read(write(dir, ~s({"mcpServers": []})))
      assert notice =~ "mcpServers that is no object"
      assert Config.read(write(dir, ~s({"other": 1}))) == {[], []}
    end
  end

  describe "a server" do
    test "the name rule", %{tmp_dir: dir} do
      for name <- ["a", "0", String.duplicate("a", 15), String.duplicate("a", 16), "a-b", "a1-"],
          do: assert(%Config{name: ^name} = one(dir, %{}, name))

      for name <- ["", String.duplicate("a", 17), "-a", "A", "a_b", "é", "a b", "a\nb"] do
        notice = one(dir, %{}, name)
        assert notice =~ "a name outside ^[a-z0-9][a-z0-9-]{0,15}$"
        refute notice =~ "\n"
      end
    end

    test "a command of 1 to 4,096 bytes with no NUL", %{tmp_dir: dir} do
      at = String.duplicate("a", 4_096)
      assert %Config{command: ^at} = one(dir, %{"command" => at})
      under = String.duplicate("a", 4_095)
      assert %Config{command: ^under} = one(dir, %{"command" => under})
      assert %Config{command: "a"} = one(dir, %{"command" => "a"})
      multibyte = String.duplicate("é", 2_048)
      assert %Config{command: ^multibyte} = one(dir, %{"command" => multibyte})

      for command <- [at <> "a", multibyte <> "é", "", "a\0b", 7, nil, ["a"]],
          do: assert(one(dir, %{"command" => command}) =~ "skipped: ")

      assert {[], [_]} = servers(dir, %{"s" => %{}})
    end

    test "at most 64 args of 4,096 bytes with no NUL", %{tmp_dir: dir} do
      # The file holds at most 64 KiB: the count and the size are apart.
      args = List.duplicate("a", 64)
      assert %Config{args: ^args} = one(dir, %{"args" => args})
      assert %Config{args: [_ | _]} = one(dir, %{"args" => tl(args)})
      long = [String.duplicate("é", 2_048)]
      assert %Config{args: ^long} = one(dir, %{"args" => long})
      assert %Config{args: []} = one(dir, %{})

      for args <- [args ++ ["a"], [String.duplicate("a", 4_097)], ["a\0"], [1], "a", %{}],
          do: assert(one(dir, %{"args" => args}) =~ "skipped: ")
    end

    test "at most 64 env pairs; a value never in the notice", %{tmp_dir: dir} do
      env = Map.new(1..64, &{"V#{&1}", "v"})
      assert %Config{env: ^env} = one(dir, %{"env" => env})
      assert %Config{} = one(dir, %{"env" => Map.delete(env, "V1")})
      under = String.duplicate("A", 127)
      assert %Config{env: %{^under => "x"}} = one(dir, %{"env" => %{under => "x"}})
      value = %{"V" => String.duplicate("é", 2_048)}
      assert %Config{env: ^value} = one(dir, %{"env" => value})

      long = String.duplicate("A", 128)

      assert %Config{env: %{^long => "x", "_a9" => ""}} =
               one(dir, %{"env" => %{long => "x", "_a9" => ""}})

      over = Map.put(env, "V65", "v")
      assert one(dir, %{"env" => over}) =~ "an env that is no object of at most 64 pairs"

      for {name, value} <- [
            {long <> "A", "x"},
            {"9A", "x"},
            {"A-B", "x"},
            {"A", "secret\0value"},
            {"A", "secret" <> String.duplicate("s", 4_091)},
            {"A", 7}
          ] do
        notice = one(dir, %{"env" => %{name => value}})
        assert notice =~ "skipped: the env variable"
        refute notice =~ "secret"
      end
    end

    test "a remote or another type is skipped; stdio and no type pass", %{tmp_dir: dir} do
      for fields <- [%{"url" => "http://x"}, %{"httpUrl" => "http://x"}, %{"type" => "sse"}],
          do: assert(one(dir, fields) =~ "Helyx speaks stdio only")

      assert %Config{} = one(dir, %{"type" => "stdio"})
      assert one(dir, %{"disabled" => "yes"}) =~ "a disabled that is no boolean"
      assert %Config{} = one(dir, %{"disabled" => false})
    end

    test "a key that Helyx does not know is ignored", %{tmp_dir: dir} do
      assert %Config{command: "srv"} = one(dir, %{"cwd" => "/x", "timeout" => 5})
    end

    test "a notice names a server by inspect/1 of its first 64 bytes", %{tmp_dir: dir} do
      name = String.duplicate("A", 100)
      notice = one(dir, %{}, name)
      assert notice =~ inspect(String.duplicate("A", 64))
      refute notice =~ String.duplicate("A", 65)
    end

    test "a server that is not an object is skipped", %{tmp_dir: dir} do
      assert {[], [notice]} = servers(dir, %{"s" => "srv"})
      assert notice =~ ~s(MCP server "s" skipped: not an object)
    end
  end

  test "a disabled server is skipped with no notice and takes no place among the 16", %{
    tmp_dir: dir
  } do
    names = for n <- 1..17, do: "s#{String.pad_leading("#{n}", 2, "0")}"
    config = Map.new(names, &{&1, server()})

    config =
      Map.merge(config, %{"a" => server(%{"disabled" => true}), "b" => %{"disabled" => true}})

    {servers, [notice]} = servers(dir, config)
    assert Enum.map(servers, & &1.name) == Enum.take(names, 16)
    assert notice == ~s(1 MCP servers over the cap of 16 were skipped: "s17")
  end

  test "the 16 first by name order are checked, and a bad one keeps its place", %{tmp_dir: dir} do
    names = for n <- 1..20, do: "s#{String.pad_leading("#{n}", 2, "0")}"
    config = names |> Map.new(&{&1, server()}) |> Map.put("s01", server(%{"command" => ""}))

    {servers, [bad, over]} = servers(dir, config)
    assert Enum.map(servers, & &1.name) == names |> Enum.slice(1, 15)
    assert bad =~ ~s(MCP server "s01" skipped)
    assert over =~ "4 MCP servers over the cap of 16 were skipped"
  end

  test "a notice is at most 2,000 bytes", %{tmp_dir: dir} do
    config = Map.new(1..1_500, &{"server-#{&1}", server()})
    {servers, notices} = servers(dir, config)
    assert length(servers) == 16
    assert [over] = notices
    assert byte_size(over) == 2_000
  end

  describe "tool_name/2" do
    test "maps each character outside the rule to _" do
      assert Config.tool_name("gh", "create_issue") == "gh__create_issue"
      assert Config.tool_name("gh", "a.b c/é😀-Z9") == "gh__a_b_c___-Z9"
      assert Config.tool_name("gh", "") == "gh__"
    end

    test "at 52 bytes the name stays; past it, 43 bytes, _, and 8 hex digits of the SHA-256" do
      at = String.duplicate("t", 52 - 4)
      assert Config.tool_name("gh", at) == "gh__" <> at
      under = String.duplicate("t", 51 - 4)
      assert Config.tool_name("gh", under) == "gh__" <> under
      over = at <> "u"
      hash = :crypto.hash(:sha256, over) |> Base.encode16(case: :lower) |> binary_part(0, 8)
      name = Config.tool_name("gh", over)
      assert name == binary_part("gh__" <> over, 0, 43) <> "_" <> hash
      assert byte_size(name) == 52
      assert Helyx.Tool.name?(name)

      # Past 52 bytes the hash is of the MCP name, so two long names that map
      # alike stay apart; two short ones are one name, which Core refuses.
      long = String.duplicate("é", 60)
      refute Config.tool_name("gh", long) == Config.tool_name("gh", String.duplicate("è", 60))
      assert Config.tool_name("gh", "a.b") == Config.tool_name("gh", "a b")
      assert Helyx.Tool.name?(Config.tool_name("srv-name-16bytes", long))
    end
  end
end

defmodule Helyx.Tool.MCP.ConfigPathTest do
  # The path of the config file reads the app env of `helyx_plugins`.
  use ExUnit.Case, async: false

  alias Helyx.Tool.MCP.Config

  test "the app env :mcp_config, else ~/.helyx/mcp.json" do
    assert Config.path() == Path.join(System.user_home!(), ".helyx/mcp.json")
    Application.put_env(:helyx_plugins, :mcp_config, "/etc/helyx/mcp.json")
    on_exit(fn -> Application.delete_env(:helyx_plugins, :mcp_config) end)
    assert Config.path() == "/etc/helyx/mcp.json"
  end
end
