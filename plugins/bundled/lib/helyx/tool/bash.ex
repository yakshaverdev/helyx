defmodule Helyx.Tool.Bash do
  @keep_bytes 4 * Helyx.Text.max_bytes()

  @moduledoc """
  Runs a shell command in the working directory with `bash -c`.

  stdout and stderr are merged. Long output is cut from the head end and the
  result says which lines it shows. Only the last #{@keep_bytes} bytes are
  kept while the command runs, so a command that never stops writing does
  not grow the buffer; the result then says so, and its line count is of
  the kept part. A non-zero exit code is reported in the text; the result
  is an error only when the command could not start. stdin is `/dev/null`.
  The call returns when stdout closes, so a background child that keeps
  stdout open holds the call until it exits.

  The command runs in its own process group under a perl watchdog, started
  by `Helyx.Watchdog`, which holds the group with the hands before the
  command is allowed to execute. The watchdog ties the command's life to
  the port: when the port closes, because anything above the command died,
  the watchdog kills the group. perl is required; `check/0` reports a
  system without it when a session starts or resumes.
  """

  @behaviour Helyx.Tool

  @impl true
  def name, do: "bash"

  @impl true
  def description do
    "Run a shell command in the working directory. Returns stdout and stderr, " <>
      "the last #{Helyx.Text.max_lines()} lines or #{div(Helyx.Text.max_bytes(), 1024)} KB, " <>
      "and the exit code when it is not zero."
  end

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{"command" => %{"type" => "string"}},
      "required" => ["command"]
    }
  end

  @impl true
  def check, do: check(&System.find_executable/1)

  @doc false
  def check(find) do
    if find.("perl") do
      :ok
    else
      {:error, "perl not found: the bash tool needs perl to watch its commands"}
    end
  end

  # Port arguments are NUL-terminated C strings: a command with a NUL would
  # be cut there silently and the result would report success for something
  # that did not run as given. JSON strings can carry an escaped NUL, so the
  # model can send one. The session checks the working directory at start.
  @impl true
  def run(%{"command" => command}, cwd) when is_binary(command) do
    if String.contains?(command, <<0>>),
      do: {:error, "the command contains a NUL byte"},
      else: run_command(command, cwd)
  end

  def run(_args, _cwd), do: {:error, "bash needs a command"}

  @impl true
  defdelegate release(handles, mode, deadline), to: Helyx.Watchdog.Group

  defp run_command(command, cwd) do
    bash = System.find_executable("bash") || "/bin/bash"

    result(Helyx.Watchdog.start([bash, "-c", command], cwd, nil))
  end

  # `Helyx.Watchdog.start/4` cuts the reason of a failed start.
  defp result({:error, reason}), do: {:error, "the command did not start: " <> reason}

  # `pre`, perl's own startup output, stays in front of the output.
  defp result({:started, port, pre}) do
    {output, dropped?, status} = collect(port, pre, false)
    {:ok, render(output, dropped?, status)}
  end

  defp render(output, dropped?, status) do
    text =
      case output do
        "" -> "(no output)"
        out -> Helyx.Text.truncate(out, :tail)
      end

    text =
      if dropped?,
        do: "[output cut: only the last #{@keep_bytes} bytes were kept]\n" <> text,
        else: text

    if status == 0, do: text, else: text <> "\nExit code: #{status}"
  end

  # No per-call timeout: a command that never exits holds the call until
  # the turn is aborted.
  defp collect(port, acc, dropped?) do
    receive do
      {^port, {:data, data}} ->
        {acc, cut?} = keep_tail(acc <> data)
        collect(port, acc, dropped? or cut?)

      {^port, {:exit_status, status}} ->
        {acc, dropped?, status}
    end
  end

  # Cuts at twice the cap so the copy is amortised, not once per chunk.
  # The cut can land inside a character; the hands repair the partial
  # character at the start of the result.
  @doc false
  # Public for the direct test of the cut.
  def keep_tail(acc) when byte_size(acc) <= 2 * @keep_bytes, do: {acc, false}
  def keep_tail(acc), do: {binary_part(acc, byte_size(acc) - @keep_bytes, @keep_bytes), true}
end
