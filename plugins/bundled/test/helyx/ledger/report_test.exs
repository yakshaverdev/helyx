defmodule Helyx.Ledger.ReportTest do
  use ExUnit.Case, async: true

  alias Helyx.Ledger
  alias Helyx.Ledger.Report
  alias Helyx.Session.Totals

  test "each cost form, with the list mark of a known cost" do
    assert Report.text(%Ledger{totals: %Totals{}}) =~ "cost" and
             Report.text(%Ledger{totals: %Totals{}}) =~ "-"

    assert Report.text(%Ledger{totals: %Totals{unknown: true}}) =~ "$?"

    assert Report.text(%Ledger{totals: %Totals{cost: 0.0042, unknown: true, list: true}}) =~
             "≥$0.0042 list"

    assert Report.text(%Ledger{totals: %Totals{cost: 12.34}}) =~ "$12.34"
  end

  test "cleans a folder name with an escape and an invalid byte" do
    ledger = %Ledger{
      by_project: %{("\e[31mred" <> <<255>>) => %Totals{input: 1}}
    }

    text = Report.text(ledger)

    refute text =~ "\e"
    assert text =~ "?[31mred?"
  end

  test "json decodes back with the totals and the percentiles" do
    ledger = %Ledger{
      since: ~U[2026-11-01 00:00:00Z],
      until: ~U[2026-11-04 00:00:00Z],
      totals: %Totals{
        input: 10,
        output: 5,
        cache_read: 2,
        cache_write: 1,
        cost: 1.23,
        list: true
      },
      by_day: %{"2026-11-01" => %Totals{input: 10}},
      replies: %{"m" => %{"end_turn" => 1}},
      tools: %{"bash" => %{calls: 1, errors: 0, buckets: %{11 => 1}, max: 1_500}},
      hooks: %{{"before_tool", "deny"} => 1},
      denies: %{"bash" => 1},
      compactions: 2
    }

    decoded = JSON.decode!(Report.json(ledger))

    assert decoded["totals"]["input"] == 10
    assert decoded["totals"]["output"] == 5
    assert decoded["totals"]["tokens_in"] == 13
    assert decoded["totals"]["cache_share"] == 15
    assert decoded["totals"]["cost"] == 1.23
    assert decoded["totals"]["cost_list"] == true
    assert decoded["totals"]["cost_unknown"] == false
    assert decoded["tools"]["bash"]["p50"] == 2_048
    assert decoded["tools"]["bash"]["max"] == 1_500
    assert decoded["compactions"] == 2

    assert decoded["hooks"] == [
             %{"point" => "before_tool", "answer" => "deny", "count" => 1}
           ]
  end
end
