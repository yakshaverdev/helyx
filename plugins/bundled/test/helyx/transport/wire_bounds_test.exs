defmodule Helyx.Transport.WireBoundsTest do
  # `test/fixtures/wire/bounds.json` holds the bounds and the error codes of
  # the wire once, and the code reads it (`Helyx.Transport.WebSocket.Bounds`).
  # The schema of the wire doc is the other place that names the codes.
  use ExUnit.Case, async: true

  alias Helyx.Transport.WebSocket
  alias Helyx.Transport.WebSocket.Bounds

  @doc_path Path.expand("../../../../../docs/features/wire-protocol.md", __DIR__)
  @file_path Path.expand("../../../../../test/fixtures/wire/bounds.json", __DIR__)

  test "the file names the protocol of the server" do
    assert JSON.decode!(File.read!(@file_path))["protocol"] == WebSocket.protocol()
  end

  test "the schema of the wire doc names the error codes of the file" do
    [_, rest] = String.split(File.read!(@doc_path), "\nerror_code = ", parts: 2)
    [rule, _] = String.split(rest, "\n\n", parts: 2)
    codes = Regex.scan(~r/"([a-z0-9_]+)"/, rule, capture: :all_but_first) |> List.flatten()
    assert codes == Enum.map(Bounds.error_codes(), &Atom.to_string/1)
  end
end
