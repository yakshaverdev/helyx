defmodule Helyx.TUI.Wire do
  @moduledoc """
  The wire client of the TUI: a WebSocket connection to `helyx serve` over
  TCP and the handshake of `docs/features/wire-protocol.md` (O1). The rules
  of the client are in `docs/features/tui-attach.md`.

  Mint upgrades the connection and encodes and decodes the WebSocket frames
  (`Mint.WebSocket`); the socket stays a raw `:gen_tcp` socket that the
  connection process reads and the writer process writes (decision 15).
  """

  alias Helyx.Transport.WebSocket
  alias Helyx.Transport.WebSocket.Frame
  alias Helyx.TUI.Wire.Reader

  # Mint.WebSocket.recv/3 types the connection of its error as its opaque
  # WebSocket type, and Reader.read/2 takes that opaque type, so Dialyzer
  # drops both branches. They run: recv delegates to Mint.HTTP.recv/3 before
  # new/5, and decode returns the same state it takes.
  @dialyzer {:nowarn_function, [reply: 5, recv_reply: 6, early: 2, next: 5]}

  # The head of the upgrade reply, in all: Mint refuses a larger head and a
  # longer status line or header. The old client capped each line at 8,192
  # bytes and the lines at 64, which Mint does not.
  @max_head 64 * 8_192

  @typedoc """
  `{:refused, server_protocol}` for a server of another protocol, `:broken`
  for a frame that the handshake does not allow, or a text: the server
  cannot be reached yet or closed the connection.
  """
  @type error :: {:refused, non_neg_integer()} | :broken | String.t()

  @doc """
  Connects to the server at `ip` and `port`, upgrades the connection, and
  passes the handshake with the proof of the token that `token` returns,
  all within `timeout` milliseconds. Returns the socket after `welcome`,
  passive and owned by the caller, and the WebSocket state that the caller
  keeps for the frames after it. A failure up to the `101` reply, a close
  of the server, and the timeout give a text; the socket is closed on every
  error. No error holds the token.
  """
  @spec connect(:inet.ip_address(), :inet.port_number(), (-> binary()), pos_integer()) ::
          {:ok, :gen_tcp.socket(), term()} | {:error, error()}
  def connect(ip, port, token, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout

    opts = [
      protocols: [:http1],
      mode: :passive,
      hostname: host(ip),
      # The conventional casing of the handshake headers, as the old client
      # sent them.
      case_sensitive_headers: true,
      max_header_list_size: @max_head,
      transport_opts: [timeout: left(deadline), send_timeout: timeout]
    ]

    case Mint.HTTP.connect(:http, ip, port, opts) do
      {:ok, conn} -> connected(conn, token, timeout, deadline)
      {:error, error} -> {:error, error_text(error, timeout)}
    end
  end

  defp connected(conn, token, timeout, deadline) do
    with {:ok, conn, ref} <- upgrade(conn, timeout),
         {:ok, conn, status, headers, early} <- reply(conn, ref, deadline, timeout),
         {:ok, conn, ws} <- websocket(conn, ref, status, headers) do
      socket = Mint.HTTP.get_socket(conn)
      :ok = :inet.setopts(socket, active: false, packet: :raw)

      case handshake(socket, ws, early, token, deadline, timeout) do
        {:ok, ws} ->
          {:ok, socket, ws}

        {:error, reason} ->
          :gen_tcp.close(socket)
          {:error, reason}
      end
    else
      {:error, conn, text} ->
        Mint.HTTP.close(conn)
        {:error, text}
    end
  end

  defp upgrade(conn, timeout) do
    case Mint.WebSocket.upgrade(:ws, conn, "/", []) do
      {:ok, conn, ref} -> {:ok, conn, ref}
      {:error, conn, error} -> {:error, conn, error_text(error, timeout)}
    end
  end

  # The reply by its lines: the status, the headers, and any bytes of the
  # frames that came after them. A status that is not `101` ends the read at
  # once, as the old client did, not at the end of a body.
  defp reply(conn, ref, deadline, timeout, acc \\ {nil, [], []}) do
    case left(deadline) do
      0 -> {:error, conn, "no welcome from the server in #{timeout} ms"}
      wait -> recv_reply(conn, ref, deadline, timeout, acc, wait)
    end
  end

  defp recv_reply(conn, ref, deadline, timeout, acc, wait) do
    case Mint.WebSocket.recv(conn, 0, wait) do
      {:ok, conn, responses} ->
        reply_responses(conn, ref, deadline, timeout, acc, responses)

      {:error, conn, error, responses} ->
        case responses(conn, responses, ref, acc) do
          {:ok, _acc} -> {:error, conn, error_text(error, timeout)}
          {:done, status, headers, early} -> {:ok, conn, status, headers, early}
          {:error, conn, text} -> {:error, conn, text}
        end
    end
  end

  defp reply_responses(conn, ref, deadline, timeout, acc, responses) do
    case responses(conn, responses, ref, acc) do
      {:ok, acc} -> reply(conn, ref, deadline, timeout, acc)
      {:done, status, headers, early} -> {:ok, conn, status, headers, early}
      {:error, conn, text} -> {:error, conn, text}
    end
  end

  defp responses(_conn, [], _ref, acc), do: {:ok, acc}

  defp responses(conn, [{:status, ref, 101} | rest], ref, {_status, headers, early}),
    do: responses(conn, rest, ref, {101, headers, early})

  defp responses(conn, [{:status, ref, status} | _rest], ref, _acc),
    do: {:error, conn, "the upgrade got HTTP #{status}"}

  defp responses(conn, [{:headers, ref, headers} | rest], ref, {status, _old, early}),
    do: responses(conn, rest, ref, {status, headers, early})

  defp responses(conn, [{:data, ref, data} | rest], ref, {status, headers, early}),
    do: responses(conn, rest, ref, {status, headers, [early, data]})

  defp responses(_conn, [{:done, ref} | _rest], ref, {101, headers, early}),
    do: {:done, 101, headers, IO.iodata_to_binary(early)}

  defp responses(conn, [{:done, ref} | _rest], ref, _acc),
    do: {:error, conn, "the reply to the upgrade is not a WebSocket upgrade"}

  defp responses(conn, [_other | rest], ref, acc), do: responses(conn, rest, ref, acc)

  @spec websocket(Mint.HTTP.t(), reference(), 101, Mint.Types.headers()) ::
          {:ok, Mint.HTTP.t(), term()}
          | {:error, Mint.HTTP.t(), String.t()}
  defp websocket(conn, ref, 101, headers) do
    case Mint.WebSocket.new(conn, ref, 101, headers, mode: :passive) do
      {:ok, conn, ws} ->
        {:ok, conn, ws}

      {:error, conn, _error} ->
        {:error, conn, "the reply to the upgrade is not a WebSocket upgrade"}
    end
  end

  # The challenge, the hello with the proof of the token, and the welcome.
  # The frames that came with the `101` reply go first; anything after
  # `welcome` came before a request, so a close ends the handshake, and a
  # text or a broken frame is a contract break. A ping is skipped, as it was
  # before the rewrite.
  defp handshake(socket, ws, early, token, deadline, timeout) do
    with {:ok, ws, queue} <- early(ws, early),
         {:ok, nonce, ws, queue} <- challenge(socket, ws, queue, deadline, timeout),
         {:ok, ws} <- send_frame(socket, ws, hello(nonce, token), timeout),
         {:ok, ws, queue} <- welcome(socket, ws, queue, deadline, timeout),
         :ok <- settle(queue) do
      {:ok, ws}
    end
  end

  defp settle([]), do: :ok
  defp settle([{:ping, _data} | rest]), do: settle(rest)
  defp settle([{:close, code, _reason} | _rest]), do: {:error, close_text(code)}
  defp settle([_text_or_broken | _rest]), do: {:error, :broken}

  # The frames that came with the `101` reply, decoded before the reads.
  defp early(ws, ""), do: {:ok, ws, []}

  defp early(ws, bytes) do
    case Reader.read(ws, bytes) do
      {:ok, messages, ws} -> {:ok, ws, messages}
      {:partial, messages, ws} -> {:ok, ws, messages ++ [:broken]}
      :broken -> {:error, :broken}
    end
  end

  # The next text of the server, decoded with the decode bounds of the wire
  # (`Helyx.Transport.WebSocket.Frame`): a JSON map, or `:broken`. A ping
  # between the frames is skipped, as it was before the rewrite.
  defp text(socket, ws, queue, deadline, timeout) do
    case next(socket, ws, queue, deadline, timeout) do
      {:ok, {:text, text}, ws, queue} ->
        case Frame.decode(text, nil) do
          {:frame, frame} -> {:ok, frame, ws, queue}
          _ -> {:error, :broken}
        end

      {:ok, {:ping, _data}, ws, queue} ->
        text(socket, ws, queue, deadline, timeout)

      {:ok, {:close, code, _reason}, _ws, _queue} ->
        {:error, close_text(code)}

      {:error, _} = error ->
        error
    end
  end

  defp next(socket, ws, messages, deadline, timeout, pending \\ 0)
  defp next(_socket, _ws, [:broken | _rest], _deadline, _timeout, _pending), do: {:error, :broken}

  defp next(_socket, ws, [message | rest], _deadline, _timeout, _pending),
    do: {:ok, message, ws, rest}

  defp next(socket, ws, [], deadline, timeout, pending) do
    case left(deadline) do
      0 -> {:error, "no welcome from the server in #{timeout} ms"}
      wait -> recv_next(socket, ws, deadline, timeout, wait, pending)
    end
  end

  defp recv_next(socket, ws, deadline, timeout, wait, pending) do
    case :gen_tcp.recv(socket, 0, wait) do
      {:ok, data} -> next_read(socket, ws, data, deadline, timeout, pending)
      {:error, reason} -> {:error, error_text(%Mint.TransportError{reason: reason}, timeout)}
    end
  end

  defp next_read(socket, ws, data, deadline, timeout, pending) do
    case Reader.read(ws, data, pending) do
      {:ok, [], ws, pending} -> next(socket, ws, [], deadline, timeout, pending)
      {:ok, messages, ws, _pending} -> next(socket, ws, messages, deadline, timeout, 0)
      {:partial, messages, ws} -> next(socket, ws, messages ++ [:broken], deadline, timeout, 0)
      :broken -> {:error, :broken}
    end
  end

  defp challenge(socket, ws, queue, deadline, timeout) do
    case text(socket, ws, queue, deadline, timeout) do
      {:ok, %{"type" => "challenge", "nonce" => nonce}, ws, queue} when is_binary(nonce) ->
        case Base.decode64(nonce) do
          {:ok, <<_::binary-size(32)>> = bytes} -> {:ok, bytes, ws, queue}
          _ -> {:error, :broken}
        end

      {:ok, _other, _ws, _queue} ->
        {:error, :broken}

      {:error, _} = error ->
        error
    end
  end

  # The proof is the HMAC-SHA256 of the nonce with the SHA-256 of the token
  # as the key (wire-protocol.md, O1); the token stays in its closure.
  defp hello(nonce, token) do
    proof = :crypto.mac(:hmac, :sha256, :crypto.hash(:sha256, token.()), nonce)
    %{"type" => "hello", "protocol" => WebSocket.protocol(), "proof" => Base.encode64(proof)}
  end

  defp welcome(socket, ws, queue, deadline, timeout) do
    case text(socket, ws, queue, deadline, timeout) do
      {:ok, %{"type" => "welcome", "protocol" => protocol}, ws, queue} ->
        if protocol == WebSocket.protocol(), do: {:ok, ws, queue}, else: {:error, :broken}

      {:ok, %{"type" => "refused", "code" => "protocol", "server_protocol" => server}, _ws,
       _queue}
      when is_integer(server) and server >= 0 ->
        {:error, {:refused, server}}

      {:ok, _other, _ws, _queue} ->
        {:error, :broken}

      {:error, _} = error ->
        error
    end
  end

  defp send_frame(socket, ws, frame, timeout) do
    case Mint.WebSocket.encode(ws, {:text, JSON.encode!(frame)}) do
      {:ok, ws, bytes} ->
        case :gen_tcp.send(socket, bytes) do
          :ok -> {:ok, ws}
          {:error, reason} -> {:error, error_text(%Mint.TransportError{reason: reason}, timeout)}
        end

      {:error, _ws, _reason} ->
        {:error, :broken}
    end
  end

  # The deadline is checked before each read, so bytes that wait in the
  # socket do not keep the handshake past it.
  defp left(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)

  defp host(ip) when tuple_size(ip) == 4, do: ip |> :inet.ntoa() |> to_string()
  defp host(ip), do: "[" <> (ip |> :inet.ntoa() |> to_string()) <> "]"

  defp close_text(nil), do: "the server closed the connection"
  defp close_text(code), do: "the server closed the connection with #{code}"

  defp error_text(%Mint.TransportError{reason: :timeout}, timeout),
    do: "no welcome from the server in #{timeout} ms"

  defp error_text(%Mint.TransportError{reason: :closed}, _timeout),
    do: "the server closed the connection"

  defp error_text(%Mint.TransportError{reason: reason}, _timeout),
    do: to_string(:inet.format_error(reason))

  defp error_text(_error, _timeout),
    do: "the reply to the upgrade is not a WebSocket upgrade"
end
