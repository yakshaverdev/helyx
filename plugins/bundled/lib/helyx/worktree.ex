defmodule Helyx.Worktree do
  @moduledoc false
  # A new git worktree on its own branch for one session, and the setup
  # script that runs in it (`docs/features/worktree-sessions.md`). A helper
  # of `plugins/bundled` (ADR 0005): no interface and no registration entry.

  # Each worktree is a full checkout on disk and this feature has no
  # automatic cleanup, so the count for one repository is capped.
  @max_worktrees 32
  # git reads local refs only, so a slow disk is the worst case. A setup
  # script can install dependencies, which takes minutes.
  @git_ms 30_000
  @setup_ms 600_000
  # The tail of a git command's output and of the setup output that an
  # error result keeps, and the setup text that a success keeps.
  @output_bytes 4_096
  # A base that the model gives: a commit name, not an option.
  @max_base_bytes 256

  # A branch name without the `helyx/` prefix: at most 64 bytes, and the
  # first byte is a letter or a digit. `..` is refused with it, and
  # `git check-ref-format --branch` checks the rest, such as `.lock`.
  @name ~r/\A[a-z0-9][a-z0-9._\/-]{0,63}\z/

  @doc false
  def max_worktrees, do: @max_worktrees

  @doc false
  def git_ms, do: @git_ms

  @doc false
  def setup_ms, do: @setup_ms

  @doc false
  def setup_output_bytes, do: @output_bytes

  @doc """
  Creates the worktree at `<root>/<repo>-<hash>/<branch>`, on the new branch
  `helyx/<branch>` at `base` (`HEAD` when nil), and runs the setup script
  when the base commit has one. The result holds the worktree `path`, its
  `branch`, the `setup` output (`nil` when no script ran), and `rel`, the
  folder of `folder` inside the worktree. The caller owns the worktree: a
  failure after the add keeps it. See `docs/features/worktree-sessions.md`.

  The options `:setup_ms` and `:add_ms` replace the deadline of the setup
  and of the add, for tests only.
  """
  @spec create(Path.t(), String.t(), String.t() | nil, keyword()) ::
          {:ok, %{path: Path.t(), branch: String.t(), setup: String.t() | nil, rel: Path.t()}}
          | {:error, String.t()}
  def create(folder, branch, base, opts \\ []) do
    folder = Path.expand(folder)

    with :ok <- check_name(branch),
         {:ok, repo} <- repository(folder),
         :ok <- check_git_name(folder, branch),
         :ok <- check_new_branch(repo.top, branch),
         :ok <- check_base(base, repo.top),
         {:ok, path} <- path(repo, branch),
         :ok <- add(repo.top, path, branch, base, opts),
         {:ok, setup} <- setup(repo.top, path, branch, opts) do
      {:ok, %{path: path, branch: "helyx/" <> branch, setup: setup, rel: repo.rel}}
    end
  end

  defp check_name(branch) do
    if Regex.match?(@name, branch) and not String.contains?(branch, ".."),
      do: :ok,
      else:
        {:error,
         "the branch must be 1 to 64 bytes of lowercase letters, digits, " <>
           "'.', '_', '/', and '-', with no '..'"}
  end

  # A folder that the model gives: a path in a git work tree. The three
  # answers prove it: a plain folder, a bare repository, and a folder in
  # `.git` fail at least one of them.
  defp repository(folder) do
    case rev_parse(folder, ["--show-toplevel", "--git-common-dir", "--show-prefix"]) do
      {:ok, [top, _common, prefix]} ->
        {:ok, %{top: top, rel: rel(prefix)}}

      {:ok, _other} ->
        {:error, "the folder is not in a git repository"}

      {:exit, _out} ->
        {:error, "the folder is not in a git repository"}

      {:error, text} ->
        {:error, text}
    end
  end

  # `--show-prefix` is git's own answer for the folder, so a folder reached
  # through a symlink still maps inside the new worktree.
  defp rel(""), do: "."
  defp rel(prefix), do: String.trim_trailing(prefix, "/")

  defp rev_parse(folder, args) do
    case git(["-C", folder, "rev-parse" | args], folder, git_ms()) do
      {:ok, out, 0} ->
        {:ok, lines(out)}

      {:ok, out, _status} ->
        {:exit, out}

      {:timeout, out} ->
        {:error, "git rev-parse did not finish in time: the group was released: " <> tail(out)}

      {:error, text} ->
        {:error, text}
    end
  end

  # One line for each option that `rev-parse` answered, with the newline
  # that ends the last one dropped.
  defp lines(out), do: out |> String.split("\n") |> Enum.drop(-1)

  defp check_git_name(folder, branch) do
    case git(["check-ref-format", "--branch", branch], folder, git_ms()) do
      {:ok, _out, 0} -> :ok
      {:ok, _out, _status} -> {:error, "helyx/#{branch} is not a valid git branch name"}
      {:timeout, _out} -> {:error, "git did not check the branch name in time"}
      {:error, text} -> {:error, text}
    end
  end

  # A branch that exists is never reset: the worktree would move a branch
  # that another checkout holds.
  defp check_new_branch(top, branch) do
    case git(
           ["-C", top, "rev-parse", "--verify", "--quiet", "refs/heads/helyx/" <> branch],
           top,
           git_ms()
         ) do
      {:ok, _out, 0} -> {:error, "the branch helyx/#{branch} exists already"}
      {:ok, _out, _status} -> :ok
      {:timeout, _out} -> {:error, "git did not read the branches in time"}
      {:error, text} -> {:error, text}
    end
  end

  defp check_base(nil, _top), do: :ok

  defp check_base(base, top) do
    cond do
      base == "" ->
        {:error, "the base must be a commit name"}

      byte_size(base) > @max_base_bytes ->
        {:error, "the base is over #{@max_base_bytes} bytes"}

      String.starts_with?(base, "-") ->
        {:error, "the base must not start with '-'"}

      String.contains?(base, <<0>>) ->
        {:error, "the base must have no NUL byte"}

      true ->
        resolve_base(base, top)
    end
  end

  defp resolve_base(base, top) do
    case git(["-C", top, "rev-parse", "--verify", "--quiet", base <> "^{commit}"], top, git_ms()) do
      {:ok, _out, 0} -> :ok
      {:ok, _out, _status} -> {:error, "the base #{base} does not resolve to a commit"}
      {:timeout, _out} -> {:error, "git did not resolve the base #{base} in time"}
      {:error, text} -> {:error, text}
    end
  end

  defp path(repo, branch) do
    dir = Path.join(root(), repo_dir(repo.top))
    path = Path.join(dir, String.replace(branch, "/", "-"))

    cond do
      File.exists?(path) ->
        {:error, "the path #{path} exists already"}

      length(entries(dir)) >= max_worktrees() ->
        {:error,
         "this repository holds #{max_worktrees()} worktrees already; " <>
           "remove one with `git worktree remove`"}

      true ->
        case make_dirs(Path.dirname(path)) do
          :ok ->
            {:ok, path}

          {:error, reason} ->
            {:error, "the worktree folder was not made: #{:file.format_error(reason)}"}
        end
    end
  end

  # Parents that do not exist yet are made with mode 0700, the one of the
  # worktree root; an existing parent keeps its mode.
  defp make_dirs(path) do
    if File.dir?(path), do: :ok, else: mkdir(path)
  end

  defp mkdir(path) do
    with :ok <- make_dirs(Path.dirname(path)) do
      case File.mkdir(path) do
        :ok -> File.chmod(path, 0o700)
        {:error, :eexist} -> made(path)
        {:error, reason} -> {:error, reason}
      end
    end
  end

  # Two calls can make one folder: `:eexist` is safe only for a folder.
  defp made(path) do
    if File.dir?(path), do: :ok, else: {:error, :eexist}
  end

  defp entries(dir) do
    case File.ls(dir) do
      {:ok, names} -> names
      {:error, :enoent} -> []
    end
  end

  # The root, then one folder for each repository: a short name and a hash
  # of the top-level path, so two checkouts of one name do not mix.
  defp root do
    Application.get_env(:helyx_plugins, :worktree_root) ||
      Path.join(System.user_home!(), ".helyx/worktrees")
  end

  defp repo_dir(top) do
    hash = :sha256 |> :crypto.hash(top) |> Base.encode16(case: :lower) |> binary_part(0, 8)
    Path.basename(top) <> "-" <> hash
  end

  defp add(top, path, branch, base, opts) do
    name = "helyx/" <> branch
    limit = Keyword.get(opts, :add_ms, git_ms())

    case git(["-C", top, "worktree", "add", "-b", name, path, base || "HEAD"], top, limit) do
      {:ok, _out, 0} ->
        :ok

      {:ok, out, status} ->
        {:error, "git worktree add failed with the exit status #{status}: " <> tail(out)}

      {:timeout, out} ->
        {:error,
         "git worktree add did not finish in time: the group was released; " <>
           partial(top, path, branch) <> ": " <> tail(out)}

      {:error, text} ->
        {:error, "git worktree add did not start: " <> text}
    end
  end

  # A released add can leave a part of the checkout and its branch. Nothing
  # ran in it, so it is no evidence: it is removed, and a retry with the same
  # name works. The double force removes a worktree that the add left locked.
  # git refuses to delete a branch that another worktree has checked out.
  defp partial(top, path, branch) do
    name = "helyx/" <> branch
    _ = git(["-C", top, "worktree", "remove", "--force", "--force", path], top, git_ms())
    _ = File.rm_rf(path)
    _ = git(["-C", top, "worktree", "prune"], top, git_ms())
    _ = git(["-C", top, "branch", "-D", name], top, git_ms())

    if not File.exists?(path) and check_new_branch(top, branch) == :ok,
      do: "its partial worktree was removed",
      else: "a part of the worktree #{path} or of the branch #{name} can remain"
  end

  # The script that runs is the one checked in at the base commit, in the new
  # worktree; an untracked file of the source checkout never runs.
  defp setup(top, path, branch, opts) do
    script = Path.join([path, ".helyx", "worktree-setup"])

    case File.stat(script) do
      {:ok, %File.Stat{type: :regular}} -> run_setup(top, path, branch, script, opts)
      _other -> {:ok, nil}
    end
  end

  defp run_setup(top, path, branch, script, opts) do
    limit = Keyword.get(opts, :setup_ms, setup_ms())
    bash = System.find_executable("bash") || "/bin/bash"

    case run([bash, script], path, limit, env: [{"HELYX_SOURCE_REPO", top}]) do
      {:ok, out, 0} ->
        {:ok, tail(out)}

      {:ok, out, status} ->
        {:error,
         "the setup script of the worktree #{path} on the branch helyx/#{branch} " <>
           "failed with the exit status #{status}: #{tail(out)}"}

      {:timeout, out} ->
        {:error,
         "the setup script of the worktree #{path} on the branch helyx/#{branch} " <>
           "did not finish in #{div(limit, 1000)} s: the group was released: #{tail(out)}"}

      {:error, text} ->
        {:error,
         "the setup script of the worktree #{path} on the branch helyx/#{branch} " <>
           "did not start: " <> text}
    end
  end

  # A git process, and the setup script, run under the watchdog with their
  # group held by the hands, so an abort of the call releases them. `limit`
  # is in ms, counted from before the start.
  defp git(args, cwd, limit) do
    case System.find_executable("git") do
      nil -> {:error, "git is not on PATH: a worktree needs git"}
      exe -> run([exe | args], cwd, limit, [])
    end
  end

  defp run(argv, cwd, limit, opts) do
    deadline = System.monotonic_time(:millisecond) + limit

    case Helyx.Watchdog.start(argv, cwd, nil, [deadline: deadline] ++ opts) do
      {:error, reason} ->
        {:error, reason}

      {:started, port, pre, handles} ->
        case read(port, pre, deadline) do
          {:exit, out, status} -> {:ok, out, status}
          {:timeout, out} -> {:timeout, stop(port, handles, out)}
        end
    end
  end

  # Reads until the exit status, or the monotonic deadline. The deadline is
  # checked before each receive: a message in the mailbox wins over `after`.
  defp read(port, out, deadline) do
    case deadline - System.monotonic_time(:millisecond) do
      left when left <= 0 ->
        {:timeout, out}

      left ->
        receive do
          {^port, {:data, data}} -> read(port, add(out, data), deadline)
          {^port, {:exit_status, status}} -> {:exit, out, status}
        after
          left -> {:timeout, out}
        end
    end
  end

  # The release of a deadline, as the bash tool's: TERM, a grace, KILL, with
  # a read beside it so that output still goes through the tail. The hands
  # hold the same handles, and release them again at delivery.
  defp stop(port, handles, out) do
    deadline = System.monotonic_time(:millisecond) + Helyx.Watchdog.Group.max_cancel_ms()
    release = Task.async(fn -> Helyx.Watchdog.Group.release(handles, :cancel, deadline) end)

    out =
      case read(port, out, deadline) do
        {:exit, out, _status} ->
          out

        {:timeout, out} ->
          Helyx.Watchdog.close(port)
          out
      end

    left = max(deadline - System.monotonic_time(:millisecond), 0)
    _held = Task.yield(release, left) || Task.shutdown(release, :brutal_kill)
    out
  end

  # The copy stays at twice the bound, and the cut runs once at the end, so
  # a chunk of output costs no cut and a multibyte character is cut once.
  defp add(out, data) when byte_size(out) + byte_size(data) <= 2 * @output_bytes,
    do: out <> data

  defp add(out, data) do
    all = out <> data
    binary_part(all, byte_size(all) - 2 * @output_bytes, 2 * @output_bytes)
  end

  defp tail(out), do: Helyx.Text.cap(out, setup_output_bytes(), :tail)
end
