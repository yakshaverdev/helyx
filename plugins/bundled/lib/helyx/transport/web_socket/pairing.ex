defmodule Helyx.Transport.WebSocket.Pairing do
  @moduledoc """
  The pairing of a runner of the public listener, and the hands registrations
  on it (`docs/features/remote-hands.md`, "Pairing and the public listener").

  This process owns the pending links, as a closure of the SHA-256 of their
  bootstrap tokens, the connection of each paired runner, and the lease of
  each hands registration. The closure keeps the hash out of a crash report
  or an `inspect` of the state. It reads and writes the peer rows of
  `Helyx.Hub`; it stores no secret of a peer and no bootstrap token. A link
  is valid for `link_ms/0` and for one successful pairing; at most
  `max_links/0` links wait.

  The link is `helyx-pair:1:<base64url of the JSON {a, t, p, k, n}>`: the
  address, the bootstrap token, the pin, the kind, and the name. This slice
  pairs only the kind `hands`; the client kind comes with #956.
  """

  use GenServer

  alias Helyx.Hub

  # A link waits 10 minutes for its one pairing, and at most 16 wait.
  @link_ms 600_000
  @max_links 16

  # The prefix of a link and its version.
  @prefix "helyx-pair:1:"

  # The one kind that this slice pairs.
  @kind "hands"

  # The bytes of a base64 value of a 32-byte or a 64-byte part.
  @b64_32 44
  @b64_64 88
  # The bytes of the context text of the signature.
  @context "helyx-handshake-v1"

  # The bounds of a name and of the folder of a runner.
  @name_bytes 64
  @folder_bytes 4_096

  @doc "How long a link is valid, in milliseconds."
  @spec link_ms() :: pos_integer()
  def link_ms, do: @link_ms

  @doc "The most links that wait at once."
  @spec max_links() :: pos_integer()
  def max_links, do: @max_links

  @doc "The most bytes of the name of a runner."
  @spec name_bytes() :: pos_integer()
  def name_bytes, do: @name_bytes

  @doc "The most bytes of the folder of a runner."
  @spec max_folder_bytes() :: pos_integer()
  def max_folder_bytes, do: @folder_bytes

  @doc """
  Whether `name` is 1 to `name_bytes/0` bytes of a-z, 0-9, and `_`. One
  function holds the rule, for the wire, the pairing, and the command line.
  """
  @spec name?(term()) :: boolean()
  def name?(name) when is_binary(name) and byte_size(name) in 1..@name_bytes,
    do: name =~ ~r/\A[a-z0-9_]+\z/

  def name?(_name), do: false

  @doc """
  The bytes that a peer signs for a paired `hello`
  (`docs/features/remote-hands.md`, "The handshake of a paired peer"): the
  context text, the nonce, the pin, the kind, and the name, each preceded by
  its length as a 32-bit big-endian integer.
  """
  @spec signature_text(String.t(), String.t(), String.t(), binary()) :: binary()
  def signature_text(pin, kind, name, nonce),
    do: part(@context) <> part(nonce) <> part(pin) <> part(kind) <> part(name)

  defp part(value), do: <<byte_size(value)::32, value::binary>>

  @doc """
  Whether a `hello` of the public listener has the fields of this slice: the
  role `hands`, a name, and one handshake with parts of the right type and
  size. The caller checks this before any other work on the frame.
  """
  @spec valid_hello?(term()) :: boolean()
  def valid_hello?(%{"role" => "hands", "runner" => name} = hello) do
    name?(name) and handshake?(hello)
  end

  def valid_hello?(_hello), do: false

  defp handshake?(%{"pair" => pair} = hello)
       when is_map(pair) and not is_map_key(hello, "signature") do
    map_size(pair) == 3 and
      base64?(pair["proof"], @b64_32) and
      base64?(pair["public_key"], @b64_32) and
      base64?(pair["signature"], @b64_64)
  end

  defp handshake?(%{"signature" => signature} = hello) when not is_map_key(hello, "pair"),
    do: base64?(signature, @b64_64)

  defp handshake?(_hello), do: false

  defp base64?(value, bytes), do: is_binary(value) and byte_size(value) == bytes

  @doc """
  Starts the pairing of one transport. Options: `:hub` (required), `:address`
  (the text a link carries, `host:port`), `:pin` (the pin of the public
  listener), and `:clock` (a 0-arity function of the current monotonic time
  in milliseconds, for a test).
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc "Makes a link for a pairing of a runner, or the error of the cap."
  @spec create(GenServer.server(), String.t(), String.t()) ::
          {:ok, %{String.t() => term()}} | {:error, :bad_params | :too_many_links}
  def create(pairing, kind, name), do: GenServer.call(pairing, {:create, kind, name})

  @doc """
  Deletes the row of a peer and closes its connection, the one path of
  `pair.revoke` and of the operator API.
  """
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
  or the key of a paired runner. Gives `{:ok, "hands", name}`, `{:close,
  4401}` for a handshake that does not hold, or `{:close, 4503}` when the Hub
  gives no answer.
  """
  @spec hello(GenServer.server(), binary(), map(), pid()) ::
          {:ok, String.t(), String.t()} | {:close, 4401 | 4503}
  def hello(pairing, nonce, hello, connection),
    do: GenServer.call(pairing, {:hello, nonce, hello, connection})

  @doc """
  The registration of a hands connection: the answer `{:ok, lease_ms}` when
  the name is the name of its `hello`, else `{:error, :unauthorized}`.
  """
  @spec register_hands(GenServer.server(), pid(), String.t()) ::
          {:ok, pos_integer()} | {:error, :unauthorized}
  def register_hands(pairing, connection, name),
    do: GenServer.call(pairing, {:register_hands, connection, name})

  @impl true
  def init(opts) do
    {:ok,
     %{
       hub: Keyword.fetch!(opts, :hub),
       address: Keyword.fetch!(opts, :address),
       pin: Keyword.fetch!(opts, :pin),
       lease_ms: Keyword.fetch!(opts, :lease_ms),
       clock: Keyword.get(opts, :clock, &now/0),
       links: [],
       connections: %{}
     }}
  end

  @impl true
  def handle_call({:create, kind, name}, _from, state) do
    cond do
      kind != @kind or not name?(name) ->
        {:reply, {:error, :bad_params}, state}

      length(prune(state.links, state)) >= @max_links ->
        {:reply, {:error, :too_many_links}, state}

      true ->
        token = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
        key = :crypto.hash(:sha256, token)

        link = %{"a" => state.address, "t" => token, "p" => state.pin, "k" => kind, "n" => name}
        json = JSON.encode!(link)

        entry = %{
          key: fn -> key end,
          kind: kind,
          name: name,
          expires_at: at(state) + @link_ms
        }

        links = prune(state.links, state) ++ [entry]

        value = %{
          "link" => @prefix <> Base.url_encode64(json, padding: false),
          "expires_ms" => @link_ms
        }

        {:reply, {:ok, value}, %{state | links: links}}
    end
  end

  def handle_call({:revoke, kind, name}, _from, state) do
    # The row may be gone already; the connection is the part that still
    # closes, so a second revoke is not an error (`docs/features/
    # remote-hands.md`, "Revoke").
    case hub(fn -> Hub.revoke_peer(state.hub, kind, name) end) do
      :ok -> {:reply, :ok, close(state, {kind, name})}
      {:error, :not_found} -> {:reply, :ok, close(state, {kind, name})}
      {:error, _reason} = error -> {:reply, error, state}
    end
  end

  def handle_call(:list, _from, state) do
    case hub(fn -> Hub.peers(state.hub) end) do
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
    if valid_hello?(hello) do
      handshake(state, nonce, hello, connection)
    else
      {:reply, {:close, 4401}, state}
    end
  end

  def handle_call({:register_hands, connection, name}, _from, state) do
    case state.connections do
      %{{"hands", ^name} => {^connection, _monitor}} ->
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

  # The two handshakes: a pairing with a link, or the key of a paired runner.
  # The validator holds the shape; these clauses read it.
  defp handshake(state, nonce, %{"pair" => pair, "runner" => name}, connection),
    do: pair(state, nonce, name, pair, connection)

  defp handshake(state, nonce, %{"runner" => name, "signature" => signature}, connection),
    do: paired(state, nonce, name, signature, connection)

  # The pairing of a link: the proof, the signature, the peer row, and the
  # consumed link. A wrong proof or signature, an expired link, another
  # kind or name, and a full store close with 4401, and the link stays. The
  # Hub errors that pass close with 4503, as the authority of the loopback
  # listener does.
  defp pair(state, nonce, name, pair, connection) do
    with {:ok, proof} <- decode(pair["proof"]),
         {:ok, public_key} <- decode(pair["public_key"]),
         {:ok, signature} <- decode(pair["signature"]),
         true <- byte_size(public_key) == 32 and byte_size(signature) == 64,
         {:ok, entry} <- link_entry(state, nonce, proof),
         true <- entry.kind == @kind and entry.name == name,
         true <- verify(state.pin, entry.kind, entry.name, public_key, signature, nonce),
         :ok <- put_peer(state, entry.kind, entry.name, public_key) do
      state = register(%{state | links: List.delete(state.links, entry)}, entry.name, connection)
      {:reply, {:ok, "hands", entry.name}, state}
    else
      {:close, code} -> {:reply, {:close, code}, state}
      _wrong -> {:reply, {:close, 4401}, state}
    end
  end

  # The handshake of a paired runner: the signature of the shared bytes with
  # the key of its row. No row, or a wrong signature, closes with 4401; a
  # Hub that does not answer closes with 4503.
  defp paired(state, nonce, name, signature, connection) do
    with {:ok, signature} <- decode(signature),
         true <- byte_size(signature) == 64,
         {:ok, %{public_key: public_key}} <- peer(state, name),
         true <- verify(state.pin, @kind, name, public_key, signature, nonce) do
      {:reply, {:ok, "hands", name}, register(state, name, connection)}
    else
      {:close, code} -> {:reply, {:close, code}, state}
      _wrong -> {:reply, {:close, 4401}, state}
    end
  end

  defp verify(pin, kind, name, public_key, signature, nonce) do
    :crypto.verify(
      :eddsa,
      :none,
      signature_text(pin, kind, name, nonce),
      signature,
      [public_key, :ed25519]
    )
  end

  # The one pending link whose key makes the proof. The validated name and
  # kind are not in the hello again; the link entry holds them.
  defp link_entry(state, nonce, proof) do
    Enum.find_value(prune(state.links, state), :error, fn entry ->
      if Plug.Crypto.secure_compare(proof_text(entry.key.(), nonce), Base.encode64(proof)),
        do: {:ok, entry}
    end)
  end

  defp proof_text(key, nonce), do: Base.encode64(:crypto.mac(:hmac, :sha256, key, nonce))

  defp put_peer(state, kind, name, public_key) do
    peer = %{kind: kind, name: name, public_key: public_key, created_at: System.os_time(:second)}

    case hub(fn -> Hub.put_peer(state.hub, peer, Hub.max_peers()) end) do
      :ok -> :ok
      {:error, :too_many_peers} -> {:close, 4401}
      {:error, reason} when reason in [:busy, :timeout, :failed] -> {:close, 4503}
    end
  end

  defp peer(state, name) do
    case hub(fn -> Hub.peer(state.hub, @kind, name) end) do
      {:ok, peer} -> {:ok, peer}
      {:error, reason} when reason in [:busy, :timeout, :failed] -> {:close, 4503}
      _missing -> :error
    end
  end

  # One connection for each peer name: a new one closes the old one.
  defp register(state, name, connection) do
    state = close(state, {@kind, name})
    monitor = Process.monitor(connection)
    %{state | connections: Map.put(state.connections, {@kind, name}, {connection, monitor})}
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

  defp prune(links, state), do: Enum.reject(links, &(&1.expires_at <= at(state)))

  defp at(state), do: state.clock.()

  defp now, do: System.monotonic_time(:millisecond)

  defp decode(text) when is_binary(text), do: Base.decode64(text) |> ok()
  defp decode(_other), do: :error

  defp ok({:ok, value}), do: {:ok, value}
  defp ok(:error), do: :error

  # A Hub call that exits (a timeout, a Hub that is down) is a passing error,
  # the same as `{:error, :timeout}`.
  defp hub(fun) do
    fun.()
  catch
    :exit, _reason -> {:error, :timeout}
  end
end
