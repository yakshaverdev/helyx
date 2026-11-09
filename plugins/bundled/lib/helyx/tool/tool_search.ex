defmodule Helyx.Tool.ToolSearch do
  @moduledoc """
  `tool_search`: finds the deferred tools of the session's tool sources,
  such as the tools of MCP servers, and activates the matches, so the next
  model call can call them (`Helyx.Tool.deferred/2`, `Helyx.Tool.activate/1`).

  It ranks the deferred entries of the ready groups by BM25 over the words of
  the name, the description, and the parameter names and descriptions; an
  entry whose name is a word of the query ranks first. An empty query
  activates nothing and lists the groups with their state and tool count.
  With no match while a group is starting or a source is pending, it waits
  for each change and ranks again, at most 30,000 ms from its first look. The
  answer names the matches that the session kept, those it left out, the
  groups that are still starting, and the failed groups. See
  `docs/features/mcp-client.md`.
  """

  @behaviour Helyx.Tool

  @max_query_bytes 1_024
  @max_limit 10
  @default_limit 5
  # The bytes of a description in the answer.
  @max_description_bytes 1_024
  # The bytes of a failure text, so the answer stays below the result cut.
  @max_failure_bytes 512
  # The wait of a search with no match, from its first look.
  @wait_ms 30_000
  # The common BM25 parameters: term frequency saturation and length norm.
  @k1 1.2
  @b 0.75

  @impl true
  def name, do: "tool_search"

  @impl true
  def description do
    "Search the tools that are not loaded yet, such as the tools of MCP servers, and load the " <>
      "matches: they are callable from the next model call. Give words that describe the " <>
      "task, or tool names. An empty query lists the tool groups with their state."
  end

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "query" => %{
          "type" => "string",
          "description" => "Words that describe the tool, or tool names; empty to list the groups"
        },
        "limit" => %{
          "type" => "integer",
          "description" =>
            "The most tools to load, 1 to #{@max_limit} (default #{@default_limit})"
        }
      },
      "required" => ["query"]
    }
  end

  @impl true
  def run(%{"query" => query} = args, _cwd) when is_binary(query) do
    with :ok <- check_query(query),
         {:ok, limit} <- limit(args) do
      if String.trim(query) == "",
        do: {:ok, groups_text(Helyx.Tool.deferred(nil, 0))},
        else: search(query, limit)
    end
  end

  def run(_args, _cwd), do: {:error, "tool_search needs a query, a string"}

  defp check_query(query) when byte_size(query) <= @max_query_bytes, do: :ok
  defp check_query(_query), do: {:error, "the query has more than #{@max_query_bytes} bytes"}

  defp limit(%{"limit" => limit}) when is_integer(limit) and limit in 1..@max_limit,
    do: {:ok, limit}

  defp limit(%{"limit" => nil}), do: {:ok, @default_limit}
  defp limit(%{"limit" => _}), do: {:error, "limit is an integer from 1 to #{@max_limit}"}
  defp limit(_args), do: {:ok, @default_limit}

  defp search(query, limit) do
    deadline = System.monotonic_time(:millisecond) + @wait_ms
    look(Helyx.Tool.deferred(nil, 0), parse(query, limit), deadline, %{})
  end

  # Ranks the entries of `view`. `known` holds the counts of the last look,
  # so a look after a change reads only the entries that are new.
  defp look(view, query, deadline, known) do
    counts = counts(view.entries, query.terms, known)

    case best(counts, query) do
      [] -> wait(view, query, deadline, counts)
      matches -> load(matches)
    end
  end

  # No match: while a group is starting or a source is pending, waits for
  # the next change within the deadline and looks again.
  defp wait(view, query, deadline, counts) do
    time_left = deadline - System.monotonic_time(:millisecond)

    if starting?(view) and time_left > 0 do
      case Helyx.Tool.deferred(view.version, time_left) do
        %{version: version} = next when version != view.version ->
          look(next, query, deadline, counts)

        # The same version: the wait ended, or 32 callers wait and the
        # session answered at once. Either way the matches stay none.
        same ->
          no_match(same)
      end
    else
      no_match(view)
    end
  end

  defp starting?(view),
    do: view.pending != [] or Enum.any?(view.groups, &(&1.state == :starting))

  defp no_match(view), do: {:ok, lines(["No tool matches the query." | state_lines(view)])}

  # A match is loaded when one view after the activation holds it in its
  # entries and in its activated list: the list keeps the names of a group
  # that emptied, and a put after the activation can drop a name by the
  # cap, so the list that `activate/1` returns does not show it.
  defp load(matches) do
    Helyx.Tool.activate(Enum.map(matches, & &1.name))
    view = Helyx.Tool.deferred(nil, 0)
    activated = MapSet.new(view.activated)

    descriptions =
      for %{name: name} = entry <- view.entries,
          name in activated,
          into: %{},
          do: {name, entry.description}

    {kept, left_out} = Enum.split_with(matches, &is_map_key(descriptions, &1.name))

    {:ok,
     lines(
       Enum.map(kept, &"#{&1.name}: #{one_line(descriptions[&1.name])}") ++
         joined(
           "Not loaded, by the cap of loaded tools or a change of their group: ",
           Enum.map(left_out, & &1.name)
         ) ++
         state_lines(view) ++ ["The listed tools are callable from the next model call."]
     )}
  end

  defp state_lines(view) do
    starting = for %{group: group, state: :starting} <- view.groups, do: flat(group)

    joined("Groups still starting: ", starting) ++
      pending_line(view) ++
      for(
        %{group: group, state: {:error, text}} <- view.groups,
        do:
          "Group #{flat(group)} failed: #{Helyx.Text.cap(flat(text), @max_failure_bytes, :head)}"
      )
  end

  # The labels of pending sources are `inspect/1` output, on one line.
  defp pending_line(view), do: joined("Tool sources still starting: ", view.pending)

  defp joined(_head, []), do: []
  defp joined(head, names), do: [head <> Enum.join(names, ", ") <> "."]

  defp groups_text(%{groups: [], pending: []}), do: "No tool groups."

  defp groups_text(view), do: lines(Enum.map(view.groups, &group_line/1) ++ pending_line(view))

  defp group_line(%{group: group, state: state, tools: tools}),
    do: "#{flat(group)}: #{state_text(state, tools)}"

  defp state_text(:ready, 1), do: "ready, 1 tool"
  defp state_text(:ready, tools), do: "ready, #{tools} tools"
  defp state_text(:starting, _tools), do: "starting"

  defp state_text({:error, text}, _tools),
    do: "failed: #{Helyx.Text.cap(flat(text), @max_failure_bytes, :head)}"

  defp lines(lines), do: Enum.join(lines, "\n")

  defp one_line(text), do: text |> flat() |> Helyx.Text.cap(@max_description_bytes, :head)

  # A text of a source on one line of the answer: each run of line breaks,
  # of any kind that Unicode names, becomes a space.
  defp flat(text), do: String.replace(text, ~r/\R+/u, " ")

  @doc false
  # The entries that match `query`, best first, at most `limit` (`best/2`).
  @spec rank([map()], String.t(), pos_integer()) :: [map()]
  def rank(entries, query, limit) do
    query = parse(query, limit)
    entries |> counts(query.terms, %{}) |> best(query)
  end

  # A query: its words split at whitespace, each of which can name an entry;
  # its terms for BM25; and the limit.
  defp parse(query, limit),
    do: %{names: Enum.uniq(String.split(query)), terms: MapSet.new(words(query)), limit: limit}

  # By entry, the count of each query term that the entry holds and the
  # count of its words; an entry that `known` holds keeps its counts.
  defp counts(entries, terms, known) do
    Map.new(entries, fn entry ->
      {entry, Map.get_lazy(known, entry, fn -> count(entry, terms) end)}
    end)
  end

  defp count(entry, terms) do
    words = words(entry.name) ++ words(entry.description) ++ schema_words(entry.parameters)
    {words |> Enum.filter(&MapSet.member?(terms, &1)) |> Enum.frequencies(), length(words)}
  end

  # Each entry whose name is a word of the query, in the order of the query;
  # then each other entry with a positive BM25 score, highest first, then by
  # name; at most the limit.
  defp best(counts, query) do
    by_name = Map.new(counts, fn {entry, _counts} -> {entry.name, entry} end)
    exact = for name <- query.names, is_map_key(by_name, name), do: by_name[name]
    named = MapSet.new(query.names)

    ranked =
      counts
      |> scores()
      |> Enum.reject(fn {entry, _score} -> MapSet.member?(named, entry.name) end)
      |> Enum.sort_by(fn {entry, score} -> {-score, entry.name} end)
      |> Enum.map(&elem(&1, 0))

    Enum.take(exact ++ ranked, query.limit)
  end

  # The BM25 score of each entry that holds a query term, over all the
  # entries. Each term that an entry holds adds a positive score, so these
  # are the entries with a positive score.
  defp scores(counts) do
    total = map_size(counts)
    lengths = Enum.sum_by(counts, fn {_entry, {_freq, length}} -> length end)
    # Each count at least 1, so the mean length divides by no zero.
    average = max(lengths, 1) / max(total, 1)

    with_term =
      counts
      |> Enum.flat_map(fn {_entry, {freq, _length}} -> Map.keys(freq) end)
      |> Enum.frequencies()

    for {entry, {freq, length}} <- counts, map_size(freq) > 0 do
      norm = @k1 * (1 - @b + @b * length / average)

      score =
        Enum.sum_by(freq, fn {term, f} ->
          n = with_term[term]
          :math.log(1 + (total - n + 0.5) / (n + 0.5)) * f * (@k1 + 1) / (f + norm)
        end)

      {entry, score}
    end
  end

  # The words of a text: runs of letters and digits, split where a lower
  # case letter meets an upper case one, in lower case.
  defp words(text) do
    text
    |> String.split(~r/[^\p{L}\p{N}]+|(?<=\p{Ll})(?=\p{Lu})/u, trim: true)
    |> Enum.map(&String.downcase/1)
  end

  # The words of the property names and the descriptions of a JSON schema,
  # at any depth.
  defp schema_words(%{} = schema) do
    Enum.flat_map(schema, fn
      {"properties", %{} = properties} ->
        Enum.flat_map(properties, fn {name, value} -> words(name) ++ schema_words(value) end)

      {"description", text} when is_binary(text) ->
        words(text)

      {_key, value} ->
        schema_words(value)
    end)
  end

  defp schema_words(list) when is_list(list), do: Enum.flat_map(list, &schema_words/1)
  defp schema_words(_value), do: []
end
