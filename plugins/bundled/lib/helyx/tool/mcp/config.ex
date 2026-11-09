defmodule Helyx.Tool.MCP.Config do
  @moduledoc false
  # The MCP config of `Helyx.Tool.MCP`: the read of the user file, the
  # checks of each server, and the tool name of each MCP tool, with no
  # process (`docs/features/mcp-client.md`, decisions 1, 2, 8, and 13, and
  # "Bounds"). A server is this struct; `read/1` gives the servers that
  # start and the notice texts.

  import Bitwise, only: [&&&: 2]

  defstruct [:name, :command, args: [], env: %{}]

  @type t :: %__MODULE__{
          name: String.t(),
          command: String.t(),
          args: [String.t()],
          env: %{String.t() => String.t()}
        }

  @max_file_bytes 65_536
  @max_servers 16
  @name ~r/\A[a-z0-9][a-z0-9-]{0,15}\z/
  @max_text_bytes 4_096
  @max_args 64
  @max_env 64
  @env_name ~r/\A[A-Za-z_][A-Za-z0-9_]{0,127}\z/
  @text_rule "of at most #{@max_text_bytes} bytes with no NUL"
  @env_rule "a name outside ^[A-Za-z_][A-Za-z0-9_]{0,127}$, " <>
              "or a value that is no string #{@text_rule}"
  # A notice text from a source (`mcp-client.md`, "Bounds").
  @max_notice_bytes 2_000
  # The bytes of a name of the file that a notice shows.
  @max_echo_bytes 64
  @max_tool_name_bytes 52
  # A long tool name keeps this many bytes, then `_` and 8 hex digits.
  @kept_bytes 43

  @doc false
  # The file: the app env `:mcp_config` of `helyx_plugins`, else
  # `~/.helyx/mcp.json`.
  @spec path() :: Path.t()
  def path,
    do:
      Application.get_env(:helyx_plugins, :mcp_config) ||
        Path.join(System.user_home!(), ".helyx/mcp.json")

  @doc false
  # The servers that start, in name order, and the notice texts. A missing
  # file names no server and gives no notice; a file that fails a check
  # names no server and gives one notice.
  @spec read(Path.t()) :: {[t()], [String.t()]}
  def read(path) do
    case file(path) do
      :missing ->
        {[], []}

      {:ok, servers} ->
        check_servers(servers)

      {:error, reason} ->
        # The reason first: the path, escaped, can be long, and the cut keeps the head.
        {[], [notice("MCP config #{reason}; no MCP server starts: #{inspect(path)}")]}
    end
  end

  # A regular file of at most 64 KiB without the group or other write bit,
  # and JSON with no repeated key at any depth, whose `mcpServers` is an
  # object, or absent.
  defp file(path) do
    with :ok <- stat(path),
         {:ok, text} <- read_text(path),
         {:ok, config} <- json(text) do
      servers_of(config)
    end
  end

  defp stat(path) do
    case File.stat(path) do
      {:ok, %File.Stat{mode: mode}} when (mode &&& 0o022) == 0 -> :ok
      {:ok, _stat} -> {:error, "is writable by others"}
      {:error, :enoent} -> :missing
      {:error, reason} -> {:error, "cannot be read: #{:file.format_error(reason)}"}
    end
  end

  defp read_text(path) do
    case Helyx.Text.read_file(path, @max_file_bytes) do
      {:ok, text} -> {:ok, text}
      {:error, reason} -> {:error, "cannot be read: #{reason}"}
    end
  end

  defp json(text) do
    case Helyx.JSON.decode(text, :unique_keys) do
      {:ok, config} -> {:ok, config}
      {:error, :duplicate_key} -> {:error, "repeats a key"}
      {:error, _reason} -> {:error, "is not JSON"}
    end
  end

  defp servers_of(%{"mcpServers" => %{} = servers}), do: {:ok, servers}
  defp servers_of(%{"mcpServers" => _}), do: {:error, "has an mcpServers that is no object"}
  defp servers_of(%{}), do: {:ok, %{}}
  defp servers_of(_config), do: {:error, "is no JSON object"}

  # A disabled server takes no place among the 16; the first 16 others by
  # name order are checked, and the rest skipped with one notice. The sort
  # and the notice see every server of the file, at most some thousands in
  # its 64 KiB.
  defp check_servers(servers) do
    {checked, skipped} =
      servers
      |> Enum.reject(fn {_name, server} -> match?(%{"disabled" => true}, server) end)
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.split(@max_servers)

    results = for {name, server} <- checked, do: check(name, server)
    servers = for {:ok, server} <- results, do: server
    notices = for {:error, text} <- results, do: notice(text)
    {servers, notices ++ over_cap(skipped)}
  end

  defp over_cap([]), do: []

  defp over_cap(skipped) do
    names = Enum.map_join(skipped, ", ", fn {name, _server} -> echo(name) end)

    [
      notice(
        "#{length(skipped)} MCP servers over the cap of #{@max_servers} were skipped: #{names}"
      )
    ]
  end

  defp check(name, server) do
    with :ok <- check_name(name),
         {:ok, server} <- object(server),
         :ok <- stdio(server),
         :ok <- disabled(server),
         {:ok, command} <- command(server),
         {:ok, args} <- args(server),
         {:ok, env} <- env(server) do
      {:ok, %__MODULE__{name: name, command: command, args: args, env: env}}
    else
      {:error, reason} -> {:error, "MCP server #{echo(name)} skipped: #{reason}"}
    end
  end

  defp check_name(name) do
    if Regex.match?(@name, name),
      do: :ok,
      else: {:error, "a name outside ^[a-z0-9][a-z0-9-]{0,15}$"}
  end

  defp object(%{} = server), do: {:ok, server}
  defp object(_server), do: {:error, "not an object"}

  defp stdio(server) do
    cond do
      Map.has_key?(server, "url") or Map.has_key?(server, "httpUrl") ->
        {:error, "a remote server; Helyx speaks stdio only"}

      Map.get(server, "type", "stdio") != "stdio" ->
        {:error, "a type other than stdio; Helyx speaks stdio only"}

      true ->
        :ok
    end
  end

  defp disabled(%{"disabled" => disabled}) when not is_boolean(disabled),
    do: {:error, "a disabled that is no boolean"}

  defp disabled(_server), do: :ok

  defp command(%{"command" => command}) when is_binary(command) and command != "" do
    if text?(command), do: {:ok, command}, else: {:error, "a command #{@text_rule}"}
  end

  defp command(_server), do: {:error, "no command, a string of 1 to #{@max_text_bytes} bytes"}

  defp args(%{"args" => args}) when is_list(args) and length(args) <= @max_args do
    if Enum.all?(args, &(is_binary(&1) and text?(&1))),
      do: {:ok, args},
      else: {:error, "an argument that is no string #{@text_rule}"}
  end

  defp args(%{"args" => _}), do: {:error, "args that are no list of at most #{@max_args} strings"}
  defp args(_server), do: {:ok, []}

  # A value never goes into a notice.
  defp env(%{"env" => %{} = env}) when map_size(env) <= @max_env do
    case Enum.find(env, fn {name, value} -> not env_pair?(name, value) end) do
      nil -> {:ok, env}
      {name, _value} -> {:error, "the env variable #{echo(name)}: #{@env_rule}"}
    end
  end

  defp env(%{"env" => _}), do: {:error, "an env that is no object of at most #{@max_env} pairs"}
  defp env(_server), do: {:ok, %{}}

  defp env_pair?(name, value),
    do: Regex.match?(@env_name, name) and is_binary(value) and text?(value)

  # JSON gives valid UTF-8.
  defp text?(text), do: byte_size(text) <= @max_text_bytes and not String.contains?(text, <<0>>)

  # A name of the file as the notice shows it: escaped, and cut.
  defp echo(name), do: name |> Helyx.Text.cap(@max_echo_bytes, :head) |> inspect()

  defp notice(text), do: Helyx.Text.cap(text, @max_notice_bytes, :head)

  @doc false
  # The tool name of the MCP tool `tool` of the server `server`:
  # `<server>__<tool>`, each character of `tool` outside `[A-Za-z0-9_-]` as
  # `_`; past 52 bytes, its first 43 bytes, `_`, and the first 8 hex digits
  # of the SHA-256 of `tool` (`mcp-client.md`, decision 8).
  @spec tool_name(String.t(), String.t()) :: String.t()
  def tool_name(server, tool) do
    name = server <> "__" <> String.replace(tool, ~r/[^A-Za-z0-9_-]/u, "_")

    if byte_size(name) <= @max_tool_name_bytes do
      name
    else
      hash = :crypto.hash(:sha256, tool) |> Base.encode16(case: :lower) |> binary_part(0, 8)
      binary_part(name, 0, @kept_bytes) <> "_" <> hash
    end
  end
end
