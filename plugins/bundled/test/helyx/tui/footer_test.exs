defmodule Helyx.TUI.FooterTest do
  # The footer rows (#484): the location of row 1 from the disk, and the
  # text of both rows.
  use ExUnit.Case, async: true

  import Helyx.Test.TUIRender

  alias Helyx.TUI.Footer

  defp head(dir, text) do
    File.mkdir_p!(Path.join(dir, ".git"))
    File.write!(Path.join([dir, ".git", "HEAD"]), text)
  end

  # A directory outside every repository: the ExUnit tmp_dir is inside this one.
  defp outside do
    dir = Path.join(System.tmp_dir!(), "footer_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  # The branch that row 1 shows, or nil. The ExUnit tmp_dir is under the
  # home directory, so the path part shows with `~`.
  defp branch(dir) do
    case Regex.run(~r/ \(([^()]*)\)$/, Footer.location(dir)) do
      [_, name] -> name
      nil -> nil
    end
  end

  defp rows(location, vm, busy \\ nil, scroll \\ nil) do
    %{text: lines} = Footer.widget(location, vm, busy, scroll)
    line_texts(lines)
  end

  describe "location/1" do
    @describetag :tmp_dir

    test "the branch of the nearest .git, also from a subdirectory", %{tmp_dir: dir} do
      head(dir, "ref: refs/heads/feat/x\n")
      sub = Path.join(dir, "a/b")
      File.mkdir_p!(sub)

      assert {branch(dir), branch(sub)} == {"feat/x", "feat/x"}
    end

    test "a .git file points at the git directory, also by a relative path", %{tmp_dir: dir} do
      real = Path.join(dir, "real")
      head(real, "ref: refs/heads/wt\n")
      work = Path.join(dir, "work")
      File.mkdir_p!(work)

      File.write!(Path.join(work, ".git"), "gitdir: ../real/.git\n")
      assert branch(work) == "wt"

      File.write!(Path.join(work, ".git"), "gitdir: #{real}/.git\n")
      assert branch(work) == "wt"
    end

    test "no repository, a detached HEAD, or a .git file of another form shows no branch",
         %{tmp_dir: dir} do
      plain = outside()
      assert Footer.location(plain) == plain

      head(dir, "0123456789abcdef0123456789abcdef01234567\n")
      assert branch(dir) == nil

      File.write!(Path.join(plain, ".git"), "not a gitdir line")
      assert Footer.location(plain) == plain
    end

    test "a HEAD that is not a regular file is not read, so it cannot block" do
      dir = outside()
      File.mkdir_p!(Path.join(dir, ".git"))
      {_, 0} = System.cmd("mkfifo", [Path.join([dir, ".git", "HEAD"])])
      assert Footer.location(dir) == dir
    end

    # git allows a byte that is not UTF-8 in a branch; a path can hold a
    # control character.
    test "control characters and invalid bytes show as ?", %{tmp_dir: dir} do
      dir = Path.join(dir, "d\e[31m")
      head(dir, "ref: refs/heads/a\xFFb\n")
      assert String.ends_with?(Footer.location(dir), "/d?[31m (a?b)")
    end

    test "a HEAD read takes at most 4,096 bytes; a character cut there shows as ?",
         %{tmp_dir: dir} do
      room = 4096 - byte_size("ref: refs/heads/")

      for {name, shown} <- [
            {String.duplicate("b", room - 1), String.duplicate("b", room - 1)},
            {String.duplicate("b", room), String.duplicate("b", room)},
            {String.duplicate("b", room + 1), String.duplicate("b", room)},
            {String.duplicate("b", 100_000), String.duplicate("b", room)},
            # "é" is 2 bytes: its first byte is the last one read.
            {String.duplicate("b", room - 1) <> "é", String.duplicate("b", room - 1) <> "?"}
          ] do
        head(dir, "ref: refs/heads/" <> name)
        assert branch(dir) == shown
      end
    end

    # A reftable repository has a HEAD file that names `.invalid`.
    test "a name that git cannot make shows no branch", %{tmp_dir: dir} do
      for name <-
            ["", ".invalid", "x/.invalid", "a b", "x.lock", "a..b", "a\nb", "main) ~/x (y"] ++
              ["-x", "x/", "x.", "x.lock/y", "a@{b", "a//b", "a~b", "a\\b"] do
        head(dir, "ref: refs/heads/#{name}\n")
        assert branch(dir) == nil, inspect(name)
      end

      for name <- ["main", "feat/x", "release" <> <<0xA0::utf8>>, "v1.2", "a@b", "@", "a/-b"] do
        head(dir, "ref: refs/heads/#{name} \r\n")
        assert branch(dir) == name, inspect(name)
      end
    end

    test "a gitdir line keeps the spaces of its path, as git does", %{tmp_dir: dir} do
      head(Path.join(dir, "real"), "ref: refs/heads/wt\n")
      work = Path.join(dir, "work")
      File.mkdir_p!(work)
      File.write!(Path.join(work, ".git"), "gitdir:  #{dir}/real/.git\r\n")
      assert branch(work) == nil
    end

    test "a format character such as a bidi override shows as ?", %{tmp_dir: dir} do
      head(dir, "ref: refs/heads/a" <> <<0x202E::utf8>> <> "b\n")
      assert branch(dir) == "a?b"
    end

    test "the home directory shows as ~, and only as a whole path component" do
      home = System.user_home!()
      assert Footer.location(home) =~ ~r/^~( \(.*\))?$/
      assert Footer.location(Path.join(home, "no_such_dir_484")) =~ ~r"^~/no_such_dir_484"
      assert Footer.location(home <> "x484") =~ ~r/^#{Regex.escape(home)}x484/
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
