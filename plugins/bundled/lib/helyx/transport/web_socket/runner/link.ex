defmodule Helyx.Transport.WebSocket.Runner.Link do
  @moduledoc false
  # The link of a runner pairing, `helyx-pair:1:<base64url JSON>`
  # (`docs/features/remote-hands.md`, "The link"). The command line is a
  # boundary: every field is checked here before the runner connects, and an
  # error names the fault and never the bootstrap token.

  alias Helyx.Transport.WebSocket.Pairing

  @prefix "helyx-pair:1:"
  @scheme "helyx-pair:"
  @kind "hands"

  @doc "The prefix of a link of any version, for a command line that refuses one."
  @spec scheme() :: String.t()
  def scheme, do: @scheme

  @doc """
  The text with every pairing link in it cut to its prefix, for a printed
  line. The prefix alone, as a fault line names it, stays: a link has at
  least 16 bytes after it.
  """
  @spec hide(String.t()) :: String.t()
  def hide(text),
    do: String.replace(text, ~r/#{Regex.escape(@scheme)}[^\s"']{16,}/, @scheme <> "...")

  # The longest link that `Pairing.create/3` makes through the `--public`
  # argument: a host of at most 255 bytes, a port of 5 digits and 2 brackets,
  # the 43-byte token, the 43-byte pin, the kind, and a 64-byte name are 453
  # bytes of JSON, base64url makes 604, and the prefix is 12. 1,024 leaves a
  # margin for the JSON syntax.
  @max_bytes 1_024

  @doc "The most bytes of a link."
  @spec max_bytes() :: pos_integer()
  def max_bytes, do: @max_bytes

  @doc """
  Parses a link to its fields: the address text, the host, the port, the
  bootstrap token, the pin, the kind, and the name.
  """
  @spec parse(term()) :: {:ok, map()} | {:error, atom()}
  def parse(link) when is_binary(link) do
    with :ok <- size(link),
         {:ok, encoded} <- prefix(link),
         {:ok, json} <- decode(encoded),
         {:ok, fields} <- fields(json),
         {:ok, kind} <- kind(fields["k"]),
         {:ok, name} <- name(fields["n"]),
         {:ok, host, port} <- address(fields["a"]) do
      {:ok,
       %{
         address: fields["a"],
         host: host,
         port: port,
         token: fields["t"],
         pin: fields["p"],
         kind: kind,
         name: name
       }}
    end
  end

  def parse(_link), do: {:error, :bad_prefix}

  @doc false
  # The host and the port of an address text, as a link and a state file
  # carry it.
  @spec address(term()) :: {:ok, term(), pos_integer()} | {:error, atom()}
  def address(address) when is_binary(address) do
    case address do
      "[" <> rest -> ipv6(rest)
      text -> host_port(text)
    end
  end

  def address(_address), do: {:error, :bad_address}

  defp size(link) do
    if byte_size(link) <= @max_bytes, do: :ok, else: {:error, :link_too_long}
  end

  defp prefix(link) do
    if String.starts_with?(link, @prefix),
      do: {:ok, binary_part(link, byte_size(@prefix), byte_size(link) - byte_size(@prefix))},
      else: {:error, :bad_prefix}
  end

  defp decode(encoded) do
    with {:ok, json} <- base64(encoded),
         {:ok, %{} = map} <- json(json) do
      {:ok, map}
    else
      {:ok, _not_a_map} -> {:error, :bad_field}
      {:error, reason} -> {:error, reason}
    end
  end

  defp base64(encoded) do
    case Base.url_decode64(encoded, padding: false) do
      {:ok, json} -> {:ok, json}
      :error -> {:error, :bad_encoding}
    end
  rescue
    ArgumentError -> {:error, :bad_encoding}
  end

  defp json(json) do
    case Helyx.JSON.decode(json) do
      {:ok, map} -> {:ok, map}
      {:error, _reason} -> {:error, :bad_encoding}
    end
  end

  defp fields(map) do
    if Enum.all?(~w(a t p k n), &is_binary(map[&1])),
      do: {:ok, map},
      else: {:error, :bad_field}
  end

  defp kind(@kind), do: {:ok, @kind}
  defp kind(_kind), do: {:error, :bad_kind}

  defp name(name) do
    if Pairing.name?(name), do: {:ok, name}, else: {:error, :bad_name}
  end

  defp ipv6(rest) do
    with [host, port] <- String.split(rest, "]:", parts: 2),
         {:ok, ip} <- ip(host),
         true <- tuple_size(ip) == 8 do
      with {:ok, port} <- port(port), do: {:ok, ip, port}
    else
      {:error, reason} -> {:error, reason}
      _other -> {:error, :bad_address}
    end
  end

  defp host_port(text) do
    with [host, port] <- String.split(text, ":", parts: 2),
         true <- host?(host),
         {:ok, port} <- port(port) do
      {:ok, host, port}
    else
      {:error, reason} -> {:error, reason}
      _other -> {:error, :bad_address}
    end
  end

  defp ip(host) do
    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, ip} -> {:ok, ip}
      {:error, _not_an_ip} -> {:error, :bad_address}
    end
  end

  defp host?(host) do
    byte_size(host) in 1..255 and String.valid?(host) and
      not (host =~ ~r/[\x00-\x1F\x7F]/)
  end

  defp port(text) do
    case Integer.parse(text) do
      {port, ""} when port in 1..65_535 -> {:ok, port}
      {_port, ""} -> {:error, :bad_port}
      _other -> {:error, :bad_address}
    end
  end
end
