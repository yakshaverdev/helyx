defmodule Helyx.Session.File.Branch do
  @moduledoc false
  # The branch rules of the session file (ADR 0001). `newest/1` takes the
  # entries in file order and gives the newest leaf and its checked branch,
  # header first. The other public functions take that checked branch. The
  # functions do no I/O.

  alias Helyx.Message

  @no_header "the first entry is not a header"

  def newest(entries) do
    with {:ok, leaf, branch} <- newest_branch(entries),
         :ok <- check_entries(branch) do
      {:ok, leaf, branch}
    end
  end

  # The writer only produces a header on line one, then messages, model
  # changes, and harness sessions, every one with an id, every model field a
  # string. Anything else on the branch is on-disk corruption, never
  # silently dropped, and never laundered by a later entry that overrides
  # it. An entry on no branch is never read, so its shape is not checked.
  # The harness fields are an optional label: harness_sessions/2 drops a
  # bad one. newest_branch/1 put on the branch only entries with a string
  # id.
  defp check_entries([%{"type" => "session", "model" => model} | rest]) when is_binary(model) do
    case Enum.find(rest, &(not valid_entry?(&1))) do
      nil -> :ok
      bad -> {:error, {:invalid_file, "entry the writer never produces: #{inspect(bad["type"])}"}}
    end
  end

  defp check_entries(_branch), do: {:error, {:invalid_file, @no_header}}

  defp valid_entry?(%{"type" => "message"}), do: true
  defp valid_entry?(%{"type" => "model_change", "model" => model}), do: is_binary(model)
  defp valid_entry?(%{"type" => "harness_session"}), do: true
  defp valid_entry?(_entry), do: false

  # The branch of the newest leaf, header first. The index holds each entry
  # in file order, so a parent is always an earlier entry, the walk from a
  # leaf ends at the header, and a cycle cannot form. The header is the root
  # whatever its own parent_id says: the walk stops at its id. A value in
  # the index is a rooted entry, :unrooted, or {:shared, entry}: an id that
  # a later entry repeats. Before the repeat a child can only mean the
  # first entry, so the branch through it stands; after it, a child cannot
  # tell the two apart and is on no branch, as is the repeat itself.
  #
  # The leaf is the newest rooted entry whose id is not shared: the next
  # append names the leaf as its parent, so a shared leaf would put all new
  # work on no branch. When the header id is shared and no other entry can
  # be the leaf, no entry can take a child, and the file is refused.
  defp newest_branch([%{"id" => root} = header | rest] = entries) when is_binary(root) do
    index = Enum.reduce(rest, %{root => header}, &index_entry/2)

    case Enum.find(Enum.reverse(entries), &match?(%{}, Map.get(index, &1["id"]))) do
      %{"id" => leaf} -> {:ok, leaf, walk(index, root, leaf, [])}
      nil -> {:error, {:invalid_file, "a repeat of the header id leaves no entry to resume"}}
    end
  end

  defp newest_branch(_entries), do: {:error, {:invalid_file, @no_header}}

  # An entry with no string id has no identity: no entry can name it as
  # its parent, so it is on no branch.
  defp index_entry(%{"id" => id}, index) when is_map_key(index, id),
    do: Map.update!(index, id, &shared/1)

  defp index_entry(%{"id" => id} = entry, index) when is_binary(id) do
    parent = entry["parent_id"]

    case index do
      %{^parent => %{}} -> Map.put(index, id, entry)
      _unrooted -> Map.put(index, id, :unrooted)
    end
  end

  defp index_entry(_entry, acc), do: acc

  defp shared(%{} = entry), do: {:shared, entry}
  defp shared(other), do: other

  defp walk(index, root, root, branch), do: [entry_at(index, root) | branch]

  defp walk(index, root, id, branch) do
    entry = entry_at(index, id)
    walk(index, root, entry["parent_id"], [entry | branch])
  end

  defp entry_at(index, id) do
    case Map.fetch!(index, id) do
      {:shared, entry} -> entry
      entry -> entry
    end
  end

  # The last model change wins, else the header's model. Both are strings:
  # check_entries validated every entry before this runs.
  def current_model(header, entries) do
    Enum.reduce(entries, header["model"], fn
      %{"type" => "model_change"} = entry, _acc -> entry["model"]
      _entry, acc -> acc
    end)
  end

  # The last harness session entry of each provider wins: a lost harness
  # session is followed by a new entry for the same provider. Each keeps the
  # number of messages before it, so the session can tell whether the
  # harness session has made a message since. The label is optional: with
  # none, the provider starts a fresh harness session. A bad id removes the
  # label of its provider, so an earlier, stale label does not come back. An
  # entry with no usable provider removes every label, because the reader
  # cannot know which one it replaced. A fork at the branch entry with the
  # id `fork` removes every label at or above it (#282): the other branch
  # holds those labels too and may have continued their harness sessions.
  def harness_sessions(entries, fork) do
    {sessions, _count} =
      Enum.reduce(entries, {%{}, 0}, fn entry, acc ->
        {sessions, count} = harness_entry(entry, acc)
        if entry["id"] == fork, do: {%{}, count}, else: {sessions, count}
      end)

    sessions
  end

  defp harness_entry(%{"type" => "message"}, {sessions, count}), do: {sessions, count + 1}

  defp harness_entry(
         %{"type" => "harness_session", "provider" => provider} = entry,
         {sessions, count}
       )
       when is_binary(provider) do
    if Message.resume_id?(entry["harness_session_id"]),
      do: {Map.put(sessions, provider, {entry["harness_session_id"], count}), count},
      else: {Map.delete(sessions, provider), count}
  end

  defp harness_entry(%{"type" => "harness_session"}, {_sessions, count}), do: {%{}, count}
  defp harness_entry(_entry, acc), do: acc

  # The id of the last branch entry, from the first harness session entry
  # down, that an entry of the file off the branch names as its parent, or
  # nil. Every such entry counts, also one on no branch: a fork the reader
  # cannot follow may still be another writer's work, and a wrong fork
  # costs one replay. A branch with no harness session entry has no label
  # to drop, so it builds nothing.
  def last_fork(entries, branch),
    do: fork_in(entries, Enum.drop_while(branch, &(&1["type"] != "harness_session")))

  defp fork_in(_entries, []), do: nil

  # The branch child of a labelled entry is itself labelled, so an entry off
  # the branch is one whose id is not among these.
  defp fork_in(entries, labelled) do
    ids = MapSet.new(labelled, & &1["id"])

    forks =
      for %{"parent_id" => parent} = entry <- entries,
          MapSet.member?(ids, parent),
          not MapSet.member?(ids, entry["id"]),
          into: MapSet.new(),
          do: parent

    Enum.find_value(Enum.reverse(labelled), fn %{"id" => id} ->
      if MapSet.member?(forks, id), do: id
    end)
  end
end
