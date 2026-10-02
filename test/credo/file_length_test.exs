# The check is no part of the compiled project: Credo loads it from .credo.exs.
Code.require_file("../../credo/file_length.ex", __DIR__)

defmodule Helyx.Credo.FileLengthTest do
  use Credo.Test.Case

  alias Helyx.Credo.FileLength

  # In `mix precommit`, `mix credo` has started the services of Credo in
  # this VM before the tests.
  setup_all do
    case Credo.Application.start(:normal, []) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
  end

  # A module of exactly `lines` lines, with a final newline.
  defp issues(lines, path \\ "lib/sample.ex", allowed \\ %{}) do
    body = String.duplicate("  @a 1\n", lines - 2)

    "defmodule Sample do\n#{body}end\n"
    |> to_source_file(path)
    |> run_check(FileLength, allowed: allowed)
  end

  test "a file at the limit passes, one line more fails" do
    refute_issues(issues(400))
    assert_issue(issues(401))
  end

  test "a file outside lib/ is not checked" do
    refute_issues(issues(401, "test/sample.ex"))
  end

  test "a listed file passes at its count and fails one line more" do
    allowed = %{"lib/sample.ex" => {450, "reason"}}
    refute_issues(issues(450, "lib/sample.ex", allowed))
    assert_issue(issues(451, "lib/sample.ex", allowed))
  end

  test "a listed file at or under the limit fails, so that its entry goes away" do
    issues(400, "lib/sample.ex", %{"lib/sample.ex" => {450, "reason"}})
    |> assert_issue(fn issue -> assert issue.message =~ "Remove its entry" end)
  end
end
