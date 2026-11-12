defmodule CodingAgent.CLI.Pair do
  @moduledoc false
  # The `pair` command and the `--public` address of `serve`
  # (`docs/features/remote-hands.md`, "Pairing and the public listener").
  # The command runs on the server machine: it finds the server of the data
  # folder as a second start does, makes one link with `pair.create`, and
  # prints it.

  alias Helyx.Transport.WebSocket.Pairing
  alias Helyx.TUI.Wire.Connection

  # The command, for the data folder `dir`.
  def run(opts, [], dir) do
    with :ok <- switches(opts),
         {:ok, kind, name} <- peer_name(opts),
         {:ok, _apps} <- Application.ensure_all_started(:coding_agent),
         {:ok, socket, ws} <- find_server(dir) do
      result = create_link(socket, ws, kind, name)
      with {:error, text} <- result, do: {:error, CodingAgent.clean_line(text)}
    end
  end

  def run(_opts, args, _dir),
    do: {:error, "pair takes no directory argument, got: #{inspect(args)}"}

  # `--public host:port`: the host is the address that a link carries, a DNS
  # name or an IP address; the listener binds every interface, and port 0 is
  # refused.
  def public_option(nil), do: {:ok, nil}

  def public_option(value) when is_binary(value) do
    case Regex.run(~r/\A(?:\[([^\]]+)\]|([A-Za-z0-9.-]+)):(\d+)\z/, value) do
      [_, bracket, "", port] -> public_address(bracket, port, value, true)
      [_, "", host, port] -> public_address(host, port, value, false)
      _other -> public_error(value)
    end
  end

  defp public_address(host, port, value, bracketed) do
    with true <- valid_host?(host),
         {port, ""} <- Integer.parse(port),
         true <- port in 1..65_535 do
      address = if bracketed or ipv6?(host), do: "[#{host}]:#{port}", else: "#{host}:#{port}"
      {:ok, {public_ip(), port, address}}
    else
      _bad -> public_error(value)
    end
  end

  defp public_error(value), do: {:error, "--public takes host:port, got: #{inspect(value)}"}

  defp valid_host?(host) when byte_size(host) in 1..255 do
    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, _ip} -> true
      {:error, _not_ip} -> host =~ ~r/\A[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?\z/
    end
  end

  defp valid_host?(_host), do: false

  defp ipv6?(host) do
    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, ip} -> tuple_size(ip) == 8
      {:error, _not_ip} -> false
    end
  end

  # The listener binds every interface of both families with one dual-stack
  # socket when the host has IPv6, and every IPv4 interface otherwise
  # (`docs/features/remote-hands.md`, "Public listener").
  defp public_ip do
    case :inet.getaddr(~c"::1", :inet6) do
      {:ok, _loopback} -> {0, 0, 0, 0, 0, 0, 0, 0}
      {:error, _no_ipv6} -> {0, 0, 0, 0}
    end
  end

  # Exactly one of `--runner` and `--client`.
  defp switches(opts) do
    case Enum.find(Keyword.keys(opts), &(&1 not in [:runner, :client])) do
      nil -> :ok
      name -> {:error, "--#{name} does not combine with pair"}
    end
  end

  defp peer_name(opts) do
    case {opts[:runner], opts[:client]} do
      {nil, nil} -> {:error, "pair needs --runner name or --client name"}
      {name, nil} -> runner_name(name)
      {nil, name} -> client_name(name)
      {_runner, _client} -> {:error, "--runner does not combine with --client"}
    end
  end

  defp runner_name(name) do
    if Pairing.name?(name),
      do: {:ok, "hands", name},
      else: {:error, "--runner takes 1 to 64 bytes of a-z, 0-9, and _, got: #{inspect(name)}"}
  end

  defp client_name(name) do
    if Pairing.name?(name),
      do: {:ok, "client", name},
      else: {:error, "--client takes 1 to 64 bytes of a-z, 0-9, and _, got: #{inspect(name)}"}
  end

  defp find_server(dir) do
    case CodingAgent.Attach.connect(dir) do
      {:ok, socket, ws} -> {:ok, socket, ws}
      :none -> {:error, "no server runs for #{dir}; start one with helyx serve"}
      {:error, text} -> {:error, text}
    end
  end

  defp create_link(socket, ws, kind, name) do
    {:ok, conn, ref} = Connection.open(socket, ws)

    try do
      case Connection.pair(conn, kind, name) do
        {:ok, %{"link" => link, "expires_ms" => expires_ms}} ->
          IO.puts(link)

          IO.puts(
            "helyx: the link is valid for #{div(expires_ms, 60_000)} minutes, for one pairing"
          )

          :ok

        {:error, code} ->
          {:error, pair_error(code)}
      end
    after
      Process.exit(conn, :kill)
      Process.demonitor(ref, [:flush])
    end
  end

  defp pair_error(:no_public_listener),
    do: "the server has no public listener; start it with helyx serve --public <host>:<port>"

  defp pair_error(:too_many_links),
    do: "the server holds too many pending links; pair one of them, or wait for one to end"

  defp pair_error(:bad_params), do: "the server refused the peer name"
  defp pair_error(:closed), do: "the connection to the server closed"
  defp pair_error(code), do: "the server answered #{code}"
end
