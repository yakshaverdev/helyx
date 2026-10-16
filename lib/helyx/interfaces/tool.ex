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
  caller, before any file or process is created (`check_available/1`). A
  tool that needs something from the system, an executable for example,
  reports it missing there. Then the session fails to start with a clear
  error, and no call fails later for that reason.

  A tool that creates an OS resource, a process group for example, holds it
  with `hold/1` before the external work starts, and implements the
  optional `release/3`. The hands call `release(handles, mode, deadline)`
  with the handles of a call when it delivers (`:deliver`), and when its
  turn is aborted (`:cancel`). `deadline` is absolute, in
  `System.monotonic_time(:millisecond)` on the node of the hands. The return
  value is the handles still held; `[]` means every one is released. The
  callback must not wait past the deadline. The tool must also free the
  resource by itself when its Task dies with no release, because the hands
  can die first and drop a late `hold/1` (ADR 0004).

  A call can go on in the background: the tool takes a place with
  `background/0` before the external work starts, gives its start answer
  with `started/1`, and keeps running. Its return value is then the end of
  the run, which reaches the session as a user message. An abort of the
  turn does not end it; the stop of the session does
  (`docs/features/background-bash.md`).
  """

  use Helyx.Interface, mode: :multi

  @type spec :: %{name: String.t(), description: String.t(), parameters: map()}

  @callback name() :: String.t()
  @callback description() :: String.t()
  @callback parameters() :: map()
  @callback run(arguments :: map(), cwd :: String.t()) :: {:ok, String.t()} | {:error, String.t()}
  @callback check() :: :ok | {:error, String.t()}
  @callback release(
              handles :: [term()],
              mode :: :deliver | :cancel,
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
  string keys at the top level that `Helyx.Message.encoded_size/1` accepts.
  Otherwise the result is `{:error, {:bad_tool_spec, label}}`: the label is
  the name when the name is accepted, else the module name. Plugin code that
  raises, throws, or exits while a spec is built is not contained. Two tools
  with one name give `{:error, {:duplicate_tool_name, name}}`.
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
  Runs the optional `check/0` of each tool that `specs/1` returned, in that
  order, and stops at the first failure. `{:error, reason}` with a reason
  of valid UTF-8 gives `{:error, {:tool_unavailable, name, reason}}`, where
  `name` is the checked spec name. Any other value but `:ok` raises in the
  caller, as a `check/0` that raises, throws, or exits does: Core does not
  contain it.
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
  process created, with the hands that run it. The hands keep the handle
  outside the Task and give it to the `release/3` of the tool or the
  provider. They release the handle of a tool call when the call delivers,
  or when its turn ends while the call runs. They release the handle of a
  provider process when the process ends. Once a release leaves a handle
  unconfirmed, the hands refuse every later tool call
  (`docs/features/tool-resource-release.md`). When the hands stop first,
  no release runs: the tool or the provider must free the resource when
  its own process dies (ADR 0004).
  Returns only when the hands hold the handle, so work that starts after it
  is never unheld. Exits when the caller runs outside the hands, such as
  `stream/3` in the model Task of `Helyx.Provider.Loop`: a provider holds
  only from the callbacks of its provider process. Raises when the tool or
  the provider does not implement `release/3`.
  """
  @spec hold(term()) :: :ok
  def hold(handle) do
    case GenServer.call(Process.get(:helyx_hands), {:hold, handle}, :infinity) do
      :ok -> :ok
      :no_release -> raise ArgumentError, "a tool without release/3 cannot hold a resource"
    end
  end

  @doc """
  Takes a place for a background run of the calling tool call, before its
  external work starts. Returns the id of the run and the background
  folder of the session, mode `0700`, which the session deletes at its
  stop; a tool keeps its files there, named by the id. `{:error, text}`
  with no place: the session's 16 places are taken, the folder cannot be
  made, or the caller is a Task of the hands that is no tool call. A
  second call gives a new id in the same place. A run that gave its start
  answer keeps its place until a turn takes its end; any other call frees
  it when its Task ends. Exits outside the hands, as `hold/1` does.
  """
  @spec background() :: {:ok, %{id: String.t(), dir: String.t()}} | {:error, String.t()}
  def background, do: GenServer.call(Process.get(:helyx_hands), :background, :infinity)

  @doc """
  Gives the start answer of a background run: `text` becomes the result of
  the call at once, and the tool's Task leaves its turn. The Task then
  runs on; its return value, or its crash, is the end of the run. Raises
  in a Task that is no tool call of a turn, such as a run that gave its
  start answer, and in a tool call that took no place with
  `background/0`. Exits outside the hands, as `hold/1` does.
  """
  @spec started(String.t()) :: :ok
  def started(text) when is_binary(text) do
    case GenServer.call(Process.get(:helyx_hands), {:started, text}, :infinity) do
      :ok -> :ok
      :no_place -> raise ArgumentError, "started/1 needs a place from background/0"
    end
  end
end
