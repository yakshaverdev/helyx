defmodule Helyx.Hub.Params do
  @moduledoc false
  # The params of the `hub.*` operations, checked in the caller at the entry
  # of Hub before it reads any object that they name (`docs/features/hub.md`,
  # decision 5, "The order of the checks"; Bounds). The bounds of Hub live
  # here, and a module that reads one asks for it.

  @max_cwd_bytes 4_096
  @max_title_bytes 256
  @max_labels 16
  @max_label_bytes 64
  @max_project_name_bytes 128
  @max_query_bytes 256
  @max_limit 256
  @default_limit 50
  # The bound of a prompt of a schedule and of the template of a subscription.
  @max_text_bytes 16_384
  @max_ahead_s 31_622_400
  @max_hook_label_bytes 64
  @placeholder "{{payload}}"
  @every_s 300..2_678_400
  # The bound of the `prompt` of a record (Store schema).
  @max_record_prompt_bytes 1_024
  # The largest integer that SQLite binds.
  @max_cursor_time 2 ** 63 - 1

  # One row for each operation. A param is `{key, field, type, presence}`:
  # the key on the wire, the field that its checked value takes when that is
  # not the key, its type with its bound (the types are those of `value/2`),
  # and `:required`, `:optional` (an absent key stays out of the checked
  # map), or `{:default, value}`. `answer` states the shape of `{:ok, value}`;
  # `across` names the rule of the row that runs after every param passed, or
  # nil.
  @ops %{
    "hub.records.get" => %{
      params: [{"session", :session, :id, :required}],
      across: nil,
      answer: {:only, :session}
    },
    "hub.records.delete" => %{
      params: [{"session", :session, :id, :required}],
      across: nil,
      answer: {:only, :session}
    },
    # At least one field; `labels` replaces the set, with duplicates removed;
    # `project: nil` clears the project.
    "hub.records.update" => %{
      params: [
        {"session", :session, :id, :required},
        {"title", :title, {:text, 0, @max_title_bytes}, :optional},
        {"labels", :labels, :labels, :optional},
        {"visibility", :visibility, :visibility, :optional},
        {"project", :project_id, :project, :optional},
        {"archived", :archived, :boolean, :optional}
      ],
      across: :one_change,
      answer: {:changes, :session}
    },
    "hub.records.search" => %{
      params: [
        {"query", :query, {:bytes, @max_query_bytes}, :optional},
        {"labels", :labels, :labels, :optional},
        {"project", :project_id, :project, :optional},
        {"archived", :archived, :boolean, :optional},
        {"mine", :mine, :boolean, :optional},
        {"limit", :limit, :limit, {:default, @default_limit}},
        {"after", :after, :after, :optional}
      ],
      across: nil,
      answer: :filters
    },
    "hub.projects.create" => %{
      params: [{"name", :name, {:text, 1, @max_project_name_bytes}, :required}],
      across: nil,
      answer: {:only, :name}
    },
    "hub.projects.update" => %{
      params: [
        {"project", :project_id, :id, :required},
        {"name", :name, {:text, 1, @max_project_name_bytes}, :required}
      ],
      across: nil,
      answer: {:tuple, [:project_id, :name]}
    },
    "hub.projects.delete" => %{
      params: [{"project", :project_id, :id, :required}],
      across: nil,
      answer: {:only, :project_id}
    },
    # A schedule (decision 11): `at` from now to 366 days on, `every` absent
    # or a period of 300 s to 31 days, and a prompt of UTF-8.
    "hub.schedules.create" => %{
      params: [
        {"session", :session, :id, :required},
        {"at", :at, :at, :required},
        {"every", :every, {:range, @every_s}, :optional},
        {"prompt", :prompt, {:long_text, 1, @max_text_bytes}, :required}
      ],
      across: nil,
      answer: {:nested, :session, [:at, :every, :prompt]}
    },
    "hub.schedules.list" => %{
      params: [{"session", :session, :id, :optional}],
      across: nil,
      answer: {:or_nil, :session}
    },
    "hub.schedules.delete" => %{
      params: [{"schedule", :schedule, :id, :required}],
      across: nil,
      answer: {:only, :schedule}
    },
    # An event subscription (decision 17): a template of 1 to 16,384 bytes of
    # UTF-8 that holds `{{payload}}` exactly once, and an optional label of 0
    # to 64 bytes with no control character.
    "hub.subscriptions.create" => %{
      params: [
        {"session", :session, :id, :required},
        {"prompt", :template, {:long_text, 1, @max_text_bytes}, :required},
        {"label", :label, {:text, 0, @max_hook_label_bytes}, {:default, ""}}
      ],
      across: :placeholder,
      answer: {:nested, :session, [:template, :label]}
    },
    "hub.subscriptions.list" => %{
      params: [{"session", :session, :id, :optional}],
      across: nil,
      answer: {:or_nil, :session}
    },
    "hub.subscriptions.delete" => %{
      params: [{"subscription", :subscription, :id, :required}],
      across: nil,
      answer: {:only, :subscription}
    }
  }

  # The operations that take params, in a guard.
  def ops, do: Map.keys(@ops)

  @doc false
  # The bounds of a schedule, for the text of the `schedule` tool.
  def schedule_bounds,
    do: %{max_ahead_s: @max_ahead_s, every_s: @every_s, max_prompt_bytes: @max_text_bytes}

  def check(op, params) when is_map(params) do
    case Map.fetch(@ops, op) do
      {:ok, row} -> run(row, params)
      :error -> :bad_params
    end
  end

  def check(_op, _params), do: :bad_params

  def max_cwd_bytes, do: @max_cwd_bytes

  def max_text_bytes, do: @max_text_bytes

  def max_limit, do: @max_limit

  def default_limit, do: @default_limit

  defp run(row, params) do
    with :ok <- keys(params, row.params),
         {:ok, checked, large} <- values(params, row.params),
         :ok <- across(row.across, checked) do
      if large, do: :text_too_large, else: answer(row.answer, checked)
    end
  end

  # A key that no param of the row names is `:bad_params`.
  defp keys(params, specs) do
    named = Enum.map(specs, &elem(&1, 0))

    if Enum.all?(Map.keys(params), &(&1 in named)), do: :ok, else: :bad_params
  end

  # Each param in the order of the row; `large` is set by a text over the
  # bytes of its type, whose answer comes after every other param passed.
  defp values(params, specs) do
    Enum.reduce_while(specs, {:ok, %{}, nil}, fn {key, field, type, presence},
                                                 {:ok, acc, large} ->
      case checked(type, fetch(params, key, presence)) do
        {:large, value} -> {:cont, {:ok, Map.put(acc, field, value), :text_too_large}}
        {:ok, checked} -> {:cont, {:ok, Map.put(acc, field, checked), large}}
        :absent -> {:cont, {:ok, acc, large}}
        :bad_params -> {:halt, :bad_params}
      end
    end)
  end

  defp checked(type, {:ok, value}) do
    with :large <- value(type, value), do: {:large, value}
  end

  defp checked(_type, missing), do: missing

  defp fetch(params, key, :required) do
    case Map.fetch(params, key) do
      {:ok, value} -> {:ok, value}
      :error -> :bad_params
    end
  end

  defp fetch(params, key, :optional) do
    case Map.fetch(params, key) do
      {:ok, value} -> {:ok, value}
      :error -> :absent
    end
  end

  defp fetch(params, key, {:default, default}) do
    case Map.fetch(params, key) do
      {:ok, value} -> {:ok, value}
      :error -> {:ok, default}
    end
  end

  # The rule of a row that a param cannot state: it runs after every param
  # passed, so a text over its bytes is `:text_too_large` only then.
  defp across(nil, _checked), do: :ok
  defp across(:one_change, checked) when map_size(checked) > 1, do: :ok
  defp across(:one_change, _checked), do: :bad_params

  defp across(:placeholder, %{template: template}) do
    if length(String.split(template, @placeholder)) == 2, do: :ok, else: :bad_params
  end

  defp answer({:only, field}, checked), do: {:ok, Map.fetch!(checked, field)}

  defp answer({:tuple, fields}, checked),
    do: {:ok, fields |> Enum.map(&Map.fetch!(checked, &1)) |> List.to_tuple()}

  defp answer({:changes, field}, checked),
    do: {:ok, {Map.fetch!(checked, field), Map.delete(checked, field)}}

  defp answer(:filters, checked), do: {:ok, checked}

  defp answer({:nested, field, fields}, checked),
    do: {:ok, {Map.fetch!(checked, field), Map.new(fields, &{&1, Map.get(checked, &1)})}}

  defp answer({:or_nil, field}, checked), do: {:ok, Map.get(checked, field)}

  defp value(:id, value) when is_binary(value), do: {:ok, value}

  defp value(:visibility, value) when value in ["private", "hub"], do: {:ok, value}

  defp value(:project, nil), do: {:ok, nil}
  defp value(:project, value) when is_binary(value), do: {:ok, value}

  defp value(:boolean, value) when is_boolean(value), do: {:ok, value}

  defp value(:limit, value) when is_integer(value) and value in 1..@max_limit, do: {:ok, value}

  defp value(:after, value) when is_binary(value), do: cursor(value)

  defp value(:at, value) when is_integer(value), do: at(value)

  defp value(:labels, value), do: labels(value)

  defp value({:range, range}, value) when is_integer(value) do
    if value in range, do: {:ok, value}, else: :bad_params
  end

  defp value({:bytes, max}, value) when is_binary(value) and byte_size(value) <= max,
    do: {:ok, value}

  defp value({:text, min, max}, value) do
    if text?(value, min, max), do: {:ok, value}, else: :bad_params
  end

  defp value({:long_text, min, max}, value) when is_binary(value) do
    cond do
      not String.valid?(value) or byte_size(value) < min -> :bad_params
      byte_size(value) > max -> :large
      true -> {:ok, value}
    end
  end

  defp value(_type, _value), do: :bad_params

  # `<updated_at>:<session id>`, a time that SQLite can bind (0 to 2^63 - 1),
  # parsed and only compared.
  defp cursor(cursor) do
    case Regex.run(~r/\A(0|[1-9][0-9]{0,18}):([A-Za-z0-9_-]{12})\z/, cursor) do
      [_, time, id] -> bounded(String.to_integer(time), id)
      nil -> :bad_params
    end
  end

  defp bounded(at, id) when at <= @max_cursor_time, do: {:ok, {at, id}}
  defp bounded(_at, _id), do: :bad_params

  # `at`: from now to 366 days on.
  defp at(at) do
    now = System.os_time(:second)

    if at >= now and at <= now + @max_ahead_s, do: {:ok, at}, else: :bad_params
  end

  defp labels(labels) when is_list(labels) do
    set = Enum.uniq(labels)

    if length(set) <= @max_labels and Enum.all?(set, &text?(&1, 1, @max_label_bytes)),
      do: {:ok, set},
      else: :bad_params
  end

  defp labels(_labels), do: :bad_params

  # The first 1,024 bytes of a text, cut on a UTF-8 boundary, for the
  # `prompt` of a record: the caller cuts it, so no Hub call carries more of
  # a text (Store schema).
  def cut(text) do
    head = binary_part(text, 0, min(byte_size(text), @max_record_prompt_bytes))
    Enum.find([head | trims(head)], &String.valid?/1)
  end

  defp trims(head) do
    for n <- 1..3, byte_size(head) > n, do: binary_part(head, 0, byte_size(head) - n)
  end

  # `min` to `max` bytes of UTF-8 with no control character (C0, DEL, C1).
  def text?(text, min, max) do
    is_binary(text) and byte_size(text) in min..max//1 and String.valid?(text) and
      not String.match?(text, ~r/[\x{0}-\x{1f}\x{7f}-\x{9f}]/u)
  end
end
