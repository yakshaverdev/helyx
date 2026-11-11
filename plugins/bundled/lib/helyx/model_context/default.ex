defmodule Helyx.ModelContext.Default do
  # The global context file, relative to the home directory.
  @global_file ".helyx/AGENTS.md"
  # The names a folder can give, in order of preference.
  @file_names ["AGENTS.override.md", "AGENTS.md", "CLAUDE.md"]
  # The cap of the text after the base prompt, in bytes: one file at the
  # per-file cap, with its heading and notice, always fits, so the nearest
  # file is never left out.
  @max_total_bytes 2 * Helyx.Text.max_bytes()
  # The Helyx source root: this file is at plugins/bundled/lib/helyx/model_context.
  @docs_root Path.expand("../../../../..", __DIR__)
  # The cap of one value line of the docs and session sections, in bytes.
  @max_value_bytes 4_096
  @docs_rule "You run in Helyx. Read these files only when the user asks about Helyx itself: its plugins, " <>
               "tools, providers, TUI, sessions, or compaction. Use your normal tools to read them."
  # The topic map, relative to the root. A test checks that each file exists.
  @docs_map [
    {"plugins", ["README.md", "docs/adr/0005-one-project-for-bundled-plugins.md"]},
    {"providers",
     [
       "docs/adr/0002-two-provider-kinds.md",
       "docs/features/provider-parity.md",
       "docs/features/openai-compatible.md"
     ]},
    {"tools",
     [
       "docs/features/coding-agent.md",
       "docs/features/tool-text-out-of-core.md",
       "docs/adr/0003-hands-process.md"
     ]},
    {"TUI", ["docs/adr/0006-client-contract.md", "docs/features/tui-session-switch.md"]},
    {"sessions",
     [
       "docs/features/session-lifecycle.md",
       "docs/features/session-list.md",
       "docs/adr/0001-transcript-shape-and-session-file.md"
     ]},
    {"compaction", ["docs/features/harness-compaction.md"]},
    {"context files and this prompt",
     ["docs/features/context-files.md", "docs/features/agent-self-knowledge.md"]},
    {"skills", ["docs/features/skills.md"]}
  ]
  @docs_topics Enum.map_join(@docs_map, "\n", fn {topic, paths} ->
                 "- #{topic}: #{Enum.join(paths, ", ")}"
               end)

  @moduledoc """
  The default model context: a base prompt, the docs section, the session
  section, the skills section, and the context files, in that order. Each
  build reads the files again. `opts` can carry `:home` and `:docs_root`,
  for tests.

  The docs and session sections: `docs/features/agent-self-knowledge.md`.
  The skills section and the skills carried after a summary
  (`opts[:summary]`): `docs/features/skills.md`. The context files and
  their caps: `docs/features/context-files.md`.
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

    root = opts[:docs_root] || @docs_root
    docs = if File.regular?(Path.join(root, "README.md")), do: [docs_section(root)], else: []
    sections = docs ++ [session_section(cwd, opts) | skills_section(context, cwd, home)]
    system = Enum.join([@base_prompt | sections] ++ nearest_within_cap(files), "\n\n")
    %{context | system: system, messages: carry_skills(context.messages, opts[:summary])}
  end

  # The skills loaded before the cut of the summary, as one message in
  # front of the first kept message, so it comes after the summary.
  defp carry_skills(messages, nil), do: messages

  defp carry_skills(messages, summary) do
    kept = Helyx.Summary.kept(messages, summary)
    {before, kept} = Enum.split(messages, length(messages) - length(kept))

    case Helyx.Skills.carried(before, kept) do
      nil -> messages
      text -> before ++ [Helyx.Message.user(text) | kept]
    end
  end

  defp docs_section(root) do
    """
    ## Helyx docs

    #{@docs_rule}

    #{line("Helyx root", root)}
    #{line("README", Path.join(root, "README.md"))}
    #{line("Feature docs", Path.join(root, "docs/features") <> "/")}
    #{line("Decisions", Path.join(root, "docs/adr") <> "/")}

    Topics, relative to the Helyx root:
    #{@docs_topics}\
    """
  end

  # The catalog only when the model can load a skill.
  defp skills_section(context, cwd, home) do
    if Enum.any?(context.tools, &(&1.name == Helyx.Skills.tool())),
      do: List.wrap(Helyx.Skills.scan(cwd, home).catalog),
      else: []
  end

  defp session_section(cwd, opts) do
    """
    ## This session

    #{line("Working directory", cwd)}
    #{line("Model", Helyx.ModelRef.to_string(Keyword.fetch!(opts, :model)))}
    #{line("Session id", Keyword.fetch!(opts, :session_id))}
    #{line("Session directory", opts[:session_dir] || "not saved")}\
    """
  end

  # One value on one line, so a value cannot add lines to these sections or
  # grow them without bound. The cap comes first: it drops invalid UTF-8,
  # which the Unicode regex rejects, and the replace never adds bytes. `\R`
  # is every Unicode line break, CRLF as one.
  defp line(label, value) do
    "#{label}: " <> String.replace(Helyx.Text.cap(value, @max_value_bytes, :head), ~r/\R/u, " ")
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
