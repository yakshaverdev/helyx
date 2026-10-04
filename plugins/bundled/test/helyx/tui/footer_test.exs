defmodule Helyx.TUI.FooterTest do
  # The footer rows (#484): row 1 from `location/2` and the branch from
  # git, and the text of both rows.
  use ExUnit.Case, async: true

  import Helyx.Test.TUIRender

  alias Helyx.TUI.Footer

  # A directory outside every repository: the ExUnit tmp_dir is inside this one.
  defp outside do
    dir = Path.join(System.tmp_dir!(), "footer_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  # A fake git: a shell script with `body`, in `dir`.
  defp fake_git(dir, body) do
    path = Path.join(dir, "git")
    File.write!(path, "#!/bin/sh\n" <> body)
    File.chmod!(path, 0o755)
    path
  end

  # Margins for a loaded machine: the OS reaps a killed process soon, not
  # at once (a zombie still answers `kill -0`), and a script starts late.
  @load_polls 40
  @load_git_ms 900

  defp gone?(_os_pid, 0), do: false

  defp gone?(os_pid, tries) do
    case System.cmd("kill", ["-0", os_pid], stderr_to_stdout: true) do
      {_, 0} ->
        Process.sleep(50)
        gone?(os_pid, tries - 1)

      {_, _gone} ->
        true
    end
  end

  defp wait_for_file(_path, 0), do: false

  defp wait_for_file(path, tries) do
    with false <- File.exists?(path) do
      Process.sleep(50)
      wait_for_file(path, tries - 1)
    end
  end

  defp git!(args), do: {_, 0} = System.cmd("git", args, stderr_to_stdout: true)

  defp rows(location, vm, busy \\ nil, scroll \\ nil) do
    %{text: lines} = Footer.widget(location, vm, busy, scroll)
    line_texts(lines)
  end

  describe "branch/1" do
    @describetag :tmp_dir

    test "the current branch of a repository, also from a subdirectory" do
      repo = outside()
      git!(["init", "-q", "-b", "one", repo])
      File.mkdir_p!(Path.join(repo, "sub"))
      assert Footer.branch(repo) == "one"
      assert Footer.branch(Path.join(repo, "sub")) == "one"

      git!(["-C", repo, "symbolic-ref", "HEAD", "refs/heads/feat/two"])
      assert Footer.branch(repo) == "feat/two"
    end

    test "no repository, a missing directory, or no git gives nil" do
      dir = outside()
      assert Footer.branch(dir) == nil
      assert Footer.branch(Path.join(dir, "missing")) == nil
      assert Footer.branch(dir, nil, 2000) == nil
    end

    test "a non-zero exit or no output gives nil", %{tmp_dir: dir} do
      assert Footer.branch(dir, fake_git(dir, "echo main; exit 1\n"), 2000) == nil
      assert Footer.branch(dir, fake_git(dir, "exit 0\n"), 2000) == nil
    end

    test "a git that does not end in time is killed and gives nil", %{tmp_dir: dir} do
      pid_file = Path.join(dir, "pid")
      git = fake_git(dir, "echo $$ > #{pid_file}\nexec sleep 30\n")
      assert Footer.branch(dir, git, @load_git_ms) == nil
      assert gone?(File.read!(pid_file) |> String.trim(), @load_polls)
    end

    test "a git whose caller dies is killed", %{tmp_dir: dir} do
      pid_file = Path.join(dir, "pid")
      git = fake_git(dir, "echo $$ > #{pid_file}\nexec sleep 30\n")
      caller = spawn(fn -> Footer.branch(dir, git, 30_000) end)
      assert wait_for_file(pid_file, @load_polls)
      Process.exit(caller, :kill)
      assert gone?(File.read!(pid_file) |> String.trim(), @load_polls)
    end

    test "the output is cut at 256 bytes", %{tmp_dir: dir} do
      git = fake_git(dir, "printf '%0300d\\n' 0\n")
      assert Footer.branch(dir, git, 2000) == String.duplicate("0", 256)

      for n <- [255, 256] do
        git = fake_git(dir, "printf '%0#{n}d\\n' 0\n")
        assert Footer.branch(dir, git, 2000) == String.duplicate("0", n)
      end

      # "é" is 2 bytes: its first byte is the last one kept.
      git = fake_git(dir, "printf '%0255d\\303\\251\\n' 0\n")
      cut = Footer.branch(dir, git, 2000)
      assert byte_size(cut) == 256
      assert Footer.location("/x", cut) == "/x (#{String.duplicate("0", 255)}?)"
    end
  end

  describe "location/2" do
    test "the branch follows the directory; control characters and invalid bytes show as ?" do
      assert Footer.location("/x", "main") == "/x (main)"
      assert Footer.location("/x", nil) == "/x"
      assert Footer.location("/d\e[31m", "a\xFFb" <> <<0x202E::utf8>>) == "/d?[31m (a?b?)"
    end

    test "the home directory shows as ~, and only as a whole path component" do
      home = System.user_home!()
      assert Footer.location(home, nil) == "~"
      assert Footer.location(Path.join(home, "no_such_dir_484"), "b") == "~/no_such_dir_484 (b)"
      assert Footer.location(home <> "x484", nil) == home <> "x484"
    end
  end

  describe "widget/4" do
    test "row 2 is the model and the state, with the queue counts only when not zero" do
      vm = view_model([], "fake/m")
      assert rows("~/p (main)", vm) == ["~/p (main)", "fake/m · idle"]

      queued = %{vm | queue: %{steers: 1, follow_ups: 2}}

      assert rows("~/p", queued, %{elapsed: 3_050}, {0, 0}) ==
               ["~/p", "fake/m · ⠋ 3s · queued 1+2 · scrolled"]
    end

    test "a reason comes first on row 2, in red" do
      vm = Helyx.TUI.ViewModel.reject(view_model([], "fake/m"), "not sent: the queue is full")
      %{text: [_row1, %{spans: [reason | _]}]} = Footer.widget("~", vm, nil, nil)
      assert {reason.content, reason.style.fg} == {"✕ not sent: the queue is full ", :red}
      assert rows("~", vm) == ["~", "✕ not sent: the queue is full fake/m · idle"]
    end
  end
end
