defmodule Helyx.Hub.Store.SQLite.Tables do
  @moduledoc false
  # The columns of each table of the store, stated once, in the order of the
  # row of that table (`docs/features/hub.md`, "Store schema"). The `SELECT`,
  # the `INSERT` of a full row, and the map of a result row are built from
  # the list, so a column costs one entry here and one in the schema.

  @columns %{
    users: ~w(id name created_at)a,
    tokens: ~w(id user_id name key created_at)a,
    projects: ~w(id owner name created_at)a,
    records: ~w(session_id owner project_id title cwd model prompt active_at visibility archived
         created_at updated_at)a,
    labels: ~w(session_id label)a,
    schedules: ~w(id owner session_id prompt at every run delivery_id due_at next_try_at last_at
         last_outcome created_at subscription_id)a,
    subscriptions: ~w(id owner session_id template label secret created_at last_at last_outcome)a,
    peers: ~w(name kind public_key created_at)a
  }

  # The conversion of each column that the store returns as another type than
  # the file holds: `archived` is 0 or 1 in the file and a boolean in a record.
  # `visibility` and `last_outcome` stay the text of the schema and of the
  # wire, and the `key` of a token the blob of its hash.
  @conversions %{archived: :boolean}

  @doc "The columns of `table`, in the order of its rows."
  def columns(table), do: Map.fetch!(@columns, table)

  @doc "The column text of a `SELECT`, each name with `prefix`."
  def select(table, prefix \\ ""),
    do: Enum.map_join(columns(table), ", ", &(prefix <> Atom.to_string(&1)))

  @doc "The `SELECT` of every column of `table`."
  def select_sql(table), do: "SELECT #{select(table)} FROM #{table}"

  @doc "The `INSERT` of a full row of `table`, with one placeholder for each column."
  def insert(table) do
    marks = Enum.map_join(1..length(columns(table)), ", ", &"?#{&1}")
    "INSERT INTO #{table} (#{select(table)}) VALUES (#{marks})"
  end

  @doc "The row of `table` as a map, `values` in the order of its columns."
  def row(table, values), do: table |> columns() |> Enum.zip(values) |> Map.new(&cell/1)

  defp cell({column, value}), do: {column, convert(Map.get(@conversions, column), value)}

  defp convert(:boolean, value), do: value == 1
  defp convert(nil, value), do: value
end
