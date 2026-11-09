defmodule Helyx.Transport.WebSocketAuthorityTest do
  use ExUnit.Case, async: true

  alias Helyx.Provider.Fake
  alias Helyx.Test.WireClient, as: Client
  alias Helyx.Transport.WebSocket

  # An authority that reports each call to the test and answers with the
  # function of its callback in the arg; with none, it passes.
  defmodule Recorder do
    @behaviour Helyx.Transport.WebSocket.Authority

    @impl true
    def hello({test, answers}, hello), do: answer(test, answers, :hello, [hello], {:ok, :user})

    @impl true
    def check({test, answers}, auth, op, params),
      do: answer(test, answers, :check, [auth, op, params], {:ok, params})

    @impl true
    def run({test, answers}, auth, op, params),
      do: answer(test, answers, :run, [auth, op, params], {:ok, %{"ran" => op}})

    @impl true
    def result({test, answers}, auth, op, params, result),
      do: answer(test, answers, :result, [auth, op, params, result], {:ok, result})

    @impl true
    def release({test, answers}, auth, op, params),
      do: answer(test, answers, :release, [auth, op, params], :ok)

    defp answer(test, answers, callback, args, default) do
      send(test, {callback, args})

      case answers do
        %{^callback => fun} -> apply(fun, args)
        _ -> default
      end
    end
  end

  defmodule NotAnAuthority do
  end

  defp serve(answers \\ %{}) do
    core = :"core_#{System.unique_integer([:positive])}"
    start_supervised!({Helyx.Core, name: core, plugins: [Fake]}, id: :core)

    transport =
      start_supervised!(
        {WebSocket, core: core, port: 0, authority: {Recorder, {self(), answers}}}
      )

    WebSocket.port(transport)
  end

  defp serve_again(answers) do
    stop_supervised!(WebSocket)
    stop_supervised!(:core)
    serve(answers)
  end

  defp open(port) do
    {:ok, socket} = Client.upgrade(port)
    nonce = Client.challenge(socket)
    Client.send_frame(socket, Client.hello(nonce, nil))
    {:frame, %{"type" => "welcome"}} = Client.recv(socket)
    socket
  end

  # A session id with no session and no file.
  @missing "AAAAAAAAAAAA"

  describe "the options" do
    test "an authority with a token, or a module that is not an authority, is refused" do
      authority = {Recorder, {self(), %{}}}

      assert WebSocket.start_link(core: :c, port: 0, authority: authority, token: "t") ==
               {:error, :invalid_options}

      for bad <- [{NotAnAuthority, nil}, {"Recorder", nil}, Recorder] do
        assert WebSocket.start_link(core: :c, port: 0, authority: bad) ==
                 {:error, :invalid_options}
      end

      assert WebSocket.start_link(core: :c, port: 0, ip: {0, 0, 0, 0}) ==
               {:error, :token_required}
    end
  end

  describe "the hello" do
    test "the authority gets the nonce, the token, the proof, and the connection" do
      port = serve()
      {:ok, socket} = Client.upgrade(port)
      nonce = Client.challenge(socket)
      hello = Client.hello(nonce, "secret") |> Map.put("token", "tokenid12345")
      Client.send_frame(socket, hello)
      assert {:frame, %{"type" => "welcome"}} = Client.recv(socket)

      assert_receive {:hello, [fields]}
      assert fields.nonce == Base.decode64!(nonce)
      assert fields.token == "tokenid12345"
      assert fields.proof == hello["proof"]
      assert is_pid(fields.connection)

      # The credential goes to every later callback.
      Client.request(socket, "1", "sessions.live", %{})
      assert_receive {:check, [:user, "sessions.live", %{}]}
    end

    test ":error closes with 4401; busy and an exit close with 4503" do
      for {answer, code} <- [
            {fn _ -> :error end, 4401},
            {fn _ -> {:error, :busy} end, 4503},
            {fn _ -> exit(:timeout) end, 4503}
          ] do
        port = serve(%{hello: answer})
        {:ok, socket} = Client.upgrade(port)
        Client.send_frame(socket, Client.hello(Client.challenge(socket), nil))
        assert {:close, ^code} = Client.recv(socket)
        stop_supervised!(WebSocket)
        stop_supervised!(:core)
      end
    end

    test "a token that is not an id closes with 4401 before the authority" do
      port = serve()

      for token <- [String.duplicate("t", 65), "", 7] do
        {:ok, socket} = Client.upgrade(port)
        hello = Client.hello(Client.challenge(socket), nil) |> Map.put("token", token)
        Client.send_frame(socket, hello)
        assert {:close, 4401} = Client.recv(socket)
      end

      {:ok, socket} = Client.upgrade(port)

      Client.send_frame(
        socket,
        Client.hello(Client.challenge(socket), nil) |> Map.put("token", String.duplicate("t", 64))
      )

      assert {:frame, %{"type" => "welcome"}} = Client.recv(socket)
      assert_receive {:hello, [%{token: token}]}
      assert byte_size(token) == 64
      refute_received {:hello, _}
    end
  end

  describe "check" do
    test "a refusal reads as the answer of a missing session, code and text" do
      missing_answers =
        for op <- ~w(prompt history abort subscribe) do
          port = serve()
          socket = open(port)
          answer = Client.request(socket, "1", op, params(op, @missing))
          stop_supervised!(WebSocket)
          stop_supervised!(:core)
          {op, answer["error"]}
        end

      port = serve(%{check: fn _, _, _ -> {:error, "session_not_found"} end})
      socket = open(port)

      for {op, missing} <- missing_answers do
        assert %{"code" => "session_not_found"} = missing
        assert Client.request(socket, op, op, params(op, "BBBBBBBBBBBB"))["error"] == missing
      end
    end

    test "{:close, 4403} closes the connection in place of the reply" do
      port = serve(%{check: fn _, _, _ -> {:close, 4403} end})

      for op <- ~w(sessions.live subscribe) do
        socket = open(port)
        Client.send_request(socket, "1", op, params(op, @missing))
        assert {:close, 4403} = Client.until_close(socket)
      end
    end

    test "an exit of check answers timeout; bad params never reach it" do
      port = serve(%{check: fn _, _, _ -> exit(:timeout) end})
      socket = open(port)

      assert %{"error" => %{"code" => "timeout"}} =
               Client.request(socket, "1", "sessions.live", %{})

      assert %{"error" => %{"code" => "bad_params"}} = Client.request(socket, "2", "abort", %{})
      assert_receive {:check, [_, "sessions.live", _]}
      refute_received {:check, [_, "abort", _]}
    end

    test "check can give other params of the operation" do
      port = serve(%{check: fn _, "resume", _ -> {:ok, %{"id" => @missing}} end})
      socket = open(port)

      assert %{"error" => %{"code" => "not_found"}} =
               Client.request(socket, "1", "resume", %{"cwd" => File.cwd!()})

      # The Core call failed: the reserved place goes back.
      assert_receive {:release, [:user, "resume", %{"id" => @missing}]}
      refute_received {:result, _}
    end
  end

  describe "the hello, more" do
    test "a client of another protocol gets 4426 before the authority; no proof is nil" do
      port = serve()
      {:ok, socket} = Client.upgrade(port)
      hello = Client.hello(Client.challenge(socket), nil)
      Client.send_frame(socket, %{hello | "protocol" => 1})
      assert {:frame, %{"type" => "refused"}} = Client.recv(socket)

      socket = open(port)
      assert_receive {:hello, [%{proof: nil, token: nil}]}
      refute_received {:hello, _}
      Client.request(socket, "1", "sessions.live", %{})
    end
  end

  describe "subscribe" do
    test "the subscription uses the params that check gave" do
      port =
        serve(%{
          check: fn
            _, "subscribe", _ -> {:ok, %{"session" => @missing}}
            _, _op, params -> {:ok, params}
          end
        })

      socket = open(port)
      start = %{"cwd" => File.cwd!(), "model" => "fake/echo"}
      %{"result" => %{"session" => id}} = Client.request(socket, "1", "start", start)

      assert %{"error" => %{"code" => "session_not_found"}} =
               Client.request(socket, "2", "subscribe", %{"session" => id})
    end
  end

  describe "run, result" do
    test "an exit of run answers timeout; {:close, 4403} from run or result closes" do
      port =
        serve(%{
          run: fn _, _, _ -> exit(:timeout) end,
          result: fn _, _, _, _ -> {:close, 4403} end
        })

      socket = open(port)
      assert %{"error" => %{"code" => "timeout"}} = Client.request(socket, "1", "hub.me", %{})
      Client.send_request(socket, "2", "sessions.live", %{})
      assert {:close, 4403} = Client.until_close(socket)

      port = serve_again(%{run: fn _, _, _ -> {:close, 4403} end})
      socket = open(port)
      Client.send_request(socket, "1", "hub.me", %{})
      assert {:close, 4403} = Client.until_close(socket)
    end

    @tag :slow
    test "the deadline of the op ends with its Core call; result has its own bound" do
      # The deadline of sessions.live is 6,000 ms; result takes longer.
      port = serve(%{result: fn _, _, _, result -> Process.sleep(6_500) && {:ok, result} end})
      socket = open(port)

      assert %{"ok" => true, "result" => %{"sessions" => _}} =
               Client.request(socket, "1", "sessions.live", %{})
    end

    test "hub.* and sessions.saved go to run; with no authority hub.* is unknown_op" do
      port =
        serve(%{
          run: fn
            _, "hub.records.get", _ -> {:error, "session_not_found", "session not found"}
            _, op, _ -> {:ok, %{"ran" => op}}
          end
        })

      socket = open(port)
      assert %{"result" => %{"ran" => "hub.me"}} = Client.request(socket, "1", "hub.me", %{})

      assert %{"result" => %{"ran" => "sessions.saved"}} =
               Client.request(socket, "2", "sessions.saved", %{"limit" => 5})

      assert %{"error" => %{"code" => "session_not_found"}} =
               Client.request(socket, "3", "hub.records.get", %{"session" => @missing})

      # A check of an op would come from its worker before its run.
      for op <- ~w(hub.me sessions.saved hub.records.get),
          do: assert_receive({:run, [:user, ^op, _]})

      refute_received {:check, _}

      core = :"core_#{System.unique_integer([:positive])}"
      start_supervised!({Helyx.Core, name: core, plugins: [Fake]}, id: :plain_core)
      plain = start_supervised!({WebSocket, core: core, port: 0}, id: :plain)
      socket = Client.open(WebSocket.port(plain))

      assert %{"error" => %{"code" => "unknown_op"}} =
               Client.request(socket, "1", "hub.me", %{})
    end

    test "result filters sessions.live and sees a start" do
      port =
        serve(%{
          result: fn
            _, "sessions.live", _, _ -> {:ok, %{"sessions" => []}}
            _, _op, _params, result -> {:ok, result}
          end
        })

      socket = open(port)
      start = %{"cwd" => File.cwd!(), "model" => "fake/echo"}
      assert %{"result" => %{"session" => id}} = Client.request(socket, "1", "start", start)
      assert_receive {:result, [:user, "start", ^start, %{"session" => ^id}]}

      assert %{"result" => %{"sessions" => []}} =
               Client.request(socket, "2", "sessions.live", %{})
    end
  end

  test "close/2 closes a connection with 4403" do
    port = serve()
    socket = open(port)
    assert_receive {:hello, [%{connection: connection}]}
    assert WebSocket.close(connection, 4403) == :ok
    assert {:close, 4403} = Client.until_close(socket)
  end

  defp params("prompt", id), do: %{"session" => id, "text" => "hi"}
  defp params("history", id), do: %{"session" => id, "instance_id" => "x", "before" => "y"}
  defp params("sessions.live", _id), do: %{}
  defp params(_op, id), do: %{"session" => id}
end
