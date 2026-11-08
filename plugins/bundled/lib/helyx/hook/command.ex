defmodule Helyx.Hook.Command do
  @default_limit_ms 60_000

  @moduledoc """
  A hook plugin that runs a command from its config at a point
  (`docs/features/command-hook.md`, ADR 0013 §8).

  The config is the env key `:command_hook` of `helyx_plugins`: a keyword
  list of the points `:before_tool`, `:after_tool`, and `:before_settle`,
  each a keyword list of `command`, a string, required; `limit_ms`, the
  hook's limit at the point, #{@default_limit_ms} by default; and, at the
  two tool points, `tools`, the tool names that the command runs for,
  every tool by default. A point with no entry, and a tool that is not in
  its `tools`, get `:allow`, `:keep`, or `:settle` with no run. A key that
  is there has a value of its type: `nil` is no value. A config of another
  shape at the top, or in the entry of the point, is a failed hook at that
  point.

  The command runs with `bash -c` in the `cwd` of its input, the session's
  folder, in its own process group under the perl watchdog, held with
  `Helyx.Tool.hold/1`. It gets the call, or at `before_settle` the ended
  turn, as JSON on standard input, in the field names of the Claude Code
  hook format where it has the field. Exit 0 is the default answer, or the answer of a JSON
  object on standard output. Exit 2 is a deny at `before_tool`, with
  standard error as the reason; at `after_tool` the result with standard
  error added; and at `before_settle` a continue with standard error as
  its text. Any other exit is a failed hook: `before_tool` denies the
  call. At most #{Helyx.Hook.Command.Run.max_output_bytes()} bytes of each
  of standard output and standard error are kept.
  """

  @behaviour Helyx.Hook

  alias Helyx.Hook.Command.{Answer, Run}

  @points [:before_tool, :after_tool, :before_settle]

  # A `limit_ms` that is there is given as it is, so Core refuses a bad
  # one, nil included, at its start; a broken top or entry gets the
  # default here and fails at each run, where the error names its path.
  @impl true
  def limit(point) do
    env = env()

    with true <- Keyword.keyword?(env),
         config = env[point],
         true <- Keyword.keyword?(config),
         {:ok, ms} <- Keyword.fetch(config, :limit_ms) do
      ms
    else
      _other -> @default_limit_ms
    end
  end

  @impl true
  def before_tool(input), do: run(:before_tool, input, env())

  @impl true
  def after_tool(input), do: run(:after_tool, input, env())

  @impl true
  def before_settle(input), do: run(:before_settle, input, env())

  @impl true
  defdelegate release(handles, mode, deadline), to: Helyx.Watchdog.Group

  defp env, do: Application.get_env(:helyx_plugins, :command_hook)

  @doc false
  # The run of `point` on `input` with the config `env`; public for the
  # tests, which pass the config and run in the fake hands.
  def run(point, input, env) do
    case command(env, point, input) do
      {:ok, nil} ->
        Answer.default(point)

      {:ok, command} ->
        point |> Answer.input(input) |> Run.run(command, input.cwd) |> Answer.of(point, input)

      {:error, path} ->
        Answer.fail("its config :command_hook is invalid: #{inspect(path)}")
    end
  end

  # The config is a boundary (AGENTS.md): at each run, the top and the
  # entry of the point are checked, the smallest unit that the run reads,
  # and the error names the path of the first bad value.
  defp command(nil, _point, _input), do: {:ok, nil}

  defp command(env, point, input) do
    cond do
      not keyword?(env, @points) -> {:error, [:command_hook]}
      not Keyword.has_key?(env, point) -> {:ok, nil}
      error = point_error(point, env[point]) -> error
      tool?(env[point][:tools], input) -> {:ok, env[point][:command]}
      true -> {:ok, nil}
    end
  end

  # nil for a valid entry, else `{:error, path}` of its first bad value.
  # A key that is there has a value of its type: nil is no value.
  defp point_error(point, config) do
    path = [:command_hook, point]

    cond do
      not keyword?(config, keys(point)) ->
        {:error, path}

      not Keyword.has_key?(config, :command) ->
        {:error, path ++ [:command]}

      key = Enum.find_value(config, fn {key, value} -> if not valid?(key, value), do: key end) ->
        {:error, path ++ [key]}

      true ->
        nil
    end
  end

  # A `before_settle` runs for no tool, so its entry has no `tools`.
  defp keys(:before_settle), do: [:command, :limit_ms]
  defp keys(_tool_point), do: [:command, :limit_ms, :tools]

  # A proper keyword list of the known keys, each at most once: `--`
  # removes one of each known key, so a key left over is unknown or repeated.
  defp keyword?(value, keys), do: Keyword.keyword?(value) and Keyword.keys(value) -- keys == []

  # A NUL would cut the port argument (`Helyx.Tool.Bash`).
  defp valid?(:command, command) do
    is_binary(command) and command != "" and String.valid?(command) and
      not String.contains?(command, <<0>>)
  end

  defp valid?(:limit_ms, ms), do: is_integer(ms) and ms in 1..Helyx.Hook.max_limit_ms()//1

  defp valid?(:tools, tools),
    do: is_list(tools) and not List.improper?(tools) and Enum.all?(tools, &is_binary/1)

  # Only the entry of a tool point has `tools`, and its input names the tool.
  defp tool?(nil, _input), do: true
  defp tool?(tools, input), do: input.tool in tools
end
