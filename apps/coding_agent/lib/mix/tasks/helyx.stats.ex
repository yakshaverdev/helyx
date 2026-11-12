defmodule Mix.Tasks.Helyx.Stats do
  @shortdoc "Prints the usage ledger of the saved sessions"
  @moduledoc """
  Prints the usage ledger of the saved sessions for a window:

      mix helyx.stats [--days n | --since YYYY-MM-DD] [--until YYYY-MM-DD] [--cwd dir] [--json]

  The window defaults to the last 30 days. `--since` is the day at 00:00 UTC,
  and `--until` is the day after its day at 00:00 UTC, so the day itself is in
  the window. `--cwd` keeps one project folder, and `--json` prints the JSON
  form. The task reads the files only and starts no application. A bad
  argument or a bad window prints one line on stderr and stops Mix with status
  1. The rules are in `docs/features/usage-ledger.md`.
  """

  use Mix.Task

  alias Helyx.Ledger
  alias Helyx.Ledger.Report

  @switches [days: :integer, since: :string, until: :string, cwd: :string, json: :boolean]
  @default_days 30
  @max_days 3_650

  @impl true
  def run(argv) do
    Mix.Task.run("app.config")

    case parse(argv) do
      {:ok, opts} -> print(opts)
      {:error, reason} -> fail(reason)
    end
  end

  defp print(opts) do
    case Ledger.read(sessions_dir(),
           since: opts.since,
           until: opts.until,
           cwd: opts.cwd
         ) do
      {:ok, ledger} ->
        IO.write(if opts.json, do: Report.json(ledger), else: Report.text(ledger))

      {:error, reason} ->
        fail(reason)
    end
  end

  # The rule of CodingAgent.CLI: application env so that a test points the
  # report at its own directory.
  defp sessions_dir do
    Application.get_env(:coding_agent, :sessions_dir) || Path.expand("~/.helyx/sessions")
  end

  defp fail(reason) do
    IO.puts(:stderr, "helyx.stats: #{reason}")
    exit({:shutdown, 1})
  end

  defp parse(argv) do
    {opts, args, invalid} = OptionParser.parse(argv, strict: @switches)

    with :ok <- no_invalid(invalid),
         :ok <- no_args(args),
         :ok <- window_choice(opts),
         {:ok, days} <- days(opts),
         {:ok, until} <- until(opts),
         {:ok, since} <- since(opts, days, until),
         :ok <- ordered(since, until) do
      {:ok, %{since: since, until: until, cwd: cwd(opts), json: Keyword.get(opts, :json, false)}}
    end
  end

  defp no_invalid([]), do: :ok
  defp no_invalid([{switch, _value} | _rest]), do: {:error, "unknown switch #{switch}"}

  defp no_args([]), do: :ok
  defp no_args([arg | _rest]), do: {:error, "unexpected argument #{arg}"}

  defp window_choice(opts) do
    if Keyword.has_key?(opts, :days) and Keyword.has_key?(opts, :since),
      do: {:error, "use either --days or --since, not both"},
      else: :ok
  end

  defp days(opts) do
    case Keyword.get(opts, :days) do
      nil -> {:ok, @default_days}
      days when days >= 1 and days <= @max_days -> {:ok, days}
      _days -> {:error, "--days must be between 1 and #{@max_days}"}
    end
  end

  defp until(opts) do
    case Keyword.get(opts, :until) do
      nil -> {:ok, DateTime.utc_now()}
      value -> date(value, "--until", &(Date.add(&1, 1) |> midnight()))
    end
  end

  defp since(opts, days, until) do
    case Keyword.get(opts, :since) do
      nil -> {:ok, DateTime.add(until, -days * 24 * 60 * 60, :second)}
      value -> date(value, "--since", &midnight/1)
    end
  end

  defp date(value, switch, fun) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, fun.(date)}
      {:error, _reason} -> {:error, "invalid date for #{switch}: #{value}"}
    end
  end

  defp midnight(date), do: DateTime.new!(date, ~T[00:00:00], "Etc/UTC")

  defp ordered(since, until) do
    if DateTime.compare(since, until) == :lt,
      do: :ok,
      else: {:error, "the window is empty: since must be before until"}
  end

  defp cwd(opts) do
    case Keyword.get(opts, :cwd) do
      nil -> nil
      path -> Path.expand(path)
    end
  end
end
