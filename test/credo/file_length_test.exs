# The check is no part of the compiled project: Credo loads it from .credo.exs.
Code.require_file("../../credo/file_length.ex", __DIR__)

defmodule Helyx.Credo.FileLengthTest do
  use Credo.Test.Case

  alias Helyx.Credo.FileLength

  # A module with `code` lines of code, with a final newline.
  defp issues(code, path \\ "lib/sample.ex", allowed \\ %{}) do
    body = String.duplicate("  @a 1\n", code - 2)

    "defmodule Sample do\n#{body}end\n"
    |> to_source_file(path)
    |> run_check(FileLength, allowed: allowed)
  end

  # A module with `code` lines of code and `docs` body lines of a heredoc
  # `@moduledoc`, with a final newline.
  defp mixed(code, docs) do
    doc = "  @moduledoc \"\"\"\n#{String.duplicate("  doc text\n", docs)}  \"\"\"\n"
    body = String.duplicate("  @a 1\n", code - 2)

    "defmodule Sample do\n#{doc}#{body}end\n"
  end

  test "a file at the limit passes, one line more fails" do
    refute_issues(issues(400))
    assert_issue(issues(401))
  end

  test "a blank line does not count" do
    source = "defmodule Sample do\n#{String.duplicate("  @a 1\n", 398)}end\n\n"

    refute_issues(
      source
      |> to_source_file("lib/sample.ex")
      |> run_check(FileLength, allowed: %{})
    )
  end

  test "a comment line does not count" do
    source = "defmodule Sample do\n#{String.duplicate("  @a 1\n", 398)}  # comment\nend\n"

    refute_issues(
      source
      |> to_source_file("lib/sample.ex")
      |> run_check(FileLength, allowed: %{})
    )
  end

  test "a single-line @doc does not count" do
    source = "defmodule Sample do\n  @doc \"text\"\n#{String.duplicate("  @a 1\n", 398)}end\n"

    refute_issues(
      source
      |> to_source_file("lib/sample.ex")
      |> run_check(FileLength, allowed: %{})
    )
  end

  test "an interpolated @moduledoc does not count" do
    docs =
      "  @moduledoc \"\"\"\n" <>
        String.duplicate("  doc text\n", 147) <> "  \#{1 + 1}\n  \"\"\"\n"

    source = "defmodule Sample do\n#{docs}#{String.duplicate("  @a 1\n", 348)}end\n"
    assert length(String.split(source, "\n")) - 1 == 500

    refute_issues(
      source
      |> to_source_file("lib/sample.ex")
      |> run_check(FileLength, allowed: %{})
    )
  end

  test "500 lines with 150 lines of @moduledoc pass" do
    source = mixed(350, 148)
    assert length(String.split(source, "\n")) - 1 == 500

    refute_issues(
      source
      |> to_source_file("lib/sample.ex")
      |> run_check(FileLength, allowed: %{})
    )
  end

  test "401 lines of code fail" do
    assert_issue(
      mixed(401, 148)
      |> to_source_file("lib/sample.ex")
      |> run_check(FileLength, allowed: %{})
    )
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

  test "a listed file under its count fails, so that its count goes down" do
    issues(449, "lib/sample.ex", %{"lib/sample.ex" => {450, "reason"}})
    |> assert_issue(fn issue -> assert issue.message =~ "Lower its entry to 449" end)
  end
end
