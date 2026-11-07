defmodule Helyx.Session.ToolRegistry do
  @moduledoc false
  # The tools of one session: its fixed tools, and the groups of entries
  # that its tool sources put (docs/features/mcp-client.md, "Interface
  # changes"). Pure: the session keeps it, sends the tool map to the hands,
  # and emits the notices that each change gives.
  #
  # `fixed` holds each fixed tool by name: its module, its spec, and its
  # flag of `Helyx.Tool.concurrent/1`. `groups` holds each group by
  # `{source, group}`: its state (`:starting`, `:ready`, or `{:error,
  # text}`) and its entries. `announced` holds the groups of each source
  # that announced and kept, sorted by name. `sources` holds the tool
  # sources that the session starts after its hands. `activated` holds the
  # activated deferred names in drop order: the front leaves first.
  # `version` counts the changes of the groups (`deferred/2`), and
  # `waiters` holds the callers of `Helyx.Tool.deferred/2` that wait for
  # the next one, with their timers. `specs` and `tools` follow from
  # `fixed`, `groups`, and `activated` at each change (`derive/1`): the
  # specs that a provider call gets, and each tool by name with its module,
  # for the hands, and its concurrent flag, for the tool queue.

  alias Helyx.Session.Input

  defstruct fixed: %{},
            groups: %{},
            announced: %{},
            sources: [],
            activated: [],
            version: 0,
            waiters: %{},
            specs: [],
            tools: %{}

  @type t :: %__MODULE__{
          fixed: %{String.t() => {module(), Helyx.Tool.spec(), boolean()}},
          groups: %{{module(), String.t()} => %{state: term(), entries: [map()]}},
          announced: %{module() => [String.t()]},
          sources: [module()],
          activated: [String.t()],
          version: non_neg_integer(),
          waiters: %{reference() => {GenServer.from(), reference()}},
          specs: [Helyx.Tool.spec()],
          tools: %{String.t() => {module(), boolean()}}
        }

  # The bounds of the "Bounds" table of docs/features/mcp-client.md.
  @max_groups 64
  @max_group_bytes 64
  @max_entries 1_024
  @max_description_bytes 4_096
  @max_parameters_bytes 16_384
  @max_text_bytes 2_000
  @max_activated 32
  @max_activated_bytes 65_536

  def max_activated, do: @max_activated

  def new(tools, concurrent, sources) do
    fixed =
      Map.new(tools, fn {tool, spec} -> {spec.name, {tool, spec, spec.name in concurrent}} end)

    derive(%__MODULE__{fixed: fixed, sources: sources})
  end

  # The tool map of the hands: each tool module by name.
  def modules(%__MODULE__{} = registry),
    do: Map.new(registry.tools, fn {name, {tool, _concurrent?}} -> {name, tool} end)

  # The specs of the fixed tools, the direct entries, and the activated
  # deferred entries, sorted by name, and each tool by name: a source entry
  # runs on its source's module and is never concurrent.
  defp derive(registry) do
    fixed = for {_name, {_tool, spec, _concurrent?}} <- registry.fixed, do: spec
    activated = MapSet.new(registry.activated)

    entries =
      for {_key, %{entries: entries}} <- registry.groups,
          entry <- entries,
          entry.exposure == :direct or MapSet.member?(activated, entry.name),
          do: spec(entry)

    fixed_tools =
      Map.new(registry.fixed, fn {name, {tool, _spec, concurrent?}} ->
        {name, {tool, concurrent?}}
      end)

    tools =
      for {{source, _group}, %{entries: entries}} <- registry.groups,
          entry <- entries,
          into: fixed_tools,
          do: {entry.name, {source, false}}

    %{registry | specs: Enum.sort_by(fixed ++ entries, & &1.name), tools: tools}
  end

  # The first announce of `source`: each group starts as `:starting`. A
  # call that is not a proper list of distinct group names of 1 to 64 bytes
  # of UTF-8, or a second call, is a contract break: `:error`. Past the cap
  # of the session, the first groups by name order are kept.
  def announce(%__MODULE__{} = registry, source, groups) do
    if is_map_key(registry.announced, source) or not group_names?(groups) do
      :error
    else
      room = @max_groups - map_size(registry.groups)
      {kept, left} = groups |> Enum.sort() |> Enum.split(room)
      added = Map.new(kept, &{{source, &1}, %{state: :starting, entries: []}})

      registry = %{
        registry
        | groups: Map.merge(registry.groups, added),
          announced: Map.put(registry.announced, source, kept)
      }

      {:ok, changed(registry), left_out(left), {:ok, kept}}
    end
  end

  defp group_names?(groups) do
    is_list(groups) and not List.improper?(groups) and
      Enum.all?(
        groups,
        &(is_binary(&1) and byte_size(&1) in 1..@max_group_bytes and String.valid?(&1))
      ) and
      length(Enum.uniq(groups)) == length(groups)
  end

  defp left_out([]), do: []

  # The names that fit in the notice and a count of all: the work is
  # bounded by the cut, not by the list.
  defp left_out(groups) do
    head = "#{length(groups)} tool groups over the cap of #{@max_groups} were left out: "
    # The first name has no separator: 2 bytes of room more.
    room = @max_text_bytes - byte_size(head) + 2
    [cap(head <> Enum.join(fitting(groups, room, []), ", "))]
  end

  # A whole name or none: the list stops at the first name that does not
  # fit with its separator.
  defp fitting([name | rest], room, acc) when byte_size(name) + 2 <= room,
    do: fitting(rest, room - byte_size(name) - 2, [name | acc])

  defp fitting(_names, _room, acc), do: Enum.reverse(acc)

  # A put of a group that the source announced and kept. `:starting` and
  # `{:error, text}` remove the group's entries; `{:ok, entries}` replaces
  # them with the entries that pass the checks. Any other value, or a group
  # that the source did not keep, is a contract break: `:error`.
  def put(%__MODULE__{} = registry, source, group, value) do
    with true <- group in Map.get(registry.announced, source, []),
         {:ok, registry, notices} <- put_group(registry, {source, group}, value) do
      {:ok, registry, notices, :ok}
    else
      _error -> :error
    end
  end

  defp put_group(registry, key, :starting),
    do: {:ok, set(registry, key, :starting, []), []}

  defp put_group(registry, key, {:error, text}) when is_binary(text),
    do: {:ok, set(registry, key, {:error, cap(text)}, []), []}

  # The cap counts the entries that pass the checks.
  defp put_group(registry, {_source, group} = key, {:ok, entries}) when is_list(entries) do
    if List.improper?(entries) do
      :error
    else
      {kept, rejected} = check(entries, taken(registry, key), [], [])

      if length(kept) + others(registry, key) > @max_entries do
        text = "the session holds at most #{@max_entries} source tools"
        {:ok, set(registry, key, {:error, text}, []), [cap("tool group #{group}: " <> text)]}
      else
        {:ok, set(registry, key, :ready, kept), rejected(group, rejected)}
      end
    end
  end

  defp put_group(_registry, _key, _value), do: :error

  defp set(registry, key, state, entries),
    do:
      changed(%{
        registry
        | groups: Map.put(registry.groups, key, %{state: state, entries: entries})
      })

  # A change of the groups: the next version, and the cap of the activated
  # list, whose names can hold more spec bytes now.
  defp changed(registry) do
    registry = %{registry | version: registry.version + 1}
    derive(%{registry | activated: capped(registry, registry.activated)})
  end

  defp others(registry, key),
    do: Enum.sum(for {other, group} <- registry.groups, other != key, do: length(group.entries))

  # The names that an entry of `key` cannot take: the fixed tools and the
  # entries of every other group. The group's own entries are replaced.
  defp taken(registry, key) do
    entries =
      for {other, group} <- registry.groups, other != key, entry <- group.entries, do: entry.name

    MapSet.new(Map.keys(registry.fixed) ++ entries)
  end

  defp check([], _taken, kept, rejected), do: {Enum.reverse(kept), Enum.reverse(rejected)}

  defp check([entry | rest], taken, kept, rejected) do
    case entry_error(entry, taken) do
      nil ->
        entry = Map.take(entry, [:name, :description, :parameters, :exposure])
        check(rest, MapSet.put(taken, entry.name), [entry | kept], rejected)

      reason ->
        check(rest, taken, kept, [{label(entry), reason} | rejected])
    end
  end

  defp entry_error(
         %{name: name, description: description, parameters: parameters, exposure: exposure},
         taken
       ) do
    cond do
      not Helyx.Tool.name?(name) ->
        "a name outside the tool name rule"

      MapSet.member?(taken, name) ->
        "the name is taken"

      not description?(description) ->
        "a description that is not UTF-8 of at most #{@max_description_bytes} bytes"

      not parameters?(parameters) ->
        "parameters that are not a JSON object schema of at most #{@max_parameters_bytes} bytes"

      exposure not in [:direct, :deferred] ->
        "an exposure other than direct or deferred"

      true ->
        nil
    end
  end

  defp entry_error(_entry, _taken), do: "not an entry"

  defp description?(text),
    do: is_binary(text) and byte_size(text) <= @max_description_bytes and String.valid?(text)

  defp parameters?(%{"type" => "object"} = parameters),
    do: Input.json_object(parameters, @max_parameters_bytes) == :ok

  defp parameters?(_parameters), do: false

  defp label(%{name: name}), do: if(Helyx.Tool.name?(name), do: name, else: "an entry")
  defp label(_entry), do: "an entry"

  defp rejected(_group, []), do: []

  defp rejected(group, rejected) do
    reasons = Enum.map_join(rejected, "; ", fn {label, reason} -> "#{label}: #{reason}" end)
    [cap("tool group #{group}: #{length(rejected)} tools were left out: " <> reasons)]
  end

  # The end of a source: its groups leave, one notice each.
  def remove(%__MODULE__{} = registry, source) do
    {gone, groups} =
      Map.split_with(registry.groups, fn {{owner, _group}, _} -> owner == source end)

    notices =
      for {{_source, group}, _} <- Enum.sort(gone),
          do: cap("tool group #{group} ended: its tools left the session")

    {changed(%{registry | groups: groups, announced: Map.delete(registry.announced, source)}),
     notices}
  end

  # `names`, in rank order, best first: the registered deferred names among
  # them move to the end of the activated list in reverse rank, so the best
  # leaves last; then the cap. A name that is no registered deferred tool
  # is ignored.
  def activate(%__MODULE__{} = registry, names) do
    deferred = Map.new(deferred(registry))
    batch = names |> Enum.uniq() |> Enum.filter(&is_map_key(deferred, &1))
    list = (registry.activated -- batch) ++ Enum.reverse(batch)
    derive(%{registry | activated: capped(registry, list)})
  end

  # The list of a resume: its names stay until the cap after a put.
  def restore(%__MODULE__{} = registry, activated), do: derive(%{registry | activated: activated})

  # Drops from the front of `list`, the oldest first, while it holds more
  # than 32 names or more than 65,536 bytes of the spec JSON that the
  # registry holds for them; a name with no entry counts no byte. Only the
  # names of `list` are encoded, not every deferred entry.
  defp capped(registry, list) do
    deferred = Map.new(deferred(registry))
    sizes = Map.new(list, &{&1, spec_bytes(deferred[&1])})
    drop_front(list, length(list), Enum.sum_by(list, &sizes[&1]), sizes)
  end

  defp drop_front([name | rest], count, bytes, sizes)
       when count > @max_activated or bytes > @max_activated_bytes,
       do: drop_front(rest, count - 1, bytes - sizes[name], sizes)

  defp drop_front(list, _count, _bytes, _sizes), do: list

  defp spec_bytes(nil), do: 0

  defp spec_bytes(entry) do
    {:ok, bytes} = Helyx.Message.encoded_size(spec(entry))
    bytes
  end

  defp spec(entry), do: Map.take(entry, [:name, :description, :parameters])

  # Each registered deferred entry by name, with its group.
  defp deferred(registry) do
    for {{_source, group}, %{entries: entries}} <- registry.groups,
        %{exposure: :deferred} = entry <- entries,
        do: {entry.name, Map.put(entry, :group, group)}
  end

  # The answer of `Helyx.Tool.deferred/2`: the version, the deferred entries
  # with their groups, the activated names, the state of each group, and
  # the label of each source that has not announced (`pending`).
  def view(%__MODULE__{} = registry, pending) do
    entries = for {_name, entry} <- deferred(registry), do: Map.delete(entry, :exposure)

    groups =
      for {{_source, group}, %{state: state}} <- Enum.sort(registry.groups),
          do: %{group: group, state: state}

    %{
      version: registry.version,
      entries: entries,
      activated: registry.activated,
      groups: groups,
      pending: pending
    }
  end

  # A notice is valid UTF-8 of at most 2,000 bytes.
  defp cap(text) do
    text = String.replace_invalid(text)
    text |> binary_part(0, min(@max_text_bytes, byte_size(text))) |> String.replace_invalid("")
  end
end
