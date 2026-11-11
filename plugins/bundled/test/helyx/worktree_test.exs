defmodule Helyx.WorktreeTest do
  # `Helyx.Worktree.create/4` (`docs/features/worktree-sessions.md`). Not
  # async: each test sets the application env `:worktree_root`, and the
  # helper holds its process groups with the fake hands.
  use ExUnit.Case, async: false

  @moduletag :tmp_dir

  alias Helyx.Worktree

  setup %{tmp_dir: dir} do
    Helyx.Test.Hands.fake()
    root = Path.join(dir, "worktrees")
    previous = Application.get_env(:helyx_plugins, :worktree_root)
    Application.put_env(:helyx_plugins, :worktree_root, root)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:helyx_plugins, :worktree_root, previous),
        else: Application.delete_env(:helyx_plugins, :worktree_root)
    end)

    %{root: root, repo: repo(Path.join(dir, "repo"))}
  end

  test "it makes the folder and the branch helyx/<branch> at HEAD", %{repo: repo, root: root} do
    assert {:ok, %{path: path, branch: "helyx/one", setup: nil, rel: "."}} =
             Worktree.create(repo, "one", nil)

    assert path == Path.join([root, repo_dir(repo), "one"])
    assert File.dir?(path)
    assert File.stat!(Path.dirname(path)).mode |> Bitwise.band(0o777) == 0o700
    assert git(path, ["rev-parse", "--abbrev-ref", "HEAD"]) == "helyx/one"
    assert git(repo, ["rev-parse", "refs/heads/helyx/one"]) == git(path, ["rev-parse", "HEAD"])
  end

  test "a folder in a subfolder maps to the same subfolder", %{repo: repo} do
    sub = Path.join(repo, "apps/web")
    File.mkdir_p!(sub)
    File.write!(Path.join(sub, "keep"), "")
    commit(repo, "sub")

    assert {:ok, %{path: path, rel: "apps/web"}} = Worktree.create(sub, "sub", nil)
    assert File.dir?(Path.join(path, "apps/web"))
  end

  test "a name of 64 bytes is accepted and one of 65 is refused", %{repo: repo} do
    name = String.duplicate("a", 64)

    assert {:ok, %{branch: "helyx/" <> ^name}} = Worktree.create(repo, name, nil)
    assert {:error, text} = Worktree.create(repo, name <> "a", nil)
    assert text =~ "the branch must be 1 to 64 bytes"
  end

  test "an uppercase name, a leading -, and .. are refused", %{repo: repo} do
    for name <- ["Upper", "-lead", "a..b", ""] do
      assert {:error, text} = Worktree.create(repo, name, nil)
      assert text =~ "the branch must be 1 to 64 bytes"
    end
  end

  test "an existing branch is refused and is not moved", %{repo: repo} do
    assert {:ok, %{path: path}} = Worktree.create(repo, "taken", nil)
    before = git(path, ["rev-parse", "HEAD"])

    File.write!(Path.join(repo, "new"), "")
    commit(repo, "two")

    assert {:error, text} = Worktree.create(repo, "taken", nil)
    assert text =~ "helyx/taken exists already"
    assert git(repo, ["rev-parse", "refs/heads/helyx/taken"]) == before
  end

  test "a base that does not resolve, is too long, or starts with - is refused", %{repo: repo} do
    assert {:error, text} = Worktree.create(repo, "missing-base", "no-such-ref")
    assert text =~ "no-such-ref does not resolve to a commit"

    at_limit = String.duplicate("a", 256)
    assert {:error, text} = Worktree.create(repo, "limit-base", at_limit)
    assert text =~ "does not resolve to a commit"

    over = String.duplicate("a", 257)
    assert {:error, text} = Worktree.create(repo, "long-base", over)
    assert text =~ "the base is over 256 bytes"

    assert {:error, text} = Worktree.create(repo, "option-base", "--all")
    assert text =~ "must not start with '-'"

    File.write!(Path.join(repo, "new"), "")
    commit(repo, "two")
    first = git(repo, ["rev-parse", "HEAD~1"])

    assert {:ok, %{path: path}} = Worktree.create(repo, "based", "HEAD~1")
    assert git(path, ["rev-parse", "HEAD"]) == first
  end

  test "a folder outside a git repository is refused" do
    plain = Path.join(System.tmp_dir!(), "helyx-worktree-#{System.unique_integer([:positive])}")
    File.mkdir_p!(plain)
    on_exit(fn -> File.rm_rf!(plain) end)

    assert {:error, "the folder is not in a git repository"} = Worktree.create(plain, "x", nil)
  end

  test "the cap of worktrees for one repository", %{repo: repo, root: root} do
    dir = Path.join(root, repo_dir(repo))
    File.mkdir_p!(dir)

    for n <- 1..(Worktree.max_worktrees() - 1) do
      git!(repo, [
        "worktree",
        "add",
        "--no-checkout",
        "-b",
        "helyx/fill-#{n}",
        Path.join(dir, "fill-#{n}")
      ])
    end

    assert {:ok, _} = Worktree.create(repo, "cap-last", nil)

    assert {:error, text} = Worktree.create(repo, "cap-over", nil)
    assert text =~ "git worktree remove"
  end

  test "a setup script runs with HELYX_SOURCE_REPO", %{repo: repo} do
    script(repo, """
    #!/bin/bash
    echo "$HELYX_SOURCE_REPO" > source.txt
    echo done
    """)

    commit(repo, "script")

    assert {:ok, %{path: path, setup: setup}} = Worktree.create(repo, "setup", nil)
    assert File.read!(Path.join(path, "source.txt")) == repo <> "\n"
    assert setup =~ "done"
  end

  test "a setup script that is not checked in does not run", %{repo: repo} do
    script(repo, "echo ran > ran.txt\n")

    assert {:ok, %{path: path, setup: nil}} = Worktree.create(repo, "untracked", nil)
    refute File.exists?(Path.join(path, "ran.txt"))
  end

  test "a failing setup script keeps the worktree and names it", %{repo: repo, root: root} do
    script(repo, "echo boom >&2\nexit 3\n")
    commit(repo, "script")
    path = Path.join([root, repo_dir(repo), "fails"])

    assert {:error, text} = Worktree.create(repo, "fails", nil)
    assert text =~ path
    assert text =~ "helyx/fails"
    assert text =~ "exit status 3"
    assert text =~ "boom"
    assert File.dir?(path)
    assert git(repo, ["rev-parse", "--verify", "refs/heads/helyx/fails"]) != ""
  end

  test "a setup script past the deadline is released", %{repo: repo, root: root} do
    script(repo, "sleep 30\n")
    commit(repo, "script")
    path = Path.join([root, repo_dir(repo), "late"])

    assert {:error, text} = Worktree.create(repo, "late", nil, setup_ms: 100)
    assert text =~ "did not finish in 0 s: the group was released"
    assert File.dir?(path)
  end

  test "the output tail is cut at the bound and stays valid UTF-8", %{repo: repo} do
    script(repo, """
    #!/bin/bash
    printf 'é%.0s' {1..3000}
    printf 'END'
    """)

    commit(repo, "script")

    assert {:ok, %{setup: setup}} = Worktree.create(repo, "output", nil)
    assert String.valid?(setup)
    assert byte_size(setup) <= Worktree.setup_output_bytes()
    assert String.ends_with?(setup, "END")
  end

  defp repo(dir) do
    File.mkdir_p!(dir)
    git!(dir, ["init"])
    git!(dir, ["commit", "--allow-empty", "-m", "one"])
    dir
  end

  defp script(repo, text) do
    File.mkdir_p!(Path.join(repo, ".helyx"))
    File.write!(Path.join(repo, ".helyx/worktree-setup"), text)
  end

  defp commit(repo, message) do
    git!(repo, ["add", "."])
    git!(repo, ["commit", "-m", message])
  end

  defp git!(dir, args) do
    {out, 0} =
      System.cmd("git", ["-c", "user.name=t", "-c", "user.email=t@t" | args],
        cd: dir,
        stderr_to_stdout: true
      )

    out
  end

  defp git(dir, args) do
    {out, _status} =
      System.cmd("git", args, cd: dir, stderr_to_stdout: true)

    String.trim(out)
  end

  defp repo_dir(repo) do
    hash = repo |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)
    Path.basename(repo) <> "-" <> binary_part(hash, 0, 8)
  end
end
