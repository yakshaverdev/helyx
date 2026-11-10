defmodule Helyx.Hub.Params do
  @moduledoc false
  # The params of the `hub.records.*`, `hub.projects.*`, and `hub.schedules.*` operations, checked
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
  # The bounds of a schedule (Bounds, #870).
  @max_schedule_prompt_bytes 16_384
  @max_ahead_s 31_622_400
  # The bounds of an event subscription (Bounds, #921).
  @max_template_bytes 16_384
  @max_hook_label_bytes 64
  @placeholder "{{payload}}"
  @every_s 300..2_678_400
  # The bound of the `prompt` of a record (Store schema).
  @max_record_prompt_bytes 1_024
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

  # A schedule (decision 11): `at` from now to 366 days on, `every` absent
  # or a period of 300 s to 31 days, and a prompt of UTF-8; one over 16,384
  # bytes is `:text_too_large`, after every other param passed.
  def check("hub.schedules.create", %{"session" => id, "at" => at, "prompt" => prompt} = params)
      when is_binary(id) and is_integer(at) and is_binary(prompt) do
    every = Map.get(params, "every")

    cond do
      not schedule?(params, at, every, prompt) -> :bad_params
      byte_size(prompt) > @max_schedule_prompt_bytes -> :text_too_large
      true -> {:ok, {id, %{at: at, every: every, prompt: prompt}}}
    end
  end

  def check("hub.schedules.list", params) when map_size(params) == 0, do: {:ok, nil}

  def check("hub.schedules.list", %{"session" => id} = params)
      when map_size(params) == 1 and is_binary(id),
      do: {:ok, id}

  def check("hub.schedules.delete", %{"schedule" => id} = params)
      when map_size(params) == 1 and is_binary(id),
      do: {:ok, id}

  # An event subscription (decision 17): a template of 1 to 16,384 bytes of
  # UTF-8 that holds `{{payload}}` exactly once, and an optional label of 0
  # to 64 bytes with no control character. A template over the byte bound is
  # `:text_too_large`; a missing or repeated placeholder is `:bad_params`.
  def check("hub.subscriptions.create", %{"session" => id, "prompt" => template} = params)
      when is_binary(id) and is_binary(template) do
    label = Map.get(params, "label", "")

    cond do
      not subscription?(params, template, label) -> :bad_params
      byte_size(template) > @max_template_bytes -> :text_too_large
      true -> {:ok, {id, %{template: template, label: label}}}
    end
  end

  def check("hub.subscriptions.list", params) when map_size(params) == 0, do: {:ok, nil}

  def check("hub.subscriptions.list", %{"session" => id} = params)
      when map_size(params) == 1 and is_binary(id),
      do: {:ok, id}

  def check("hub.subscriptions.delete", %{"subscription" => id} = params)
      when map_size(params) == 1 and is_binary(id),
      do: {:ok, id}

  def check(_op, _params), do: :bad_params

  defp schedule?(params, at, every, prompt) do
    Enum.all?(Map.keys(params), &(&1 in ~w(session at every prompt))) and at?(at) and
      every?(params, every) and prompt != "" and String.valid?(prompt)
  end

  defp subscription?(params, template, label) do
    Enum.all?(Map.keys(params), &(&1 in ~w(session prompt label))) and
      text?(label, 0, @max_hook_label_bytes) and
      template != "" and String.valid?(template) and
      length(String.split(template, @placeholder)) == 2
  end

  defp at?(at) do
    now = System.os_time(:second)
    at >= now and at <= now + @max_ahead_s
  end

  # `every` absent, or a period; a key that is present is never null.
  defp every?(params, every),
    do: not Map.has_key?(params, "every") or (is_integer(every) and every in @every_s)

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
