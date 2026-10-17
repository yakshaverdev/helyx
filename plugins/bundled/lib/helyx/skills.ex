defmodule Helyx.Skills do
  @moduledoc false
  # The skills of a working directory in the Agent Skills format: the scan
  # of the `.agents/skills` folders, the catalog of the system prompt, the
  # load text of the skill tool and of a user command, and the derived
  # "already loaded" check. A helper module (ADR 0005), called by
  # `Helyx.ModelContext.Default`, `Helyx.Tool.Skill`, the TUI, and print
  # mode. The rules and the bounds are in docs/features/skills.md.

  defmodule Skill do
    @moduledoc false
    @enforce_keys [:name, :description, :folder, :content]
    defstruct [:name, :description, :folder, :content]

    @type t :: %__MODULE__{
            name: String.t(),
            description: String.t(),
            folder: String.t(),
            content: String.t()
          }
  end

  @folder ".agents/skills"
  # The tool name that the catalog tells the model to call.
  @tool "skill"
  # The skill folders of one scan, in precedence order.
  @max_skills 200
  @max_file_bytes 65_536
  @max_catalog_bytes 16_384
  @max_name_chars 64
  @max_description_chars 1_024
  # The folder line is capped so that the load text stays under
  # `Helyx.Message.max_result_bytes/0`: the hands never cut it, and its
  # first line, which `loaded?/2` reads, stays first.
  @max_folder_bytes 4_096
  @max_notice_bytes 1_024
  @name_rule ~r/\A[a-z0-9]+(-[a-z0-9]+)*\z/
  @catalog_heading "## Skills\n\n" <>
                     "Each skill below is a folder of instructions for one kind of task. " <>
                     "When a task matches a skill, load it with the skill tool before you start, " <>
                     "and follow it."

  # The load text: the cut of `Helyx.Text.truncate/2` with its newline and
  # notice (at most 257 bytes), the header and the closing line (with a
  # name of at most 64 bytes), and the folder line.
  if Helyx.Text.max_bytes() + 257 + 2 * (@max_name_chars + 20) + @max_folder_bytes + 80 >
       Helyx.Message.max_result_bytes(),
     do: raise("the skill load text does not fit Helyx.Message.max_result_bytes/0")

  @type scan :: %{skills: [Skill.t()], catalog: String.t() | nil, notices: [String.t()]}

  def tool, do: @tool
  def max_catalog_bytes, do: @max_catalog_bytes

  # The skills that the catalog lists, in precedence order, the catalog
  # section (nil with no skill), and the notices of the scan, in order.
  @spec scan(String.t(), String.t()) :: scan()
  def scan(cwd, home \\ System.user_home!()) do
    {candidates, rest} = cwd |> Path.expand() |> folders(Path.expand(home)) |> candidates()
    {skills, notices} = Enum.reduce(candidates, {[], []}, &take/2)
    {kept, catalog} = skills |> Enum.reverse() |> catalog()
    cut = length(skills) - length(kept)

    notices =
      Enum.reverse(notices) ++
        for(
          {true, text} <- [
            {rest > 0, "#{rest} more skill folders were not read: at most #{@max_skills}"},
            {cut > 0,
             "#{cut} skills were left out: the skill list has at most #{@max_catalog_bytes} bytes"}
          ],
          do: text
        )

    %{
      skills: kept,
      catalog: catalog,
      notices: for(text <- notices, do: Helyx.Text.cap(text, @max_notice_bytes, :head))
    }
  end

  # A skill name that a nearer skill holds is hidden and not read.
  defp take(dir, {skills, notices}) do
    name = Path.basename(dir)

    case Enum.find(skills, &(&1.name == name)) do
      %Skill{} = winner ->
        {skills, ["skill #{dir} is hidden by #{winner.folder}" | notices]}

      nil ->
        case read(dir) do
          {:ok, skill} -> {[skill | skills], notices}
          {:error, why} -> {skills, ["skill #{dir} is not loaded: #{why}" | notices]}
        end
    end
  end

  # The `.agents/skills` folders that exist, in precedence order: from cwd
  # up to the git root (or `/`), then the user folder. A folder reached
  # twice loads once, at its first place, except that the user folder keeps
  # its own place.
  defp folders(cwd, home) do
    user = Path.join(home, @folder)
    user_id = id(user)

    for(dir <- up_to_root(cwd), do: Path.join(dir, @folder))
    |> Enum.map(&{&1, id(&1)})
    |> Enum.reject(fn {_path, id} -> id in [nil, user_id] end)
    |> Enum.concat(if user_id, do: [{user, user_id}], else: [])
    |> Enum.uniq_by(fn {_path, id} -> id end)
    |> Enum.map(fn {path, _id} -> path end)
  end

  # The folders from `dir` up to the first that holds a `.git` entry of any
  # type (a worktree's `.git` is a file), or up to `/`.
  defp up_to_root(dir) do
    parent = Path.dirname(dir)

    if parent == dir or match?({:ok, _}, File.lstat(Path.join(dir, ".git"))),
      do: [dir],
      else: [dir | up_to_root(parent)]
  end

  # The identity of a folder, or nil when the path is no folder.
  defp id(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :directory} = stat} -> {stat.major_device, stat.inode}
      _ -> nil
    end
  end

  # The skill folders with a `SKILL.md` entry, in order, at most
  # @max_skills, and the count of the rest. Nothing below a skill folder is
  # listed; `File.stat/1` follows a symlinked skill folder.
  defp candidates(folders) do
    all =
      for folder <- folders,
          {:ok, names} <- [File.ls(folder)],
          name <- Enum.sort(names),
          dir = Path.join(folder, name),
          match?({:ok, _}, File.stat(Path.join(dir, "SKILL.md"))),
          do: dir

    {Enum.take(all, @max_skills), max(length(all) - @max_skills, 0)}
  end

  defp read(dir) do
    path = Path.join(dir, "SKILL.md")

    with {:ok, %File.Stat{type: :regular, size: size}} when size <= @max_file_bytes <-
           File.stat(path),
         {:ok, content} when byte_size(content) <= @max_file_bytes <- Helyx.Text.read_file(path),
         {:ok, keys} <- Helyx.Skills.Frontmatter.read(content),
         {:ok, name, description} <- fields(keys, Path.basename(dir)) do
      {:ok, %Skill{name: name, description: description, folder: dir, content: content}}
    else
      {:ok, %File.Stat{type: :regular}} ->
        {:error, "SKILL.md is over #{@max_file_bytes} bytes"}

      {:ok, %File.Stat{}} ->
        {:error, "SKILL.md is not a regular file"}

      {:ok, content} when is_binary(content) ->
        {:error, "SKILL.md is over #{@max_file_bytes} bytes"}

      {:error, reason} when is_atom(reason) ->
        {:error, "SKILL.md: #{:file.format_error(reason)}"}

      {:error, why} ->
        {:error, why}
    end
  end

  defp fields(%{"name" => name, "description" => description}, folder_name) do
    cond do
      String.length(name) > @max_name_chars or not Regex.match?(@name_rule, name) ->
        {:error, "the name must be 1 to #{@max_name_chars} of a-z, 0-9, and single inner hyphens"}

      name != folder_name ->
        {:error, "the name #{name} is not the folder name"}

      description == "" ->
        {:error, "the frontmatter has no description string"}

      length(String.codepoints(description)) > @max_description_chars ->
        {:error, "the description is over #{@max_description_chars} characters"}

      true ->
        {:ok, name, description}
    end
  end

  # The skills whose lines fit the cap in order, and the section. From the
  # first line that does not fit, that skill and every later one are left
  # out.
  defp catalog(skills) do
    {kept, lines, _left} =
      Enum.reduce_while(skills, {[], [], @max_catalog_bytes - byte_size(@catalog_heading) - 1}, fn
        skill, {kept, lines, left} ->
          line = "\n- #{skill.name}: " <> String.replace(skill.description, ~r/\R/u, " ")

          if byte_size(line) <= left,
            do: {:cont, {[skill | kept], [line | lines], left - byte_size(line)}},
            else: {:halt, {kept, lines, left}}
      end)

    case kept do
      [] ->
        {[], nil}

      _ ->
        {Enum.reverse(kept), IO.iodata_to_binary([@catalog_heading, "\n" | Enum.reverse(lines)])}
    end
  end

  # The text of a first load, by the skill tool or by a user command.
  @spec text(Skill.t()) :: String.t()
  def text(%Skill{} = skill) do
    folder = Helyx.Text.cap(skill.folder, @max_folder_bytes, :head)

    """
    #{header(skill.name)}
    Folder: #{folder} (relative paths in this skill resolve against it)

    #{Helyx.Text.truncate(skill.content, :head)}
    </skill>\
    """
  end

  # The text of a second load.
  @spec note(Skill.t()) :: String.t()
  def note(%Skill{} = skill) do
    "The skill #{skill.name} is already loaded in this session: follow the text of the earlier load. " <>
      "If that text is no longer in your context, read #{Path.join(skill.folder, "SKILL.md")}."
  end

  defp header(name), do: ~s(<skill name="#{name}">)

  # True when a user message, or a result of the skill tool that is not an
  # error, starts with the first line of the load text of `name`.
  @spec loaded?([Helyx.Message.t()], String.t()) :: boolean()
  def loaded?(messages, name) do
    first = header(name) <> "\n"

    Enum.any?(messages, fn message ->
      load?(message) and starts?(message.content, first)
    end)
  end

  defp load?(%Helyx.Message{role: :user}), do: true
  defp load?(%Helyx.Message{role: :tool_result, tool_name: @tool, is_error: false}), do: true
  defp load?(_message), do: false

  defp starts?([%Helyx.Message.Text{text: text} | _], first) when is_binary(text),
    do: String.starts_with?(text, first)

  defp starts?(_content, _first), do: false

  # The text of a user command `/name args` when `name` is a known skill:
  # the load text, then a blank line and the arguments when there are any.
  # nil when the text is no such command.
  @spec expand(String.t(), String.t(), String.t()) :: String.t() | nil
  def expand(text, cwd, home \\ System.user_home!()) do
    with [_, name, args] <- Regex.run(~r/\A\s*\/([a-z0-9-]+)(\s.*|)\z/su, text),
         %Skill{} = skill <- find(scan(cwd, home), name) do
      case String.trim(args) do
        "" -> text(skill)
        args -> text(skill) <> "\n\n" <> args
      end
    else
      _ -> nil
    end
  end

  # The skill of the scan with that name, or nil.
  @spec find(scan(), String.t()) :: Skill.t() | nil
  def find(%{skills: skills}, name), do: Enum.find(skills, &(&1.name == name))
end
