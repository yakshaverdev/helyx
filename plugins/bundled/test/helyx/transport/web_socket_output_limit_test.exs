defmodule Helyx.Transport.WebSocketOutputLimitTest do
  # A wire switch to a provider that cannot apply the session's
  # `:max_output_tokens` answers `failed`, and the model stays
  # (docs/features/output-limit.md, "Interface changes"). Nothing here
  # touches the network: the endpoint is never called.
  use ExUnit.Case, async: true

  alias Helyx.Session
  alias Helyx.Test.WireClient, as: Client
  alias Helyx.Transport.WebSocket
  alias Helyx.Transport.WebSocket.{Ops, Outbound}

  @moduletag :tmp_dir

  defmodule Limited do
    @moduledoc false
    use Helyx.Provider.OpenAI, id: "limited", base_url: "http://localhost:11434/v1"
  end

  test "a switch that the limit refuses answers failed, and the model stays", %{tmp_dir: dir} do
    core = :"core_#{System.unique_integer([:positive])}"
    start_supervised!({Helyx.Core, name: core, plugins: [Limited, Helyx.Provider.Fake]})
    transport = start_supervised!({WebSocket, core: core, port: 0})
    socket = Client.open(WebSocket.port(transport))

    {:ok, session} = Session.start(core, model: "limited/m", cwd: dir, max_output_tokens: 5)
    params = %{"session" => session.id, "model" => "fake/echo"}

    assert %{"ok" => false, "error" => %{"code" => "failed"}} =
             Client.request(socket, "1", "set_model", params)

    # The op maps the error; it does not crash on it.
    assert Ops.run(fn -> Session.set_model(session, "fake/echo") end) ==
             Outbound.error("failed")

    {:ok, snapshot, _ref} = Session.subscribe(session)
    assert snapshot.model == "limited/m"

    # A switch that the limit allows answers as before.
    params = %{"session" => session.id, "model" => "limited/n"}
    assert %{"ok" => true} = Client.request(socket, "2", "set_model", params)
  end
end
