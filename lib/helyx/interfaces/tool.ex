defmodule Helyx.Tool do
  @moduledoc """
  A tool the model can call. The hands run it in the session's working
  directory.

  A tool plugin implements this behaviour. `name/0` is what the model calls.
  `parameters/0` is a JSON schema map with string keys. `run/2` gets the
  decoded argument map and the working directory, and returns the text the
  model sees. `{:error, text}` marks the result as an error; a tool that
  raises is reported the same way.

  The optional `check/0` runs once per session start or resume, in the
  caller, before any file or process is created (`check_available/1`). A
  tool that needs something from the system, an executable for example,
  reports it missing there. Then the session fails to start with a clear
  error, and no call fails later for that reason.

  A tool that creates an OS resource, a process group for example, holds it
  with `hold/1` before the external work starts, and implements the
  optional `release/3`. The hands call `release(handles, mode, deadline)`
  with the handles of a call when it delivers (`:deliver`), when its turn is
  aborted (`:cancel`), and before a later call for handles that an earlier
  release did not confirm (`:retry`). `deadline` is absolute, in
  `System.monotonic_time(:millisecond)` on the node of the hands. The return
  value is the handles still held; `[]` means every one is released. The
  callback must be safe to call again with the same handles, and it must
  not wait past the deadline. The tool must also free the resource by
  itself when its Task dies with no release, because the hands can die
  first and drop a late `hold/1` (ADR 0004).
  """

  use Helyx.Interface, mode: :multi

  # The fixed reasons of `check_available/1`.
  @bad_check_value "check/0 returned a bad value"
  @failed_check "check/0 raised, threw, or exited"

  @type spec :: %{name: String.t(), description: String.t(), parameters: map()}

  @callback name() :: String.t()
  @callback description() :: String.t()
  @callback parameters() :: map()
  @callback run(arguments :: map(), cwd :: String.t()) :: {:ok, String.t()} | {:error, String.t()}
  @callback check() :: :ok | {:error, String.t()}
  @callback release(
              handles :: [term()],
              mode :: :deliver | :cancel | :retry,
              deadline :: integer()
            ) ::
              [term()]

  @optional_callbacks check: 0, release: 3

  @doc """
  Builds the spec of each registered tool plugin, checks it, and returns
  the tools sorted by name. The session calls this once at start, so the
  callbacks `name/0`, `description/0`, and `parameters/0` run once per
  session, and every provider call uses the checked value.

  A spec is accepted when `name` is a non-empty string of valid UTF-8,
  `description` is a string of valid UTF-8, and `parameters` is a map with
  string keys at the top level that `Helyx.Message.encodable?/1` accepts.
  Otherwise the result is `{:error, {:bad_tool_spec, label}}`: the label is
  the name when the name is accepted, else the module name. Plugin code that
  raises, throws, or exits while a spec is built or checked (a callback, or
  a JSON encoder of a struct in `parameters`) gives the same error with the
  module name, so a plugin failure never reaches the caller. Two tools with
  one name give `{:error, {:duplicate_tool_name, name}}`.
  """
  @spec specs(Helyx.Core.name()) ::
          {:ok, [{module(), spec()}]}
          | {:error, {:bad_tool_spec, String.t()} | {:duplicate_tool_name, String.t()}}
  def specs(core) do
    result =
      Enum.reduce_while(Helyx.Core.plugins(core, __MODULE__), {:ok, []}, fn tool, {:ok, acc} ->
        case checked_spec(tool) do
          {:ok, spec} -> {:cont, {:ok, [{tool, spec} | acc]}}
          error -> {:halt, error}
        end
      end)

    with {:ok, tools} <- result,
         :ok <- check_unique(tools),
         do: {:ok, Enum.sort_by(tools, fn {_tool, spec} -> spec.name end)}
  end

  # The callbacks and the check run in one catch: all of it can run plugin
  # code, and a failure there is a bad spec, not a crash of the caller.
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
  catch
    _class, _reason -> {:error, {:bad_tool_spec, inspect(tool)}}
  end

  @doc """
  Runs the optional `check/0` of each tool that `specs/1` returned, in that
  order, and stops at the first failure. `{:error, reason}` with a reason
  of valid UTF-8 gives `{:error, {:tool_unavailable, name, reason}}`, where
  `name` is the checked spec name. Any other value but `:ok`, and a
  `check/0` that raises, throws, or exits, give the same error with a fixed
  reason, so a plugin failure never reaches the caller.
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
  catch
    _class, _reason -> {:error, @failed_check}
  end

  defp checked_result(:ok), do: :ok

  defp checked_result({:error, reason} = error) do
    if text?(reason), do: error, else: {:error, @bad_check_value}
  end

  defp checked_result(_other), do: {:error, @bad_check_value}

  defp check_unique(tools) do
    names = Enum.map(tools, fn {_tool, spec} -> spec.name end)

    case names -- Enum.uniq(names) do
      [] -> :ok
      [dup | _] -> {:error, {:duplicate_tool_name, dup}}
    end
  end

  defp text?(value), do: is_binary(value) and String.valid?(value)

  defp parameters?(value) when is_map(value),
    do: Enum.all?(Map.keys(value), &is_binary/1) and Helyx.Message.encodable?(value)

  defp parameters?(_value), do: false

  @doc """
  Holds an opaque handle of a resource the tool call created with the hands
  that run it. The hands keep it outside the Task and give it to the tool's
  `release/3` when the call delivers or its turn is aborted, so no resource
  outlives the call. Returns only when the hands hold the handle, so work
  that starts after it is never unheld. A no-op when the tool runs outside
  the hands. Raises when the tool does not implement `release/3`.
  """
  @spec hold(term()) :: :ok
  def hold(handle) do
    case Process.get(:helyx_hands) do
      nil ->
        :ok

      hands ->
        case GenServer.call(hands, {:hold, handle}, :infinity) do
          :ok -> :ok
          :no_release -> raise ArgumentError, "a tool without release/3 cannot hold a resource"
        end
    end
  end
end
