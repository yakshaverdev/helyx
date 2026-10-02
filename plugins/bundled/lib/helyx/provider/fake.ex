defmodule Helyx.Provider.Fake do
  @moduledoc """
  A provider that replays scripted responses. For tests and demos.

  The `echo` model streams the last user message back, one word per delta.
  The `system` model streams the system prompt of the context back. Any
  other model name replays responses registered with `script/3`, one
  response per call, in order. A response is a list of text deltas and tool
  calls. A response with a tool call stops with `:tool_use`.

      call = %Helyx.Message.ToolCall{id: "c1", name: "bash", arguments: %{"command" => "ls"}}
      :ok = Helyx.Provider.Fake.script(core, "lister", [["Listing.", call], ["Done."]])
      {:ok, session} = Helyx.Session.start(core, model: "fake/lister")

  Scripts live in an Agent that Core starts with the plugin, so each Core
  instance has its own scripts.
  """

  use Helyx.Provider.Loop

  @impl true
  def id, do: "fake"

  @doc "Starts the scripts Agent under Core. Core calls this with `core: name`."
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    core = Keyword.fetch!(opts, :core)
    %{id: __MODULE__, start: {Agent, :start_link, [fn -> %{} end, [name: scripts(core)]]}}
  end

  @doc "Registers the responses a scripted model replays, one per call."
  @spec script(Helyx.Core.name(), String.t(), [[String.t() | Helyx.Message.ToolCall.t()]]) :: :ok
  def script(core, model, responses) when is_list(responses) do
    Agent.update(scripts(core), &Map.put(&1, model, responses))
  end

  @impl true
  def stream("echo", %Helyx.Context{messages: messages}, _opts) do
    text =
      messages
      |> Enum.reverse()
      |> Enum.find(&(&1.role == :user))
      |> Helyx.Message.text()

    {:ok, deltas_to_stream(words(text))}
  end

  def stream("system", %Helyx.Context{system: system}, _opts) do
    {:ok, deltas_to_stream([system || "no system"])}
  end

  def stream(model, _context, opts) do
    core = Keyword.fetch!(opts, :core)

    scripts(core)
    |> Agent.get_and_update(fn state ->
      case Map.get(state, model) do
        [response | rest] -> {{:ok, response}, Map.put(state, model, rest)}
        _ -> {{:error, {:no_script, model}}, state}
      end
    end)
    |> case do
      {:ok, response} -> {:ok, deltas_to_stream(response)}
      error -> error
    end
  end

  defp deltas_to_stream(deltas) do
    events = Enum.map(deltas, &to_event/1)
    stop = if Enum.any?(events, &match?({:tool_call, _}, &1)), do: :tool_use, else: :end_turn
    Stream.concat(events, [{:done, %{stop_reason: stop, usage: %{}}}])
  end

  defp to_event(%Helyx.Message.ToolCall{} = call), do: {:tool_call, call}
  defp to_event(text) when is_binary(text), do: {:text_delta, text}

  # Splits "hello there" into ["hello", " there"], keeping the spaces.
  defp words(text) do
    Regex.scan(~r/\s*\S+/, text) |> List.flatten()
  end

  defp scripts(core), do: Module.concat(core, __MODULE__)
end
