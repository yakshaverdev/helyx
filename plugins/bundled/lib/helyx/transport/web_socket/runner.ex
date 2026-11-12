defmodule Helyx.Transport.WebSocket.Runner do
  @moduledoc """
  The runner of a paired hands connection: the client side of the role
  `hands` of the bundled transport (`docs/features/remote-hands.md`,
  "The runner state"). It pairs with a link, saves its key under
  `<home>/hands/<name>.json`, registers `hands.register {runner, folder}`,
  answers `hands.live`, and reconnects alone after a lost connection. It is
  not a Core plugin and has no registration entry.

  Options: `:link` (a pairing link) or `:name` (a paired runner), `:folder`
  (the absolute folder of the runner), `:home` (the root of the state
  files, default `~/.helyx`), `:notify` (a process that gets
  `{:hands, :waiting}` and `{:hands, {:connected, info}}`), and
  `:reconnect_ms`, `:max_reconnect_ms`, and `:lease_ms` (test seams).

  One process owns the socket and the state. `start_link/1` starts it, and
  `await/1` gives its end as `{:error, :unauthorized}`, `{:error,
  :bad_pin}`, or another error. The private key is held in a closure; it is
  in no process state and in no crash report as a binary.
  """

  use GenServer

  alias Helyx.Transport.WebSocket.{Frame, Pairing}
  alias Helyx.Transport.WebSocket.Runner.{Connection, Handshake, Link, State}

  # The wait after a lost connection, and its cap: a runner is a service.
  @reconnect_ms 1_000
  @max_reconnect_ms 60_000

  # The TCP connect, the TLS handshake, and the upgrade, in all. The
  # server's TLS handshake has a bound of `TLS.handshake_ms/0` (5,000); the
  # TCP connect and the upgrade add to it, so 10,000 covers a slow network
  # with a margin.
  @connect_ms 10_000

  # The wait for the challenge and the welcome together, and for the
  # registration answer: one frame on an open connection, the same bound as
  # the attach of a client.
  @frame_ms 5_000

  defmodule Prepared do
    @moduledoc false
    # Everything a connection needs. The `:sign`, `:private_key`, and
    # `:token` fields are closures, so `inspect/1` of the state prints no
    # secret.
    defstruct [
      :mode,
      :name,
      :address,
      :host,
      :port,
      :pin,
      :folder,
      :home,
      :sign,
      :private_key,
      :public_key,
      :token,
      :notify,
      :base_ms,
      :max_ms,
      :lease_ms
    ]

    @type t :: %__MODULE__{}
  end

  @doc "The wait after the first lost connection, in milliseconds."
  @spec reconnect_ms() :: pos_integer()
  def reconnect_ms, do: @reconnect_ms

  @doc "The cap of the wait after a lost connection, in milliseconds."
  @spec max_reconnect_ms() :: pos_integer()
  def max_reconnect_ms, do: @max_reconnect_ms

  @doc "The bound of the TCP connect, the TLS handshake, and the upgrade."
  @spec connect_ms() :: pos_integer()
  def connect_ms, do: @connect_ms

  @doc "The wait for the challenge and the welcome, and for the registration answer."
  @spec frame_ms() :: pos_integer()
  def frame_ms, do: @frame_ms

  @doc """
  The wait after `attempt` consecutive failed connections: `base`, then
  double, up to `cap`. A connection that reached its registration resets the
  count, so the next wait is `base`.
  """
  @spec wait_ms(pos_integer(), pos_integer(), pos_integer()) :: pos_integer()
  def wait_ms(attempt, base \\ @reconnect_ms, cap \\ @max_reconnect_ms)
      when is_integer(attempt) and attempt >= 1 do
    min(base * Integer.pow(2, min(attempt, 63) - 1), cap)
  end

  @doc """
  Prepares the connection from the options: parses the link, or reads the
  saved state and its key. Gives `{:ok, prepared}` or `{:error, reason}`.
  """
  @spec prepare(keyword() | Prepared.t()) :: {:ok, Prepared.t()} | {:error, term()}
  def prepare(%Prepared{} = prepared), do: {:ok, prepared}

  def prepare(opts) when is_list(opts) do
    common = %{
      home: Keyword.get(opts, :home, Path.expand("~/.helyx")),
      notify: Keyword.get(opts, :notify),
      base_ms: Keyword.get(opts, :reconnect_ms, @reconnect_ms),
      max_ms: Keyword.get(opts, :max_reconnect_ms, @max_reconnect_ms),
      lease_ms: Keyword.get(opts, :lease_ms)
    }

    with :ok <- waits(common.base_ms, common.max_ms, common.lease_ms) do
      case {Keyword.get(opts, :link), Keyword.get(opts, :name)} do
        {link, nil} when is_binary(link) -> pair(link, opts[:folder], common)
        {nil, name} when is_binary(name) -> paired(name, opts[:folder], common)
        _other -> {:error, {:options, :link_or_name}}
      end
    end
  end

  defp waits(base, cap, lease) do
    if is_integer(base) and base > 0 and is_integer(cap) and cap >= base and
         (is_nil(lease) or (is_integer(lease) and lease > 0)),
       do: :ok,
       else: {:error, {:options, :waits}}
  end

  defp pair(link, folder, common) do
    with {:ok, link} <- parse(link),
         {:ok, folder} <- folder(folder) do
      {public, private} = :crypto.generate_key(:eddsa, :ed25519)
      token = link.token

      {:ok,
       %Prepared{
         mode: :pair,
         name: link.name,
         address: link.address,
         host: link.host,
         port: link.port,
         pin: link.pin,
         folder: folder,
         home: common.home,
         sign: sign(private),
         private_key: fn -> private end,
         public_key: public,
         token: fn -> token end,
         notify: common.notify,
         base_ms: common.base_ms,
         max_ms: common.max_ms,
         lease_ms: common.lease_ms
       }}
    end
  end

  defp parse(link) do
    case Link.parse(link) do
      {:ok, link} -> {:ok, link}
      {:error, reason} -> {:error, {:link, reason}}
    end
  end

  defp paired(name, folder, common) do
    with :ok <- name(name),
         {:ok, state} <- State.read(common.home, name),
         {:ok, host, port} <- address(state, common.home, name),
         {:ok, folder} <- folder(folder || state.folder) do
      {:ok,
       %Prepared{
         mode: :name,
         name: name,
         address: state.address,
         host: host,
         port: port,
         pin: state.pin,
         folder: folder,
         home: common.home,
         sign: state.sign,
         private_key: nil,
         public_key: state.public_key,
         token: nil,
         notify: common.notify,
         base_ms: common.base_ms,
         max_ms: common.max_ms,
         lease_ms: common.lease_ms
       }}
    end
  end

  defp address(state, home, name) do
    case Link.address(state.address) do
      {:ok, host, port} -> {:ok, host, port}
      {:error, reason} -> {:error, {:state_file, State.path(home, name), reason}}
    end
  end

  defp name(name) do
    if Pairing.name?(name), do: :ok, else: {:error, {:name, :bad_name}}
  end

  defp folder(nil), do: {:error, {:folder, :missing}}

  defp folder(folder) when is_binary(folder) do
    folder = Path.expand(folder)

    cond do
      byte_size(folder) > Pairing.max_folder_bytes() ->
        {:error, {:folder, :too_long, folder}}

      not File.dir?(folder) ->
        {:error, {:folder, :not_a_directory, folder}}

      true ->
        {:ok, folder}
    end
  end

  defp folder(_folder), do: {:error, {:folder, :not_a_directory}}

  defp sign(private), do: fn text -> :crypto.sign(:eddsa, :none, text, [private, :ed25519]) end

  @doc "Starts a runner; see `prepare/1` for the options."
  @spec start_link(keyword() | Prepared.t()) :: GenServer.on_start()
  def start_link(opts) do
    with {:ok, prepared} <- prepare(opts) do
      GenServer.start_link(__MODULE__, prepared)
    end
  end

  @doc false
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary,
      shutdown: frame_ms()
    }
  end

  @doc "Waits for the end of a runner: `:ok` or `{:error, reason}`."
  @spec await(pid(), timeout()) :: :ok | {:error, term()}
  def await(pid, timeout \\ :infinity) do
    ref = Process.monitor(pid)

    receive do
      {:DOWN, ^ref, :process, ^pid, reason} -> result(reason)
    after
      timeout ->
        Process.demonitor(ref, [:flush])
        {:error, :timeout}
    end
  end

  defp result({:shutdown, reason}), do: {:error, reason}
  defp result(:normal), do: :ok
  defp result(reason), do: {:error, reason}

  @impl true
  def init(%Prepared{} = prepared) do
    {:ok,
     %{
       prepared: prepared,
       cache: nil,
       lease: nil,
       lease_ref: nil,
       connect_ref: nil,
       attempts: 0,
       waiting?: false,
       connected?: false
     }, {:continue, :connect}}
  end

  @impl true
  def handle_continue(:connect, state) do
    case connect(state) do
      {:ok, state} -> {:noreply, state}
      {:error, reason, state} -> failure(reason, state)
    end
  end

  @impl true
  def handle_info({:connect, ref}, %{connect_ref: ref} = state) do
    case connect(%{state | connect_ref: nil}) do
      {:ok, state} -> {:noreply, state}
      {:error, reason, state} -> failure(reason, state)
    end
  end

  def handle_info({:connect, _old}, state), do: {:noreply, state}

  def handle_info({:lease, ref}, %{lease_ref: ref, cache: cache} = state)
      when cache != nil do
    lost(:lease, %{state | lease_ref: nil})
  end

  def handle_info({:lease, _old}, state), do: {:noreply, state}

  def handle_info({:ssl, socket, data}, %{cache: %{socket: socket}} = state) do
    case Connection.stream(state.cache, {:ssl, socket, data}) do
      {:ok, frames, cache} -> frames(frames, %{state | cache: cache})
      {:error, reason, cache} -> lost(reason, %{state | cache: cache})
    end
  end

  def handle_info({:ssl_closed, _socket}, %{cache: cache} = state) when cache != nil,
    do: lost(:closed, state)

  def handle_info({:ssl_error, _socket, reason}, %{cache: cache} = state) when cache != nil,
    do: lost({:transport, reason}, state)

  # A message of a socket that a reconnect left behind: it is not ours.
  def handle_info({:ssl, _socket, _data}, state), do: {:noreply, state}
  def handle_info({:ssl_closed, _socket}, state), do: {:noreply, state}
  def handle_info({:ssl_error, _socket, _reason}, state), do: {:noreply, state}

  # The connection, in order: the TLS connect and the upgrade, the
  # challenge and the welcome, the state file of a pairing, the
  # registration, and active mode.
  defp connect(state) do
    prepared = state.prepared

    case Connection.open(prepared.host, prepared.port, prepared.pin, connect_ms()) do
      {:ok, cache} -> handshake(%{state | cache: cache})
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp handshake(state) do
    prepared = state.prepared

    case Connection.handshake(state.cache, Handshake.hello(prepared), frame_ms()) do
      {:ok, cache} ->
        state = %{state | cache: cache}

        case write_state(prepared) do
          :ok -> register(state)
          {:error, reason} -> {:error, reason, state}
        end

      {:error, reason, cache} ->
        {:error, reason, %{state | cache: cache}}
    end
  end

  defp register(state) do
    prepared = state.prepared

    case Connection.register(state.cache, prepared.name, prepared.folder, frame_ms()) do
      {:ok, lease, cache} ->
        state = %{state | cache: cache, prepared: after_register(prepared)}

        case Connection.activate(cache) do
          {:ok, cache} -> connected(%{state | cache: cache}, lease)
          {:error, reason, cache} -> {:error, reason, %{state | cache: cache}}
        end

      {:error, reason, cache} ->
        {:error, reason, %{state | cache: cache}}
    end
  end

  defp write_state(%Prepared{mode: :name}), do: :ok

  defp write_state(%Prepared{mode: :pair} = prepared) do
    State.write(
      prepared.home,
      prepared.name,
      %{address: prepared.address, pin: prepared.pin, folder: prepared.folder},
      prepared.private_key
    )
  end

  # The link is used by the first connection: a reconnect proves the saved
  # key alone.
  defp after_register(%Prepared{mode: :pair} = prepared),
    do: %{prepared | mode: :name, token: nil, private_key: nil}

  defp after_register(prepared), do: prepared

  defp connected(state, lease) do
    first? = not state.connected?

    state = %{
      state
      | attempts: 0,
        waiting?: false,
        connected?: true,
        lease: lease,
        lease_ref: lease_timer(lease, state)
    }

    notify(
      state,
      {:connected, %{name: state.prepared.name, address: state.prepared.address, first?: first?}}
    )

    {:ok, state}
  end

  defp lease_timer(lease, state) do
    ref = make_ref()
    ms = if state.prepared.lease_ms, do: min(lease, state.prepared.lease_ms), else: lease
    Process.send_after(self(), {:lease, ref}, ms)
    ref
  end

  defp reset_lease(state) do
    cancel(state.lease_ref)
    %{state | lease_ref: lease_timer(state.lease, state)}
  end

  defp cancel(nil), do: :ok

  defp cancel(ref) do
    _ = Process.cancel_timer(ref)
    :ok
  end

  # The frames of the server: a `hands.live` is answered at once, a ping
  # gets a pong, and a close is the end of this connection.
  defp frames([], state), do: {:noreply, state}

  defp frames([{:text, text} | rest], state) do
    if byte_size(text) > Frame.max_frame() do
      lost(:too_large, state)
    else
      case Frame.decode(text, nil, :outbound) do
        {:frame, frame} -> frame(frame, rest, state)
        {:close, _code} -> lost(:bad_frame, state)
      end
    end
  end

  defp frames([{:ping, payload} | rest], state) do
    case Connection.pong(state.cache, payload) do
      {:ok, cache} -> frames(rest, %{state | cache: cache})
      {:error, reason, cache} -> lost(reason, %{state | cache: cache})
    end
  end

  defp frames([{:pong, _payload} | rest], state), do: frames(rest, state)

  defp frames([{:close, code, _reason} | _rest], state), do: lost(close_error(code), state)

  defp frames([_other | rest], state), do: frames(rest, state)

  defp frame(
         %{"type" => "req", "id" => id, "op" => "hands.live", "params" => %{"seq" => seq}},
         rest,
         state
       )
       when is_binary(id) and is_integer(seq) do
    state = reset_lease(state)
    response = %{"type" => "res", "id" => id, "ok" => true, "result" => %{"seq" => seq}}

    case Connection.send_frame(state.cache, response) do
      {:ok, cache} -> frames(rest, %{state | cache: cache})
      {:error, reason, cache} -> lost(reason, %{state | cache: cache})
    end
  end

  defp frame(_frame, rest, state), do: frames(rest, state)

  defp close_error(4401), do: :unauthorized
  defp close_error(_code), do: :closed

  defp lost(reason, state) do
    Connection.close(state.cache)
    cancel(state.lease_ref)
    failure(reason, %{state | cache: nil, lease_ref: nil})
  end

  # A 4401, a wrong pin, and a protocol refusal are permanent: a retry
  # cannot pass.
  defp failure(:unauthorized, state) do
    Connection.close(state.cache)
    remove_state(state)
    {:stop, {:shutdown, :unauthorized}, %{state | cache: nil}}
  end

  defp failure(:bad_pin, state) do
    Connection.close(state.cache)
    {:stop, {:shutdown, :bad_pin}, %{state | cache: nil}}
  end

  defp failure({:refused, server}, state) do
    Connection.close(state.cache)
    {:stop, {:shutdown, {:refused, server}}, %{state | cache: nil}}
  end

  defp failure({:state_file, _path, _reason} = reason, state) do
    Connection.close(state.cache)
    {:stop, {:shutdown, reason}, %{state | cache: nil}}
  end

  defp failure(_reason, state) do
    Connection.close(state.cache)
    state = %{state | cache: nil, attempts: state.attempts + 1}

    state =
      if state.waiting? do
        state
      else
        notify(state, :waiting)
        %{state | waiting?: true}
      end

    wait = wait_ms(state.attempts, state.prepared.base_ms, state.prepared.max_ms)
    ref = make_ref()
    Process.send_after(self(), {:connect, ref}, wait)
    {:noreply, %{state | connect_ref: ref}}
  end

  defp remove_state(%{prepared: %Prepared{mode: :pair} = prepared}) do
    _ = File.rm(State.path(prepared.home, prepared.name))
    :ok
  end

  defp remove_state(_state), do: :ok

  defp notify(%{prepared: %Prepared{notify: pid}} = state, event) when is_pid(pid) do
    send(pid, {:hands, event})
    state
  end

  defp notify(state, _event), do: state
end
