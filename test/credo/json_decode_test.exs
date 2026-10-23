# The check is no part of the compiled project: Credo loads it from .credo.exs.
Code.require_file("../../credo/json_decode.ex", __DIR__)

defmodule Helyx.Credo.JSONDecodeTest do
  use Credo.Test.Case

  alias Helyx.Credo.JSONDecode

  defp issues(body, path \\ "lib/sample.ex") do
    "defmodule Sample do\n  def f(text) do\n    #{body}\n  end\nend\n"
    |> to_source_file(path)
    |> run_check(JSONDecode)
  end

  test "a call of JSON.decode or JSON.decode! in lib/ code is reported" do
    for body <- [
          "JSON.decode(text)",
          "JSON.decode!(text)",
          "JSON.decode(text, nil, [])",
          "text |> JSON.decode()",
          "&JSON.decode/1"
        ] do
      assert_issue(issues(body))
    end
  end

  test "the lib/ code of the plugins, the clients, and the apps is checked" do
    for path <- [
          "plugins/bundled/lib/helyx/sample.ex",
          "plugins/bundled/clients/tui/lib/sample.ex",
          "apps/coding_agent/lib/sample.ex"
        ] do
      assert_issue(issues("JSON.decode(text)", path))
    end
  end

  test "Helyx.JSON and a test file are not reported" do
    "defmodule Helyx.JSON do\n  def decode(text), do: JSON.decode(text)\nend\n"
    |> to_source_file("lib/helyx/json.ex")
    |> run_check(JSONDecode)
    |> refute_issues()

    refute_issues(issues("JSON.decode(text)", "test/sample_test.exs"))
    refute_issues(issues("JSON.decode(text)", "plugins/bundled/test/support/sample.ex"))
  end

  test "Helyx.JSON.decode/1 and an encode are not reported" do
    refute_issues(issues("Helyx.JSON.decode(text)"))
    refute_issues(issues("JSON.encode!(text)"))
  end
end
