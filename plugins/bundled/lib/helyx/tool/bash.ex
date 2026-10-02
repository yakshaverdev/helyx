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

  # The launcher and the handshake live in `Helyx.Watchdog`, and the release
  # in `Helyx.Watchdog.Group`; the harness providers share both (ADR 0005).

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

  # Recorded risk: a future macOS may ship without perl. The watchdog is
  # small enough to rewrite in sh with job control if that happens.
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

  # Port arguments are NUL-terminated C strings: a string with a NUL would
  # be cut there silently and the result would report success for something
  # that did not run as given. JSON strings can carry an escaped NUL, so the
  # model can send one. Every string that reaches the port is checked here.
  @impl true
  def run(%{"command" => command}, cwd) when is_binary(command) do
    cond do
      String.contains?(command, <<0>>) ->
        {:error, "the command contains a NUL byte"}

      String.contains?(cwd, <<0>>) ->
        {:error, "the working directory contains a NUL byte"}

      true ->
        run_command(command, cwd)
    end
  end

  def run(_args, _cwd), do: {:error, "bash needs a command"}

  @impl true
  defdelegate release(handles, mode, deadline), to: Helyx.Watchdog.Group

  defp run_command(command, cwd) do
    bash = System.find_executable("bash") || "/bin/bash"

    result(Helyx.Watchdog.start([bash, "-c", command], cwd, nil))
  end

  # The text of a failed start names perl at its head (see
  # `Helyx.Watchdog.start/4`), so the head is kept, with the cut of the
  # harness providers. A start report has its reason at the tail.
  defp result({:failed, text}), do: not_started(Helyx.HarnessIO.cap_error(text))

  defp result(started) do
    case consume(started) do
      {:not_started, reason} -> not_started(Helyx.Text.truncate(reason, :tail))
      {output, dropped?, status} -> {:ok, render(output, dropped?, status)}
    end
  end

  defp not_started(reason), do: {:error, "the command did not start: " <> reason}

  defp consume({:not_started, _port, reason}), do: {:not_started, reason}

  defp consume({:started, port, pre, nonce, go}),
    do: start_report(collect(port, pre, false), pre, nonce <> " 1\n", go <> " 0\n")

  # Reads the start report off the collected output (see the watchdog).
  # `pre` is what came before the group marker, perl's own startup output.
  # Output that was cut has lost its head, and only a command that ran
  # writes that much: the watchdog's own text is at most `pre`, the start
  # line, perl's warnings, and a 4,096-byte report.
  defp start_report({_output, true, _status} = ran, _pre, _start, _failed), do: ran

  defp start_report({output, false, status}, pre, start, failed) do
    ^pre <> rest = output

    case String.split(rest, failed, parts: 2) do
      [before, reason] ->
        {:not_started, pre <> String.replace_prefix(before, start, "") <> reason}

      [^start <> body] ->
        {pre <> body, false, status}

      [_no_start_line] ->
        {:not_started, "the command gave no start line: " <> output}
    end
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

  # ponytail: no per-call timeout; a command that never exits holds the call
  # until the turn is aborted.
  defp collect(port, acc, dropped?) do
    receive do
      {^port, {:data, data}} ->
        {acc, cut?} = keep_tail(acc <> data)
        collect(port, acc, dropped? or cut?)

      {^port, {:exit_status, status}} ->
        {acc, dropped?, status}
    end
  end

  # A character has at most three continuation bytes (`10xxxxxx`).
  @max_continuation_bytes 3

  # Cuts at twice the cap so the copy is amortised, not once per chunk.
  # The cut can land inside a character; the rest of that character is
  # dropped, so the kept tail starts on a character boundary. Only the start
  # is cleaned: the end of `acc` can hold a character the next chunk completes.
  @doc false
  # Public for the direct test of the cut.
  def keep_tail(acc) when byte_size(acc) <= 2 * @keep_bytes, do: {acc, false}

  def keep_tail(acc) do
    tail = binary_part(acc, byte_size(acc) - @keep_bytes, @keep_bytes)
    {drop_continuation(tail, @max_continuation_bytes), true}
  end

  defp drop_continuation(<<2::2, _::6, rest::binary>>, n) when n > 0,
    do: drop_continuation(rest, n - 1)

  defp drop_continuation(bin, _n), do: bin
end
