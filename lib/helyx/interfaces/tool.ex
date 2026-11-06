defmodule Helyx.Tool do
  @moduledoc """
  A tool the model can call. The hands run it in the session's working
  directory.

  A tool plugin implements this behaviour. `name/0` is what the model calls.
  `parameters/0` is a JSON schema map with string keys. `run/2` gets the
  decoded argument map and the working directory, and returns the text the
  model sees. `{:error, text}` marks the result as an error; a tool that
  raises is reported the same way. The hands make every result text valid
  UTF-8 and cut a text over `Helyx.Message.max_result_bytes/0` to a notice
  line, its head, a marker line, and its tail (`Helyx.Message.cut_result/1`).

  The optional `check/0` runs once per session start or resume, in the
  caller (`check_available/1`). `hold/1` and `release/3` manage a resource
  (`docs/features/tool-resource-release.md`, ADR 0004); the optional
  `concurrent?/0` and `background/0` are described in
  `docs/features/concurrent-tool-calls.md` and
  `docs/features/background-bash.md`.
  """

  use Helyx.Interface, mode: :multi

  @type spec :: %{name: String.t(), description: String.t(), parameters: map()}

  @callback name() :: String.t()
  @callback description() :: String.t()
  @callback parameters() :: map()
  @callback run(arguments :: map(), cwd :: String.t()) :: {:ok, String.t()} | {:error, String.t()}
  @callback check() :: :ok | {:error, String.t()}
  @callback concurrent?() :: boolean()
  @callback release(
              handles :: [term()],
              mode :: :deliver | :cancel,
              deadline :: integer()
            ) ::
              [term()]

  @optional_callbacks check: 0, concurrent?: 0, release: 3

  @doc """
  Builds and checks the spec of each registered tool plugin, in name order;
  the session calls this once at start. With `only`, it keeps only the
  listed names. A spec needs a non-empty `name` and a `description` of
  valid UTF-8, and `parameters` a map with string keys that
  `Helyx.Message.encoded_size/1` accepts. Errors:
  `{:error, {:bad_tool_spec, label}}` and
  `{:error, {:duplicate_tool_name, name}}` (`docs/features/coding-agent.md`).
  """
  @spec specs(Helyx.Core.name(), [String.t()] | nil) ::
          {:ok, [{module(), spec()}]}
          | {:error, {:bad_tool_spec, String.t()} | {:duplicate_tool_name, String.t()}}
  def specs(core, only \\ nil) do
    result =
      Enum.reduce_while(Helyx.Core.plugins(core, __MODULE__), {:ok, []}, fn tool, {:ok, acc} ->
        case checked_spec(tool) do
          {:ok, spec} -> {:cont, {:ok, [{tool, spec} | acc]}}
          error -> {:halt, error}
        end
      end)

    with {:ok, tools} <- result,
         :ok <- check_unique(tools),
         do: {:ok, Enum.sort_by(keep(tools, only), fn {_tool, spec} -> spec.name end)}
  end

  defp keep(tools, nil), do: tools
  defp keep(tools, only), do: Enum.filter(tools, fn {_tool, spec} -> spec.name in only end)

  defp checked_spec(tool) do
    spec = %{name: tool.name(), description: tool.description(), parameters: tool.parameters()}

    cond do
      not text?(spec.name) or spec.name == "" ->
        {:error, {:bad_tool_spec, inspect(tool)}}

      not text?(spec.description) or not parameters?(spec.parameters) ->
        {:error, {:bad_tool_spec, spec.name}}

      true ->
        {:ok, spec}
    end
  end

  @doc """
  Runs the optional `check/0` of each tool in order and stops at the first
  failure: `{:error, {:tool_unavailable, name, reason}}`. Any other value
  but `:ok` raises in the caller (`docs/features/coding-agent.md`).
  """
  @spec check_available([{module(), spec()}]) ::
          :ok | {:error, {:tool_unavailable, String.t(), String.t()}}
  def check_available(tools) do
    Enum.find_value(tools, :ok, fn {tool, spec} ->
      case run_check(tool) do
        :ok -> nil
        {:error, reason} -> {:error, {:tool_unavailable, spec.name, reason}}
      end
    end)
  end

  defp run_check(tool) do
    if function_exported?(tool, :check, 0), do: checked_result(tool.check()), else: :ok
  end

  @doc """
  The names of the tools whose optional `concurrent?/0` returns `true`; a
  tool without it is not concurrent. A return other than a boolean raises
  (`docs/features/concurrent-tool-calls.md`).
  """
  @spec concurrent([{module(), spec()}]) :: MapSet.t(String.t())
  def concurrent(tools),
    do: MapSet.new(for {tool, spec} <- tools, concurrent?(tool), do: spec.name)

  defp concurrent?(tool) do
    if function_exported?(tool, :concurrent?, 0) do
      concurrent? = tool.concurrent?()
      true = is_boolean(concurrent?)
      concurrent?
    else
      false
    end
  end

  defp checked_result(:ok), do: :ok

  defp checked_result({:error, reason} = error) when is_binary(reason) do
    true = String.valid?(reason)
    error
  end

  defp check_unique(tools) do
    names = Enum.map(tools, fn {_tool, spec} -> spec.name end)

    case names -- Enum.uniq(names) do
      [] -> :ok
      [dup | _] -> {:error, {:duplicate_tool_name, dup}}
    end
  end

  defp text?(value), do: is_binary(value) and String.valid?(value)

  defp parameters?(value) when is_map(value),
    do: Enum.all?(Map.keys(value), &is_binary/1) and Helyx.Message.encoded_size(value) != :error

  defp parameters?(_value), do: false

  @doc """
  Holds an opaque handle of a resource that a tool call or a provider
  process created, with the hands that run it; returns only when the hands
  hold it, so work that starts after is never unheld.

  The hands call `release(handles, mode, deadline)` with the handles of a
  Task: `:deliver` when it delivers, `:cancel` when its turn is aborted or
  the session stops. `deadline` is absolute, in
  `System.monotonic_time(:millisecond)` on the node of the hands. The return
  value is the handles still held; `[]` means every one is released, and the
  callback must not wait past the deadline. A tool frees its resource itself
  when its Task dies with no release. Exits outside the hands; raises
  without `release/3` (`docs/features/tool-resource-release.md`, ADR 0004).
  """
  @spec hold(term()) :: :ok
  def hold(handle) do
    case GenServer.call(Process.get(:helyx_hands), {:hold, handle}, :infinity) do
      :ok -> :ok
      :no_release -> raise ArgumentError, "a tool without release/3 cannot hold a resource"
    end
  end

  @doc """
  Ends the hold of handles whose resources the caller released itself with
  its own `release/3`, only those that the release confirmed
  (`docs/features/tool-resource-release.md`, rule 9).
  """
  @spec unhold([term()]) :: :ok
  def unhold(handles) when is_list(handles) do
    # An improper list fails here, in the caller, and not in the hands.
    false = List.improper?(handles)
    GenServer.call(Process.get(:helyx_hands), {:unhold, handles}, :infinity)
  end

  @doc """
  The context of the calling tool call, with the keys of the return type
  above. Raises in any other process (`docs/features/agent-tool.md`).
  """
  @spec context() :: %{
          core: Helyx.Core.name(),
          session_id: String.t(),
          tools: [String.t()],
          tool: String.t(),
          call_id: String.t(),
          model: String.t(),
          provider_opts: keyword(),
          model_context: module() | nil
        }
  def context do
    case Process.get(:helyx_call) do
      %{} = context -> context
      nil -> raise ArgumentError, "context/0 runs only in a tool call"
    end
  end

  # The most bytes of the JSON of a request to `ask/1`.
  @max_request_bytes 65_536

  @doc """
  Asks the clients of the session and waits for the first answer: a JSON
  object of at most #{@max_request_bytes} bytes, emitted in an `:ask` event.
  `{:error, :no_client}` when no subscriber can answer, and
  `{:error, :not_running}` when the call is not a running call of the
  current turn. Raises on any other request and outside a tool call
  (`docs/features/question-tool.md`).
  """
  @spec ask(map()) :: {:ok, map()} | {:error, :no_client | :not_running}
  def ask(request) do
    %{core: core, session_id: id, call_id: call_id, tool: tool} = context()

    if Helyx.Session.Input.json_object(request, @max_request_bytes) != :ok,
      do: raise(ArgumentError, "an ask request is a JSON object of at most 64 KiB")

    GenServer.call(Helyx.Session.Server.via(core, id), {:ask, call_id, tool, request}, :infinity)
  end

  @doc """
  The messages of the session that runs the calling Task of the hands, as it
  holds them when it answers. Exits outside the hands and when the session
  ends (`docs/features/skills.md`).
  """
  @spec transcript() :: [Helyx.Message.t()]
  def transcript, do: GenServer.call(Process.get(:helyx_session), :transcript, :infinity)

  @doc """
  Takes a place for a background run before its external work starts:
  `{:ok, %{id: id, dir: dir}}`, or `{:error, text}` with no place because
  the 16 places are taken, the folder cannot be made, or the caller is no
  tool call. Exits outside the hands, as `hold/1` does
  (`docs/features/background-bash.md`).
  """
  @spec background() :: {:ok, %{id: String.t(), dir: String.t()}} | {:error, String.t()}
  def background, do: GenServer.call(Process.get(:helyx_hands), :background, :infinity)

  @doc """
  Gives the start answer of a background run: `text` becomes the result of
  the call, and the Task runs on. Raises in a Task that is no tool call of a
  turn and in a call with no place from `background/0`; exits outside the
  hands (`docs/features/background-bash.md`).
  """
  @spec started(String.t()) :: :ok
  def started(text) when is_binary(text) do
    case GenServer.call(Process.get(:helyx_hands), {:started, text}, :infinity) do
      :ok -> :ok
      :no_place -> raise ArgumentError, "started/1 needs a place from background/0"
    end
  end
end
