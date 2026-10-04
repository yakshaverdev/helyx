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
    hints but the one of a first Ctrl+C. Row 1 is the location: the working
    directory, with the home directory as `~`, and the git branch. Row 2 is
    the model, the turn state, the queue counts when they are not zero, and
    "scrolled" while the view is scrolled; the reason of a rejected input
    comes first, in red, then the Ctrl+C hint, in bold. The rules
    and the bounds are in `docs/features/coding-agent.md`, "TUI".
    """

    alias ExRatatui.Style
    alias ExRatatui.Text.{Line, Span}
    alias ExRatatui.Widgets.Paragraph
    alias Helyx.TUI.{Quit, ViewModel}

    @dim %Style{modifiers: [:dim]}
    @bad %Style{fg: :red}
    @bold %Style{modifiers: [:bold]}

    @rows 2

    # The busy indicator: one frame per tick while a turn runs.
    @tick_ms 100
    @frames List.to_tuple(~w(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏))

    # `git branch --show-current` gets this long, then it is killed, and
    # this many bytes of its output are kept: a name of a branch is short.
    @git_ms 2000
    @branch_bytes 256

    # sh sends its own stderr and that of git to /dev/null: on the terminal
    # it would draw over the TUI, and sh reports a killed job there. sh
    # kills git when its own stdin, the port, reaches its end: when the
    # port closes at the deadline, or when the task or the VM ends. Only
    # builtins of sh, so no `PATH` lookup. `-C` and not the `:cd` option of
    # the port, which writes its own error to the terminal for a missing
    # directory.
    @run_git ~S"""
    exec 3<&0 2>/dev/null
    "$0" -C "$1" branch --show-current </dev/null &
    git=$!
    (read -r _ <&3; kill -KILL "$git") &
    watch=$!
    wait "$git"
    status=$?
    kill "$watch"
    exit "$status"
    """

    @doc """
    The text of row 1: `cwd`, with the home directory as `~`, and `branch`
    when it is not nil. A character of Unicode category C, or a run of
    bytes that is not UTF-8, shows as `?`.
    """
    @spec location(String.t(), String.t() | nil) :: String.t()
    def location(cwd, branch) do
      suffix = if branch, do: " (#{branch})", else: ""
      clean(tilde(Path.expand(cwd)) <> suffix)
    end

    @doc """
    The branch that `git branch --show-current` prints in `cwd`, cut at
    #{@branch_bytes} bytes, or nil. It blocks for up to #{@git_ms} ms, so
    the TUI calls it in a task. No git, a port that cannot open, a timeout,
    a non-zero exit, or no output (a detached HEAD) gives nil.
    """
    @spec branch(String.t()) :: String.t() | nil
    def branch(cwd), do: branch(cwd, System.find_executable("git"), @git_ms)

    @doc false
    # Public for the tests, which give a fake git and a short timeout.
    def branch(_cwd, nil, _timeout_ms), do: nil

    def branch(cwd, git, timeout_ms) do
      port =
        Port.open({:spawn_executable, "/bin/sh"}, [
          :binary,
          :exit_status,
          args: ["-c", @run_git, git, cwd]
        ])

      collect(port, "", System.monotonic_time(:millisecond) + timeout_ms)
    rescue
      # No port left, or no file descriptor: no branch.
      _no_port in [ErlangError, SystemLimitError] -> nil
    end

    # The deadline is checked before each receive: a message in the mailbox
    # wins over `after`.
    defp collect(port, acc, deadline) do
      case deadline - System.monotonic_time(:millisecond) do
        left when left <= 0 ->
          kill(port)

        left ->
          receive do
            {^port, {:data, data}} ->
              acc = acc <> data
              collect(port, binary_part(acc, 0, min(byte_size(acc), @branch_bytes)), deadline)

            {^port, {:exit_status, 0}} ->
              case String.trim_trailing(acc, "\n") do
                "" -> nil
                name -> name
              end

            {^port, {:exit_status, _failed}} ->
              nil
          after
            left -> kill(port)
          end
      end
    end

    # The close ends the stdin of sh, and sh kills git (see `@run_git`).
    # A port that closed at the deadline, as git exited, raises.
    defp kill(port) do
      Port.close(port)
      nil
    rescue
      ArgumentError -> nil
    end

    @doc "The rows of the footer."
    @spec rows() :: pos_integer()
    def rows, do: @rows

    @doc "The ms between two frames of the busy indicator. The TUI ticks at this rate while a turn runs."
    @spec tick_ms() :: pos_integer()
    def tick_ms, do: @tick_ms

    @doc """
    The two rows: `location` from `location/2`, then the state of `vm`. The
    turn state is "idle" for a nil `busy`, else a spinner frame and the whole
    seconds of `busy.elapsed`. A non-nil `scroll` adds "scrolled". The hint
    of `quit` (`Helyx.TUI.Quit.hint/1`) comes after the reason. A row does
    not wrap.
    """
    @spec widget(
            String.t(),
            ViewModel.t(),
            %{elapsed: non_neg_integer()} | nil,
            term(),
            Quit.t()
          ) :: Paragraph.t()
    def widget(location, %ViewModel{} = vm, busy, scroll, quit) do
      %{steers: steers, follow_ups: follow_ups} = vm.queue
      queued = if steers + follow_ups > 0, do: ["queued #{steers}+#{follow_ups}"], else: []
      scrolled = if scroll, do: ["scrolled"], else: []
      status = Enum.join([vm.model, run_state(busy)] ++ queued ++ scrolled, " · ")

      # The reason is a fixed text of `Helyx.TUI`, never input. It comes
      # first: the row does not wrap, and a model ref can be 256 bytes.
      reason = if vm.reason, do: [%Span{content: "✕ #{vm.reason} ", style: @bad}], else: []
      hint = if text = Quit.hint(quit), do: [%Span{content: "#{text} ", style: @bold}], else: []

      %Paragraph{
        text: [
          %Line{spans: [%Span{content: location, style: @dim}]},
          %Line{spans: reason ++ hint ++ [%Span{content: status, style: @dim}]}
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

    defp clean(text), do: text |> String.replace_invalid("?") |> String.replace(~r/\p{C}/u, "?")
  end
end
