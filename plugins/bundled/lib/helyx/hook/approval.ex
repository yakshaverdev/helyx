defmodule Helyx.Hook.Approval do
  @default_limit_ms 600_000
  @max_name_bytes 256
  @max_arguments_bytes 16_384

  @moduledoc """
  The approval gate: a hook plugin on `before_tool` that allows, denies,
  or asks the user about each tool call by a rule of its config
  (`docs/features/approval-gate.md`, ADR 0013 §7).

  The config is the env key `:approval_hook` of `helyx_plugins`, a keyword
  list: `rules`, a list of rules, `[]` by default; `default`, the action of
  a call that no rule matches, `:ask` by default; and `limit_ms`, the
  hook's limit, the bound of the wait for the user, #{@default_limit_ms} by
  default. A rule is a keyword list of `tool`, a tool name, required;
  `provider`, nil for a Helyx tool or a provider id, nil by default; and
  `action`, `:allow`, `:deny`, or `:ask`, required. A rule matches a call
  of its tool and provider; of the rules that match, a deny wins over an
  ask, and an ask over an allow. A config of another shape is a failed
  hook: the call is denied.

  `:ask` asks the clients with `Helyx.Hook.ask/1` and an `approval` UI
  block (`docs/features/ui-blocks.md`): `tool` and `provider` cut at
  #{@max_name_bytes} bytes, `arguments` the JSON text of the arguments cut
  at #{@max_arguments_bytes} bytes, and `cut: true` when one was cut. The
  answer `%{"decision" => "allow"}` allows the call, and any other answer
  denies it. With no client that can answer, the call is denied at once.
  """

  @behaviour Helyx.Hook

  # Strictest first: of the actions of the rules that match, the first wins.
  @actions [:deny, :ask, :allow]

  @no_client "no user can approve the call in this run: no client that can answer is " <>
               "attached, as in a print run or the session of a sub-agent; try another way"

  @doc false
  def max_name_bytes, do: @max_name_bytes

  @doc false
  def max_arguments_bytes, do: @max_arguments_bytes

  # A `limit_ms` that is there is given as it is, so Core refuses a bad
  # one, nil included, at its start; a broken top gets the default here
  # and fails at each run, where the error names its path.
  @impl true
  def limit(:before_tool) do
    env = env()

    with true <- Keyword.keyword?(env),
         {:ok, ms} <- Keyword.fetch(env, :limit_ms) do
      ms
    else
      _other -> @default_limit_ms
    end
  end

  @impl true
  def before_tool(call), do: decide(call, env())

  defp env, do: Application.get_env(:helyx_plugins, :approval_hook)

  @doc false
  # The answer for `call` with the config `env`; public for the tests,
  # which pass the config.
  def decide(call, env) do
    case action(env, call) do
      {:ok, action, source} ->
        answer(action, source, call)

      {:error, path} ->
        raise ArgumentError, "its config :approval_hook is invalid: #{inspect(path)}"
    end
  end

  defp answer(:allow, source, call), do: {:allow, rule_text(source, call, "allows")}
  defp answer(:deny, source, call), do: {:deny, rule_text(source, call, "denies")}
  defp answer(:ask, _source, call), do: call |> request() |> Helyx.Hook.ask() |> asked()

  defp rule_text(:rule, call, verb), do: "the rule for #{name(call)} #{verb} the call"

  defp rule_text(:default, call, verb),
    do: "no rule names #{name(call)}, and the default #{verb} the call"

  defp name(%{tool: tool, provider: nil}), do: tool
  defp name(%{tool: tool, provider: provider}), do: "#{tool} of #{provider}"

  # The answer for the reply of `Helyx.Hook.ask/1`.
  defp asked({:ok, answer}) when answer == %{"decision" => "allow"},
    do: {:allow, "the user allowed the call"}

  defp asked({:ok, answer}) when answer == %{"decision" => "deny"},
    do: {:deny, "the user denied the call"}

  defp asked({:ok, _other}), do: {:deny, "the answer of the client was not an allow or a deny"}
  defp asked({:error, :no_client}), do: {:deny, @no_client}
  defp asked({:error, :not_running}), do: {:deny, "the call no longer runs"}

  @doc false
  # The `approval` UI block of `call` (docs/features/ui-blocks.md).
  def request(%{tool: tool, provider: provider, arguments: arguments}) do
    {tool, tool_cut?} = cut(tool, @max_name_bytes)
    {provider, provider_cut?} = cut(provider, @max_name_bytes)
    {json, json_cut?} = cut(JSON.encode!(arguments), @max_arguments_bytes)

    block = %{
      "kind" => "approval",
      "text" => "allow #{name(%{tool: tool, provider: provider})}?",
      "tool" => tool,
      "provider" => provider,
      "arguments" => json
    }

    if tool_cut? or provider_cut? or json_cut?, do: Map.put(block, "cut", true), else: block
  end

  defp cut(nil, _max), do: {nil, false}
  defp cut(text, max) when byte_size(text) <= max, do: {text, false}
  defp cut(text, max), do: {Helyx.Text.cap(text, max, :head), true}

  # The action for `call` and whether a rule or the default gave it, or
  # `{:error, path}` of the first bad value of the config. The config is a
  # boundary (AGENTS.md): it is checked whole at each run, as it is small
  # and of the config, not of the model.
  defp action(nil, call), do: action([], call)

  defp action(env, call) do
    with :ok <- top(env),
         {:ok, rules} <- rules(Keyword.get(env, :rules, [])) do
      matched =
        for rule <- rules, rule.tool == call.tool, rule.provider == call.provider, do: rule.action

      case Enum.find(@actions, &(&1 in matched)) do
        nil -> {:ok, Keyword.get(env, :default, :ask), :default}
        action -> {:ok, action, :rule}
      end
    end
  end

  defp top(env) do
    cond do
      not keyword?(env, [:rules, :default, :limit_ms]) ->
        {:error, [:approval_hook]}

      key = Enum.find_value(env, fn {key, value} -> if not top?(key, value), do: key end) ->
        {:error, [:approval_hook, key]}

      true ->
        :ok
    end
  end

  defp top?(:rules, rules), do: is_list(rules) and not List.improper?(rules)
  defp top?(:default, action), do: action in @actions
  defp top?(:limit_ms, ms), do: is_integer(ms) and ms in 1..Helyx.Hook.max_limit_ms()//1

  defp rules(rules) do
    rules
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {rule, index}, {:ok, acc} ->
      case rule(rule) do
        {:ok, rule} -> {:cont, {:ok, [rule | acc]}}
        {:error, path} -> {:halt, {:error, [:approval_hook, :rules, index | path]}}
      end
    end)
  end

  defp rule(rule) do
    cond do
      not keyword?(rule, [:tool, :provider, :action]) ->
        {:error, []}

      not Keyword.has_key?(rule, :tool) ->
        {:error, [:tool]}

      not Keyword.has_key?(rule, :action) ->
        {:error, [:action]}

      key = Enum.find_value(rule, fn {key, value} -> if not rule?(key, value), do: key end) ->
        {:error, [key]}

      true ->
        {:ok, %{tool: rule[:tool], provider: rule[:provider], action: rule[:action]}}
    end
  end

  defp rule?(:tool, tool), do: is_binary(tool)
  # nil names a Helyx tool: the `provider` of a Helyx tool call.
  defp rule?(:provider, provider), do: is_nil(provider) or is_binary(provider)
  defp rule?(:action, action), do: action in @actions

  # A proper keyword list of the known keys, each at most once: `--`
  # removes one of each known key, so a key left over is unknown or repeated.
  defp keyword?(value, keys), do: Keyword.keyword?(value) and Keyword.keys(value) -- keys == []
end
