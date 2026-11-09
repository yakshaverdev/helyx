defmodule Helyx.Hub.Params do
  @moduledoc false
  # The params of the `hub.records.*` and `hub.projects.*` operations, checked
  # in the caller at the entry of Hub before it reads any object that they
  # name (`docs/features/hub.md`, decision 5, "The order of the checks";
  # Bounds). `check/2` answers `{:ok, value}` or `:bad_params`.

  @max_title_bytes 256
  @max_labels 16
  @max_label_bytes 64
  @max_project_name_bytes 128
  @max_query_bytes 256
  @max_limit 256
  @default_limit 50
  # The largest integer that SQLite binds.
  @max_cursor_time 2 ** 63 - 1

  def check(op, %{"session" => id} = params)
      when op in ~w(hub.records.get hub.records.delete) and map_size(params) == 1 and
             is_binary(id),
      do: {:ok, id}

  # At least one field; `labels` replaces the set, with duplicates removed;
  # `project: null` clears the project.
  def check("hub.records.update", %{"session" => id} = params)
      when map_size(params) > 1 and is_binary(id) do
    with {:ok, changes} <- fields(Map.delete(params, "session"), %{}, &change/2),
         do: {:ok, {id, changes}}
  end

  def check("hub.records.search", params), do: fields(params, %{limit: @default_limit}, &filter/2)

  def check("hub.projects.create", %{"name" => name} = params) when map_size(params) == 1,
    do: name(name)

  def check("hub.projects.update", %{"project" => id, "name" => name} = params)
      when map_size(params) == 2 and is_binary(id) do
    with {:ok, name} <- name(name), do: {:ok, {id, name}}
  end

  def check("hub.projects.delete", %{"project" => id} = params)
      when map_size(params) == 1 and is_binary(id),
      do: {:ok, id}

  def check(_op, _params), do: :bad_params

  # Each param through `check`, which answers `{:ok, field, value}` or
  # `:bad_params`, and rejects an unknown key.
  defp fields(params, acc, check) do
    Enum.reduce_while(params, {:ok, acc}, fn {key, value}, {:ok, acc} ->
      case check.(key, value) do
        {:ok, field, checked} -> {:cont, {:ok, Map.put(acc, field, checked)}}
        :bad_params -> {:halt, :bad_params}
      end
    end)
  end

  defp change("title", title) do
    if text?(title, 0, @max_title_bytes), do: {:ok, :title, title}, else: :bad_params
  end

  defp change("labels", labels), do: labels(labels)
  defp change("visibility", v) when v in ["private", "hub"], do: {:ok, :visibility, v}
  defp change("project", nil), do: {:ok, :project_id, nil}
  defp change("project", id) when is_binary(id), do: {:ok, :project_id, id}
  defp change("archived", a) when is_boolean(a), do: {:ok, :archived, a}
  defp change(_key, _value), do: :bad_params

  # The filters of a search; `after` is `<updated_at>:<session id>`, a time
  # that SQLite can bind (0 to 2^63 - 1), parsed and only compared.
  defp filter("query", q) when is_binary(q) and byte_size(q) <= @max_query_bytes,
    do: {:ok, :query, q}

  defp filter("labels", labels), do: labels(labels)
  defp filter("project", id) when is_binary(id), do: {:ok, :project_id, id}
  defp filter("archived", a) when is_boolean(a), do: {:ok, :archived, a}
  defp filter("mine", m) when is_boolean(m), do: {:ok, :mine, m}
  defp filter("limit", n) when is_integer(n) and n in 1..@max_limit, do: {:ok, :limit, n}

  defp filter("after", cursor) when is_binary(cursor) do
    case Regex.run(~r/\A(0|[1-9][0-9]{0,18}):([A-Za-z0-9_-]{12})\z/, cursor) do
      [_, at, id] -> at |> String.to_integer() |> cursor(id)
      nil -> :bad_params
    end
  end

  defp filter(_key, _value), do: :bad_params

  defp cursor(at, id) when at <= @max_cursor_time, do: {:ok, :after, {at, id}}
  defp cursor(_at, _id), do: :bad_params

  defp labels(labels) when is_list(labels) do
    set = Enum.uniq(labels)

    if length(set) <= @max_labels and Enum.all?(set, &text?(&1, 1, @max_label_bytes)),
      do: {:ok, :labels, set},
      else: :bad_params
  end

  defp labels(_labels), do: :bad_params

  defp name(name) do
    if text?(name, 1, @max_project_name_bytes), do: {:ok, name}, else: :bad_params
  end

  # `min` to `max` bytes of UTF-8 with no control character (C0, DEL, C1).
  def text?(text, min, max) do
    is_binary(text) and byte_size(text) in min..max//1 and String.valid?(text) and
      not String.match?(text, ~r/[\x{0}-\x{1f}\x{7f}-\x{9f}]/u)
  end
end
