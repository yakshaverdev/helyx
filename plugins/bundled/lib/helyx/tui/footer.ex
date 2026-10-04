# ex_ratatui is an optional dependency (ADR 0005): without it
# Helyx.TUI.Footer does not exist.
defmodule Helyx.TUI.Footer.Available do
  @moduledoc false
  use Helyx.TUI.Guard
end

if Helyx.TUI.Footer.Available.available?() do
  defmodule Helyx.TUI.Footer do
    @moduledoc """
    The footer of the TUI: two dim rows under the composer, with no key
    hints. Row 1 is the location: the working directory, with the home
    directory as `~`, and the git branch. Row 2 is the model, the turn state,
    the queue counts when they are not zero, and "scrolled" while the view is
    scrolled; the reason of a rejected input comes first, in red. The rules
    and the bounds are in `docs/features/coding-agent.md`, "TUI".
    """

    alias ExRatatui.Style
    alias ExRatatui.Text.{Line, Span}
    alias ExRatatui.Widgets.Paragraph
    alias Helyx.TUI.ViewModel

    @dim %Style{modifiers: [:dim]}
    @bad %Style{fg: :red}

    @rows 2

    # The busy indicator: one frame per tick while a turn runs.
    @tick_ms 100
    @frames List.to_tuple(~w(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏))

    # A read of `.git` or `HEAD` takes at most this many bytes: each holds
    # one path or one ref.
    @read_bytes 4096

    @doc """
    The text of row 1 for `cwd`. It reads the disk, so the TUI calls it at
    mount and after each turn, not on each frame. The branch is that of the
    nearest `.git` at or above `cwd`: a directory, or a file
    `gitdir: <path>` as a worktree or a submodule has. A name that git
    cannot make, a detached HEAD, a reftable repository, or a `cwd` outside
    a repository shows no branch. A character of Unicode category C, or a
    run of bytes that is not UTF-8, shows as `?`.
    """
    @spec location(String.t()) :: String.t()
    def location(cwd) do
      cwd = Path.expand(cwd)
      suffix = if name = branch(cwd), do: " (#{name})", else: ""
      clean(tilde(cwd) <> suffix)
    end

    @doc "The rows of the footer."
    @spec rows() :: pos_integer()
    def rows, do: @rows

    @doc "The ms between two frames of the busy indicator. The TUI ticks at this rate while a turn runs."
    @spec tick_ms() :: pos_integer()
    def tick_ms, do: @tick_ms

    @doc """
    The two rows: `location` from `location/1`, then the state of `vm`. The
    turn state is "idle" for a nil `busy`, else a spinner frame and the whole
    seconds of `busy.elapsed`. A non-nil `scroll` adds "scrolled". A row
    does not wrap.
    """
    @spec widget(String.t(), ViewModel.t(), %{elapsed: non_neg_integer()} | nil, term()) ::
            Paragraph.t()
    def widget(location, %ViewModel{} = vm, busy, scroll) do
      %{steers: steers, follow_ups: follow_ups} = vm.queue
      queued = if steers + follow_ups > 0, do: ["queued #{steers}+#{follow_ups}"], else: []
      scrolled = if scroll, do: ["scrolled"], else: []
      status = Enum.join([vm.model, run_state(busy)] ++ queued ++ scrolled, " · ")

      # The reason is a fixed text of `Helyx.TUI`, never input. It comes
      # first: the row does not wrap, and a model ref can be 256 bytes.
      reason = if vm.reason, do: [%Span{content: "✕ #{vm.reason} ", style: @bad}], else: []

      %Paragraph{
        text: [
          %Line{spans: [%Span{content: location, style: @dim}]},
          %Line{spans: reason ++ [%Span{content: status, style: @dim}]}
        ]
      }
    end

    defp run_state(nil), do: "idle"

    defp run_state(%{elapsed: ms}),
      do: "#{elem(@frames, rem(div(ms, @tick_ms), tuple_size(@frames)))} #{div(ms, 1000)}s"

    defp tilde(path), do: tilde(path, System.user_home())

    defp tilde(path, nil), do: path

    # `Path.relative_to/2` gives a path outside the home unchanged, so absolute.
    defp tilde(path, home) do
      case Path.relative_to(path, home) do
        "." -> "~"
        "/" <> _outside -> path
        relative -> "~/" <> relative
      end
    end

    # git trims ASCII whitespace at the end of HEAD, and no other.
    defp branch(dir) do
      with {:ok, git_dir} <- git_dir(dir),
           {:ok, "ref: refs/heads/" <> name} <- read(Path.join(git_dir, "HEAD")),
           name = String.replace(name, ~r/[\t\n\v\f\r ]+\z/, ""),
           true <- branch_name?(name) do
        name
      else
        _no_branch -> nil
      end
    end

    # The rules of `git check-ref-format --branch`, so a name that git cannot
    # make shows no branch. A reftable repository has a HEAD file that names
    # `.invalid` and keeps the real HEAD in its tables.
    defp branch_name?(name) do
      name != "" and
        not Regex.match?(
          ~r"^[-/]|/$|\.$|^\.|/\.|\.\.|//|@\{|\.lock(/|$)|[\x00-\x20\x7f~^:?*\[\\]",
          name
        )
    end

    # The walk up ends at the root, so it takes at most one step for each
    # component of `dir`.
    defp git_dir(dir) do
      dot_git = Path.join(dir, ".git")

      case File.stat(dot_git) do
        {:ok, %{type: :directory}} ->
          {:ok, dot_git}

        {:ok, %{type: :regular}} ->
          gitdir_file(dot_git, dir)

        _none ->
          parent = Path.dirname(dir)
          if parent == dir, do: :error, else: git_dir(parent)
      end
    end

    # A worktree or a submodule has a `.git` file that names its git directory.
    defp gitdir_file(dot_git, dir) do
      case read(dot_git) do
        # git trims only the line end of the path.
        {:ok, "gitdir: " <> path} ->
          {:ok, Path.expand(String.replace(path, ~r/[\r\n]+\z/, ""), dir)}

        _other ->
          :error
      end
    end

    # Only a regular file is read: a FIFO would block the TUI.
    defp read(path) do
      with {:ok, %{type: :regular}} <- File.stat(path),
           {:ok, data} when is_binary(data) <-
             File.open(path, [:read, :binary], &IO.binread(&1, @read_bytes)) do
        {:ok, data}
      else
        _unreadable -> :error
      end
    end

    defp clean(text), do: text |> String.replace_invalid("?") |> String.replace(~r/\p{C}/u, "?")
  end
end
