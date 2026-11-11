defmodule Helyx.Transport.WebSocket.Pairing do
  @moduledoc """
  The pairing of a peer of the public listener, and the hands registrations
  on it (`docs/features/remote-hands.md`, "Pairing and the public listener").

  This process owns the pending links, as the SHA-256 of their bootstrap
  tokens, the connection of each paired peer, and the lease of each hands
  registration. It reads and writes the peer rows of `Helyx.Hub`; it stores
  no secret of a peer and no bootstrap token. A link is valid for
  `link_ms/0` and for one successful pairing; at most `max_links/0` links
  wait.

  The link is `helyx-pair:1:<base64url of the JSON {a, t, p, k, n}>`: the
  address, the bootstrap token, the pin, the kind, and the name.
  """

  use GenServer

  alias Helyx.Hub

  # A link waits 10 minutes for its one pairing, and at most 16 wait.
  @link_ms 600_000
  @max_links 16

  # The prefix of a link and its version.
  @prefix "helyx-pair:1:"

  # The kinds of a peer.
  @kinds ~w(hands client)

  @doc "How long a link is valid, in milliseconds."
  @spec link_ms() :: pos_integer()
  def link_ms, do: @link_ms

  @doc "The most links that wait at once."
  @spec max_links() :: pos_integer()
  def max_links, do: @max_links

  @doc """
  Starts the pairing of one transport. Options: `:hub` (required), `:address`
  (the text a link carries, `host:port`), `:pin` (the pin of the public
  listener), and `:clock` (a 0-arity function of the current monotonic time
  in milliseconds, for a test).
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc "Makes a link for a pairing of `kind` and `name`, or the error of the cap."
  @spec create(GenServer.server(), String.t(), String.t()) ::
          {:ok, %{String.t() => term()}} | {:error, :bad_params | :too_many_links}
  def create(pairing, kind, name), do: GenServer.call(pairing, {:create, kind, name})

  @doc "Deletes a peer and closes its connection."
  @spec revoke(GenServer.server(), String.t(), String.t()) :: :ok | {:error, term()}
  def revoke(pairing, kind, name), do: GenServer.call(pairing, {:revoke, kind, name})

  @doc "The peers of the server, with whether each is connected."
  @spec list(GenServer.server()) :: {:ok, [map()]} | {:error, term()}
  def list(pairing), do: GenServer.call(pairing, :list)

  @doc """
  One pairing operation of the wire: `pair.create`, `pair.revoke`, or
  `pair.list`. Gives `{:ok, result}` or the code of the wire as an atom.
  """
  @spec request(GenServer.server(), String.t(), map()) ::
          {:ok, map()} | {:error, atom()}
  def request(pairing, "pair.create", %{"kind" => kind, "name" => name} = params)
      when map_size(params) == 2,
      do: create(pairing, kind, name)

  def request(pairing, "pair.revoke", %{"kind" => kind, "name" => name} = params)
      when map_size(params) == 2 do
    case revoke(pairing, kind, name) do
      :ok -> {:ok, %{}}
      error -> error
    end
  end

  def request(pairing, "pair.list", params) when map_size(params) == 0 do
    case list(pairing) do
      {:ok, peers} -> {:ok, %{"peers" => peers}}
      error -> error
    end
  end

  def request(_pairing, _op, _params), do: {:error, :bad_params}

  @doc """
  The handshake of a `hello` on the public listener: a pairing with a link,
  or the key of a paired peer. Gives `{:ok, role, name}` or `{:close, 4401}`.
  """
  @spec hello(GenServer.server(), binary(), map(), pid()) ::
          {:ok, String.t(), String.t() | nil} | {:close, 4401}
  def hello(pairing, nonce, hello, connection),
    do: GenServer.call(pairing, {:hello, nonce, hello, connection})

  @doc """
  The registration of a hands connection: the answer `{:ok, lease_ms}` when
  the name is the name of its `hello`, else `{:error, :unauthorized}`.
  """
  @spec register_hands(GenServer.server(), pid(), String.t(), String.t()) ::
          {:ok, pos_integer()} | {:error, :unauthorized}
  def register_hands(pairing, connection, name, folder),
    do: GenServer.call(pairing, {:register_hands, connection, name, folder})

  @impl true
  def init(opts) do
    {:ok,
     %{
       hub: Keyword.fetch!(opts, :hub),
       address: Keyword.fetch!(opts, :address),
       pin: Keyword.fetch!(opts, :pin),
       lease_ms: Keyword.fetch!(opts, :lease_ms),
       clock: Keyword.get(opts, :clock, &now/0),
       links: %{},
       connections: %{}
     }}
  end

  @impl true
  def handle_call({:create, kind, name}, _from, state) do
    cond do
      kind not in @kinds or not name?(name) ->
        {:reply, {:error, :bad_params}, state}

      map_size(prune(state.links, state)) >= @max_links ->
        {:reply, {:error, :too_many_links}, state}

      true ->
        token = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
        key = :crypto.hash(:sha256, token)

        link = %{"a" => state.address, "t" => token, "p" => state.pin, "k" => kind, "n" => name}
        json = JSON.encode!(link)

        entry = %{kind: kind, name: name, expires_at: at(state) + @link_ms}
        links = Map.put(prune(state.links, state), key, entry)

        value = %{
          "link" => @prefix <> Base.url_encode64(json, padding: false),
          "expires_ms" => @link_ms
        }

        {:reply, {:ok, value}, %{state | links: links}}
    end
  end

  def handle_call({:revoke, kind, name}, _from, state) do
    case Hub.revoke_peer(state.hub, kind, name) do
      :ok ->
        {:reply, :ok,
         close(%{state | connections: disconnect(state.connections, {kind, name})}, {kind, name})}

      {:error, _reason} = error ->
        {:reply, error, state}
    end
  end

  def handle_call(:list, _from, state) do
    case Hub.peers(state.hub) do
      {:ok, peers} ->
        items =
          Enum.map(peers, fn peer ->
            %{
              "kind" => peer.kind,
              "name" => peer.name,
              "created_at" => peer.created_at,
              "connected" => Map.has_key?(state.connections, {peer.kind, peer.name})
            }
          end)

        {:reply, {:ok, items}, state}

      error ->
        {:reply, error, state}
    end
  end

  def handle_call({:hello, nonce, hello, connection}, _from, state) do
    role = hello["role"]
    name = hello["runner"]
    kind = kind(role)

    cond do
      kind == nil or (role == "hands" and not name?(name)) ->
        {:reply, {:close, 4401}, state}

      is_map(hello["pair"]) ->
        pair(state, nonce, kind, name, hello["pair"], connection)

      is_binary(hello["signature"]) ->
        paired(state, nonce, kind, name, hello["signature"], connection)

      true ->
        {:reply, {:close, 4401}, state}
    end
  end

  def handle_call({:register_hands, connection, name, folder}, _from, state) do
    case state.connections do
      %{{"hands", ^name} => {^connection, _monitor}}
      when is_binary(folder) and byte_size(folder) <= 4_096 ->
        {:reply, {:ok, state.lease_ms}, state}

      _other ->
        {:reply, {:error, :unauthorized}, state}
    end
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    connections =
      state.connections
      |> Enum.reject(fn {_key, {conn, _monitor}} -> conn == pid end)
      |> Map.new()

    {:noreply, %{state | connections: connections}}
  end

  # The pairing of a link: the proof, the signature, the peer row, and the
  # consumed link. A wrong proof or signature, an expired link, another
  # kind, and a full store close with 4401, and the link stays.
  defp pair(state, nonce, kind, name, %{} = pair, connection) do
    with {:ok, proof} <- decode(pair["proof"]),
         {:ok, public_key} <- decode(pair["public_key"]),
         {:ok, signature} <- decode(pair["signature"]),
         true <- byte_size(public_key) == 32 and byte_size(signature) == 64,
         {:ok, key} <- link_key(state, kind, name, nonce, proof),
         true <- :crypto.verify(:eddsa, :none, nonce, signature, [public_key, :ed25519]),
         :ok <- put_peer(state, kind, name, public_key) do
      state = register(%{state | links: Map.delete(state.links, key)}, kind, name, connection)
      {:reply, {:ok, kind, name}, state}
    else
      _wrong -> {:reply, {:close, 4401}, state}
    end
  end

  defp pair(state, _nonce, _kind, _name, _pair, _connection), do: {:reply, {:close, 4401}, state}

  # The handshake of a paired peer: the signature of the nonce with the key
  # of its row.
  defp paired(state, nonce, kind, name, signature, connection) do
    with {:ok, signature} <- decode(signature),
         {:ok, %{public_key: public_key}} <- Hub.peer(state.hub, kind, name),
         true <- :crypto.verify(:eddsa, :none, nonce, signature, [public_key, :ed25519]) do
      {:reply, {:ok, kind, name}, register(state, kind, name, connection)}
    else
      _wrong -> {:reply, {:close, 4401}, state}
    end
  end

  # The one pending link of this kind and name whose key makes the proof.
  defp link_key(state, kind, name, nonce, proof) do
    Enum.find_value(state.links, :error, fn {key, entry} ->
      if entry.kind == kind and entry.name == name and entry.expires_at > at(state) and
           Plug.Crypto.secure_compare(proof_text(key, nonce), Base.encode64(proof)),
         do: {:ok, key}
    end)
  end

  defp proof_text(key, nonce), do: Base.encode64(:crypto.mac(:hmac, :sha256, key, nonce))

  defp put_peer(state, kind, name, public_key) do
    peer = %{kind: kind, name: name, public_key: public_key, created_at: System.os_time(:second)}
    Hub.put_peer(state.hub, peer, Hub.max_peers())
  end

  # One connection for each peer name: a new one closes the old one.
  defp register(state, kind, name, connection) do
    key = {kind, name}
    state = close(state, key)
    monitor = Process.monitor(connection)
    %{state | connections: Map.put(state.connections, key, {connection, monitor})}
  end

  defp close(state, key) do
    case Map.fetch(state.connections, key) do
      {:ok, {connection, monitor}} ->
        Process.demonitor(monitor, [:flush])
        send(connection, {:close, 4401})
        %{state | connections: Map.delete(state.connections, key)}

      :error ->
        state
    end
  end

  defp disconnect(connections, key) do
    case Map.fetch(connections, key) do
      {:ok, {connection, monitor}} ->
        Process.demonitor(monitor, [:flush])
        send(connection, {:close, 4401})
        Map.delete(connections, key)

      :error ->
        connections
    end
  end

  defp prune(links, state),
    do: Map.reject(links, fn {_key, entry} -> entry.expires_at <= at(state) end)

  defp at(state), do: state.clock.()

  defp now, do: System.monotonic_time(:millisecond)

  defp kind("hands"), do: "hands"
  defp kind("client"), do: "client"
  defp kind(_other), do: nil

  defp decode(text) when is_binary(text), do: Base.decode64(text) |> ok()
  defp decode(_other), do: :error

  defp ok({:ok, value}), do: {:ok, value}
  defp ok(:error), do: :error

  # 1 to 64 bytes of a-z, 0-9, and _.
  defp name?(name) when is_binary(name) and byte_size(name) in 1..64,
    do: name =~ ~r/\A[a-z0-9_]+\z/

  defp name?(_name), do: false
end
