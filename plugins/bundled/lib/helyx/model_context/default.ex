defmodule Helyx.ModelContext.Default do
  # The global context file, relative to the home directory.
  @global_file ".helyx/AGENTS.md"
  # The names a folder can give, in order of preference.
  @file_names ["AGENTS.override.md", "AGENTS.md", "CLAUDE.md"]
  # The cap of the text after the base prompt, in bytes: one file at the
  # per-file cap, with its heading and notice, always fits, so the nearest
  # file is never left out.
  @max_total_bytes 2 * Helyx.Text.max_bytes()

  @moduledoc """
  The default model context: a base prompt plus the context files.

  The context files are the global file `~/.helyx/AGENTS.md`, then one file
  for each folder from the filesystem root down to the working directory, in
  that order. A folder gives the first of `AGENTS.override.md`, `AGENTS.md`,
  and `CLAUDE.md` that is a regular file there. If `Helyx.Text.read_file/1`
  rejects that file (including a file that is not valid UTF-8), the folder
  gives nothing. A file reached twice, through a symlink or as the global
  file in the chain, loads once, at its first place.

  Each file follows a heading with its path, capped by `Helyx.Text.truncate/2`.
  The text after the base prompt, headings and separators included, is at
  most #{@max_total_bytes} bytes: the files nearest the working directory
  come first, and from the first file that does not fit, that file and every
  file farther away are left out.
  `opts` can carry `:home` to override the home directory, for tests.

  See `docs/features/context-files.md`.
  """

  @behaviour Helyx.ModelContext

  @base_prompt "You are a coding agent. You work in the user's repository with the tools provided."

  @impl true
  def build(context, opts) do
    cwd = Path.expand(Keyword.fetch!(opts, :cwd))
    home = Path.expand(opts[:home] || System.user_home!())

    candidates = for dir <- folders(cwd), do: Enum.map(@file_names, &Path.join(dir, &1))

    files =
      [[Path.join(home, @global_file)] | candidates]
      |> Enum.flat_map(&first_regular/1)
      |> Enum.uniq_by(fn {_path, id} -> id end)

    %{context | system: Enum.join([@base_prompt | nearest_within_cap(files)], "\n\n")}
  end

  # The folders from the filesystem root down to cwd, both included.
  defp folders(cwd) do
    [root | below] = Path.split(cwd)
    [root | Enum.scan(below, root, &Path.join(&2, &1))]
  end

  # The first path that is a regular file, with the identity of the file it
  # reaches, or none.
  defp first_regular(paths) do
    Enum.find_value(paths, [], fn path ->
      case File.stat(path) do
        {:ok, %File.Stat{type: :regular} = stat} -> [{path, {stat.major_device, stat.inode}}]
        _ -> nil
      end
    end)
  end

  # The sections of the files nearest the end that fit in the cap, in their
  # order. Files are read nearest first and lazily, so a file past the cap is
  # never read. Each section costs its bytes plus the separator before it.
  defp nearest_within_cap(files) do
    files
    |> Enum.reverse()
    |> Stream.flat_map(fn {path, _id} ->
      for {:ok, content} <- [Helyx.Text.read_file(path)],
          do: "## #{path}\n\n#{Helyx.Text.truncate(content, :head)}"
    end)
    |> Enum.reduce_while({[], @max_total_bytes}, fn section, {kept, left} ->
      cost = byte_size(section) + 2

      if cost <= left,
        do: {:cont, {[section | kept], left - cost}},
        else: {:halt, {kept, left}}
    end)
    |> elem(0)
  end
end
