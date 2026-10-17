defmodule Helyx.TUI.Command do
  @moduledoc false
  # The slash commands of the composer, in `@commands`
  # (docs/features/coding-agent.md, "TUI",
  # docs/features/harness-compaction.md, and
  # docs/features/tui-session-switch.md). `parse/1` owns the rule of a
  # command, `run/2` its session call and the notice of a refused one, and
  # `help/1` the text of `/help`; `Helyx.TUI` runs `/new` and `/resume`,
  # which switch the session, and `/help`, which holds the keys. The
  # transcript follows the session's events, not these calls.

  alias Helyx.Session

  @type name :: :model | :compact | :new | :resume | :help
  @type t :: {name(), String.t()} | {:usage, name()}

  # Each command and its usage: the one list of names that `parse/1`
  # matches and `/help` shows.
  @commands [
    model: "/model provider/model",
    compact: "/compact [instructions]",
    new: "/new",
    resume: "/resume",
    help: "/help"
  ]
  @names Enum.map_join(@commands, "|", fn {name, _usage} -> name end)
  # A command whose usage is its name alone takes no argument.
  @bare for {name, usage} <- @commands, usage == "/#{name}", do: name

  # The rule is on bytes, not on looks; the feature doc's bounds table
  # holds the rule and its limit. A paste keeps tabs and new lines, so
  # `/model<tab>a/b` has a separator. A command name with no separator
  # after it, as in `/models`, gives its usage. The ref goes to
  # `Helyx.ModelRef` unsplit, which owns its bounds. The text holds only
  # valid UTF-8 (a Rust `String`); the `u` flag raises on anything else.
  @spec parse(String.t()) :: t() | {:message, String.t()}
  def parse(text) do
    case Regex.run(~r/\A\s*\/(#{@names})([\s\p{C}]*)/u, text, return: :index) do
      nil ->
        {:message, text}

      [{0, head}, {at, len}, {_, separator}] ->
        name = String.to_existing_atom(binary_part(text, at, len))
        arg = String.trim(binary_part(text, head, byte_size(text) - head))

        cond do
          separator == 0 and head < byte_size(text) -> {:usage, name}
          name in @bare and arg != "" -> {:usage, name}
          true -> {name, arg}
        end
    end
  end

  # Runs a command on the session: `:ok`, or the notice of a refused one.
  @spec run(t(), Session.t()) :: :ok | {:notice, String.t()}
  def run({:usage, name}, _session), do: {:notice, "usage: " <> usage(name)}
  def run({:model, ""}, session), do: run({:usage, :model}, session)
  def run({:model, ref}, session), do: answer(Session.set_model(session, ref))
  def run({:compact, text}, session), do: answer(Session.compact(session, text))

  defp answer(:ok), do: :ok
  defp answer({:error, reason}), do: {:notice, error(reason)}

  defp usage(name), do: Keyword.fetch!(@commands, name)

  # The text of `/help`: the usage of each command, then the keys of
  # `Helyx.TUI`, one line each.
  @spec help([{String.t(), String.t()}]) :: String.t()
  def help(keys) do
    commands = Enum.map_join(@commands, ", ", fn {_name, usage} -> usage end)

    Enum.join(
      ["commands: " <> commands, "keys:" | for({key, text} <- keys, do: "#{key}: #{text}")],
      "\n"
    )
  end

  # A notice shows at most the provider id, which the ref bounds cap.
  defp error({:unknown_provider, id}), do: "unknown provider: #{id}"
  defp error({:invalid_model_ref, _ref}), do: "invalid model ref: use provider/model"
  defp error(:turn_running), do: "not sent: a compaction already runs"
  # The bound is `Session.max_text_bytes/0`.
  defp error(:text_too_large), do: "not sent: over 4 MiB"
  defp error(:session_not_found), do: "the session ended"
end
