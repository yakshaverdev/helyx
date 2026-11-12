defmodule Helyx.Ledger.Report do
  @moduledoc """
  The text and JSON forms of a `Helyx.Ledger`. It shows the totals, the same
  values by UTC day, model, and project folder, the sessions with the highest
  known cost, the replies by stop reason and model, the tools with their wall
  times, the hook answers and denies, the compactions, and the skips. Every
  text from a file is cleaned here, so a file cannot write escape codes to the
  terminal. The rules are in `docs/features/usage-ledger.md`.
  """

  alias Helyx.{Ledger, Message}
  alias Helyx.Session.Totals

  @doc "The plain-text report, one section for each item of the ledger."
  @spec text(Ledger.t()) :: String.t()
  def text(ledger) do
    [
      totals_section(ledger),
      by_day_section(ledger),
      by_map_section("By model", "model", ledger.by_model),
      by_map_section("By project", "folder", ledger.by_project),
      sessions_section(ledger),
      replies_section(ledger),
      tools_section(ledger),
      hooks_section(ledger),
      denies_section(ledger),
      compactions_section(ledger),
      skipped_section(ledger)
    ]
    |> Enum.join("\n\n")
    |> Kernel.<>("\n")
  end

  @doc "The JSON report, with the same values as `text/1` and string keys."
  @spec json(Ledger.t()) :: String.t()
  def json(ledger) do
    %{
      "since" => iso(ledger.since),
      "until" => iso(ledger.until),
      "files" => ledger.files,
      "skipped_files" => ledger.skipped_files,
      "skipped_entries" => ledger.skipped_entries,
      "too_large" => ledger.too_large,
      "torn" => ledger.torn,
      "totals" => totals_json(ledger.totals),
      "by_day" => totals_map_json(ledger.by_day),
      "by_model" => totals_map_json(ledger.by_model),
      "by_project" => totals_map_json(ledger.by_project),
      "sessions" => sessions_json(ledger),
      "replies" => replies_json(ledger.replies),
      "tools" => tools_json(ledger.tools),
      "hooks" => hooks_json(ledger.hooks),
      "denies" => denies_json(ledger.denies),
      "compactions" => ledger.compactions
    }
    |> JSON.encode!()
    |> Kernel.<>("\n")
  end

  defp totals_section(ledger) do
    t = ledger.totals

    section(
      "Totals",
      table(["metric", "value"], [
        ["tokens in", prompt(t)],
        ["tokens out", t.output],
        ["cache", share(t)],
        ["cost", cost(t)]
      ])
    )
  end

  defp by_day_section(ledger) do
    rows =
      ledger.by_day
      |> Enum.sort_by(fn {day, _totals} -> day end, :desc)
      |> Enum.map(fn {day, t} -> usage_row(clean(day), t) end)

    section(
      "By day",
      table(["day", "tokens in", "tokens out", "cache", "cost"], rows)
    )
  end

  defp by_map_section(title, first, map) do
    rows =
      map
      |> Enum.sort_by(fn {key, t} -> {-(t.cost || 0), key} end)
      |> Enum.map(fn {key, t} -> usage_row(clean(key), t) end)

    section(title, table([first, "tokens in", "tokens out", "cache", "cost"], rows))
  end

  defp sessions_section(ledger) do
    rows =
      ledger.sessions
      |> known_cost()
      |> Enum.sort_by(fn {id, session} -> {-session.totals.cost, id} end)
      |> Enum.take(10)
      |> Enum.map(fn {id, session} ->
        [clean(id), clean(session.cwd), clean(session.prompt || ""), cost(session.totals)]
      end)

    section("Top sessions", table(["session", "folder", "prompt", "cost"], rows))
  end

  defp replies_section(ledger) do
    reasons = Enum.map(Message.stop_reasons(), &Atom.to_string/1)
    headers = ["model" | reasons] ++ ["none"]

    rows =
      ledger.replies
      |> Enum.sort_by(fn {model, _counts} -> model end)
      |> Enum.map(fn {model, counts} ->
        [clean(model)] ++
          Enum.map(reasons, &Map.get(counts, &1, 0)) ++ [Map.get(counts, "none", 0)]
      end)

    section("Replies", table(headers, rows))
  end

  defp tools_section(ledger) do
    rows =
      ledger.tools
      |> Enum.sort_by(fn {name, tool} -> {-tool.calls, name} end)
      |> Enum.map(fn {name, tool} ->
        [
          clean(name),
          tool.calls,
          tool.errors,
          percent(tool.errors, tool.calls),
          Ledger.percentile(tool, 0.5) || "-",
          Ledger.percentile(tool, 0.95) || "-",
          tool.max || "-"
        ]
      end)

    section(
      "Tools",
      table(
        ["tool", "calls", "errors", "error %", "p50(ms)", "p95(ms)", "max(ms)"],
        rows
      )
    )
  end

  defp hooks_section(ledger) do
    rows =
      ledger.hooks
      |> Enum.sort_by(fn {{point, answer}, _count} -> {point, answer} end)
      |> Enum.map(fn {{point, answer}, count} -> [clean(point), clean(answer), count] end)

    section("Hooks", table(["point", "answer", "count"], rows))
  end

  defp denies_section(ledger) do
    rows =
      ledger.denies
      |> Enum.sort_by(fn {tool, count} -> {-count, tool} end)
      |> Enum.map(fn {tool, count} -> [clean(tool), count] end)

    section("Denies", table(["tool", "denies"], rows))
  end

  defp compactions_section(ledger) do
    section("Compactions", table(["count"], [[ledger.compactions]]))
  end

  defp skipped_section(ledger) do
    section(
      "Skipped",
      table(["files", "torn lines", "too large lines", "entries"], [
        [ledger.skipped_files, ledger.torn, ledger.too_large, ledger.skipped_entries]
      ])
    )
  end

  defp usage_row(key, t) do
    [key, prompt(t), t.output, share(t), cost(t)]
  end

  defp prompt(%Totals{input: input, cache_read: read, cache_write: write}),
    do: input + read + write

  defp share(%Totals{} = t) do
    total = prompt(t)
    if total == 0, do: "-", else: "#{round(t.cache_read * 100 / total)}%"
  end

  defp cost(%Totals{cost: nil, unknown: false}), do: "-"
  defp cost(%Totals{cost: nil, unknown: true}), do: "$?"
  defp cost(%Totals{cost: cost, unknown: true} = t), do: "≥$" <> number(cost) <> list(t)
  defp cost(%Totals{cost: cost} = t), do: "$" <> number(cost) <> list(t)

  defp list(%Totals{list: true, cost: cost}) when cost != nil, do: " list"
  defp list(%Totals{}), do: ""

  defp number(cost) do
    cost = cost / 1
    decimals = if Float.round(cost, 4) < 0.01, do: 4, else: 2
    :erlang.float_to_binary(cost, decimals: decimals)
  end

  defp percent(_part, 0), do: "-"
  defp percent(part, whole), do: "#{round(part * 100 / whole)}%"

  defp known_cost(sessions) do
    Enum.filter(sessions, fn {_id, session} -> session.totals.cost != nil end)
  end

  defp totals_json(%Totals{} = t) do
    %{
      "input" => t.input,
      "output" => t.output,
      "cache_read" => t.cache_read,
      "cache_write" => t.cache_write,
      "tokens_in" => prompt(t),
      "cache_share" => share_json(t),
      "cost" => t.cost,
      "cost_unknown" => t.unknown,
      "cost_list" => t.list
    }
  end

  defp share_json(%Totals{} = t) do
    total = prompt(t)
    if total == 0, do: nil, else: round(t.cache_read * 100 / total)
  end

  defp totals_map_json(map) do
    Map.new(map, fn {key, totals} -> {clean(key), totals_json(totals)} end)
  end

  defp sessions_json(ledger) do
    ledger.sessions
    |> known_cost()
    |> Enum.sort_by(fn {id, session} -> {-session.totals.cost, id} end)
    |> Enum.take(10)
    |> Enum.map(fn {id, session} ->
      %{
        "id" => clean(id),
        "cwd" => clean(session.cwd),
        "prompt" => clean(session.prompt || ""),
        "parent" => session.parent && clean(session.parent),
        "totals" => totals_json(session.totals)
      }
    end)
  end

  defp replies_json(replies) do
    Map.new(replies, fn {model, counts} -> {clean(model), counts} end)
  end

  defp tools_json(tools) do
    Map.new(tools, fn {name, tool} ->
      {clean(name),
       %{
         "calls" => tool.calls,
         "errors" => tool.errors,
         "error_percent" => error_percent_json(tool),
         "p50" => Ledger.percentile(tool, 0.5),
         "p95" => Ledger.percentile(tool, 0.95),
         "max" => tool.max
       }}
    end)
  end

  defp error_percent_json(%{calls: 0}), do: nil
  defp error_percent_json(%{calls: calls, errors: errors}), do: round(errors * 100 / calls)

  defp hooks_json(hooks) do
    for {{point, answer}, count} <- hooks do
      %{"point" => clean(point), "answer" => clean(answer), "count" => count}
    end
  end

  defp denies_json(denies), do: Map.new(denies, fn {tool, count} -> {clean(tool), count} end)

  defp iso(nil), do: nil
  defp iso(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  # A file cannot write escape codes or invalid bytes to the terminal. The
  # JSON form gets the same replacement, so its encode never fails.
  defp clean(text) when is_binary(text) do
    text
    |> String.replace_invalid("?")
    |> String.replace(~r/[\x00-\x1F\x7F]/, "?")
  end

  defp clean(other), do: clean(to_string(other))

  defp section(title, body), do: title <> "\n" <> body

  defp table(headers, rows) do
    rows = Enum.map([headers | rows], fn row -> Enum.map(row, &to_string/1) end)

    widths =
      Enum.reduce(rows, List.duplicate(0, length(headers)), fn row, widths ->
        Enum.zip_with(row, widths, fn cell, width -> max(String.length(cell), width) end)
      end)

    Enum.map_join(rows, "\n", fn row ->
      row
      |> Enum.zip(widths)
      |> Enum.map_join("  ", fn {cell, width} -> String.pad_trailing(cell, width) end)
      |> String.trim_trailing()
    end)
  end
end
