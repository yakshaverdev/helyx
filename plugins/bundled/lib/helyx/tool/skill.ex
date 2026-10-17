defmodule Helyx.Tool.Skill do
  @moduledoc """
  Loads a skill by its name: a `SKILL.md` of the `.agents/skills` folders
  of the working directory and of the home folder, the folders of the
  skills section of the system prompt. The result is the text of the file and
  its absolute folder. A skill that the session's transcript already holds,
  from this tool or from a user command, gives a short note instead
  (`Helyx.Tool.transcript/0`). See `docs/features/skills.md`.
  """

  @behaviour Helyx.Tool

  alias Helyx.Skills

  # The bytes of an unknown name that its error echoes.
  @max_echo_bytes 64

  @impl true
  def name, do: Skills.tool()

  @impl true
  def description do
    "Load a skill by its name, from the skills list in the system prompt. Returns its " <>
      "instructions and its folder; relative paths in it resolve against that folder."
  end

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "name" => %{"type" => "string", "description" => "The name of the skill"}
      },
      "required" => ["name"]
    }
  end

  @impl true
  def run(%{"name" => name}, cwd) when is_binary(name) do
    case Skills.find(Skills.scan(cwd), name) do
      nil ->
        {:error,
         "unknown skill: #{Helyx.Text.cap(name, @max_echo_bytes, :head)}; " <>
           "the skills are listed in the system prompt"}

      skill ->
        if Skills.loaded?(Helyx.Tool.transcript(), name),
          do: {:ok, Skills.note(skill)},
          else: {:ok, Skills.text(skill)}
    end
  end

  def run(_args, _cwd), do: {:error, "skill needs a name"}
end
