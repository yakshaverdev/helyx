defmodule Helyx.Transport.WireBoundsTest do
  # `test/fixtures/wire/bounds.json` holds the bounds and the error codes of
  # the wire once. The server, the client of the TUI, the schema of the wire
  # doc and the Rust client (`clients/rust/core/tests/bounds.rs`) agree with it.
  use ExUnit.Case, async: true

  alias Helyx.Transport.WebSocket
  alias Helyx.Transport.WebSocket.{Frame, Ops}
  alias Helyx.TUI.Wire.Decode

  @root Path.expand("../../../../..", __DIR__)
  @bounds JSON.decode!(File.read!(Path.join(@root, "test/fixtures/wire/bounds.json")))

  test "the server has the bounds of the file" do
    assert WebSocket.protocol() == @bounds["protocol"]
    assert Frame.max_frame() == @bounds["frame_bytes"]
    assert Frame.max_piece() == @bounds["part_bytes"]
    assert Frame.max_request() == @bounds["request_bytes"]

    for {op, ms} <- @bounds["deadlines_ms"] do
      assert Ops.deadline(if(op == "default", do: "prompt", else: op)) == ms
    end
  end

  test "the schema of the wire doc names the error codes of the file" do
    doc = File.read!(Path.join(@root, "docs/features/wire-protocol.md"))
    [_, rest] = String.split(doc, "\nerror_code = ", parts: 2)
    [rule, _] = String.split(rest, "\n\n", parts: 2)
    codes = Regex.scan(~r/"([a-z0-9_]+)"/, rule, capture: :all_but_first) |> List.flatten()
    assert codes == @bounds["error_codes"]
  end

  test "the client of the TUI reads every error code" do
    for code <- @bounds["error_codes"] do
      error = %{"ok" => false, "error" => %{"code" => code, "text" => "text"}}
      assert {:ok, {:error, _code}} = Decode.result("prompt", error)
    end
  end
end
