defmodule Helyx.Test.Gate do
  @moduledoc false
  # A tool that tells the process registered as "gate" it runs, then waits
  # for :go. `stream/2` gives the same stop to a provider's stream.
  @behaviour Helyx.Tool

  @impl true
  def name, do: "gate"
  @impl true
  def description, do: "Waits for the test."
  @impl true
  def parameters, do: %{"type" => "object"}
  @impl true
  def run(%{"gate" => gate}, _cwd), do: wait(gate)

  # Registers the test process under a new gate name, and returns the name.
  def open do
    gate = :"gate_#{System.unique_integer([:positive])}"
    Process.register(self(), gate)
    Atom.to_string(gate)
  end

  # The stream of `steps`: each `:gate` sends {:waiting, pid} to the gate
  # and waits for :go.
  def stream(steps, gate) do
    Stream.flat_map(steps, fn
      :gate ->
        wait(gate)
        []

      event ->
        [event]
    end)
  end

  defp wait(gate) do
    send(String.to_existing_atom(gate), {:waiting, self()})

    receive do
      :go -> {:ok, "done"}
    end
  end
end

defmodule Helyx.Test.Gated.Local do
  @moduledoc false
  # A provider with a local turn. The model is the name of the gate. The
  # last message of the context picks the reply:
  #
  #   "ok"     a text delta, the gate, more text, one gate call
  #   "fail"   a text delta, the gate, then a stream error
  #   "abort"  a text delta, the gate, more text, two gate calls
  #   other    the text "done"
  @behaviour Helyx.Provider

  alias Helyx.Message

  @impl true
  def id, do: "gated"

  @impl true
  def stream(gate, %Helyx.Context{messages: messages}, _opts) do
    last = List.last(messages)
    text = if last.role == :user, do: Message.text(last)
    {:ok, Helyx.Test.Gate.stream(steps(text, gate), gate)}
  end

  defp steps("ok", gate),
    do: [{:text_delta, "hel"}, :gate, {:text_delta, "lo"}] ++ calls(gate, 1)

  defp steps("fail", _gate), do: [{:text_delta, "hel"}, :gate, {:error, :boom}]

  defp steps("abort", gate),
    do: [{:text_delta, "hel"}, :gate, {:text_delta, "lo"}] ++ calls(gate, 2)

  defp steps(_other, _gate), do: [{:text_delta, "done"}, done(:end_turn)]

  defp calls(gate, count) do
    Enum.map(1..count, fn n ->
      {:tool_call, %Message.ToolCall{id: "t#{n}", name: "gate", arguments: %{"gate" => gate}}}
    end) ++ [done(:tool_use)]
  end

  defp done(stop), do: {:done, %{stop_reason: stop, usage: %{}}}
end

defmodule Helyx.Test.Gated.Connected do
  @moduledoc false
  # A connected provider; its id is the one of `Gated.Local`, so a Core
  # registers one of the two. The model is "<shape>.<gate>": the events of
  # a turn stop at the gate until the test sends :go to the harness
  # process. The harness process tells the gate only in its next message,
  # after the events before the gate reached the session. Every other
  # request gets `:ok`.
  #
  #   calls    three tool calls and a message end, the gate, the three
  #            results, then a text
  #   partial  a text delta, the gate, then more text
  #   fail     a text delta, the gate, then a stream error
  #   dangling a tool call, then the end of the turn (no gate)
  #   dup_id   two tool calls with one id and a message end, the first
  #            result, the gate, the second result, then a text
  @behaviour Helyx.Provider

  alias Helyx.Message

  @impl true
  def id, do: "gated"

  @impl true
  def harness_init(model, _tools, _opts) do
    [shape, gate] = String.split(model, ".")
    {:ok, %{shape: shape, gate: gate, turn: nil, rest: []}}
  end

  @impl true
  def harness_request({:turn, turn_id, _context}, from, state) do
    steps = steps(state.shape) ++ [{:done, %{stop_reason: :end_turn, usage: %{}}}]
    {actions, state} = run(steps, %{state | turn: turn_id})
    {:ok, [{:reply, from, :ok} | actions], state}
  end

  def harness_request(_request, from, state), do: {:ok, [{:reply, from, :ok}], state}

  @impl true
  def harness_info(:gate, state) do
    send(String.to_existing_atom(state.gate), {:waiting, self()})
    {:ok, [], state}
  end

  def harness_info(:go, state) do
    {actions, state} = run(state.rest, state)
    {:ok, actions, state}
  end

  # The events up to the gate, and the rest for :go.
  defp run(steps, state) do
    {now, rest} = Enum.split_while(steps, &(&1 != :gate))

    rest =
      case rest do
        [:gate | rest] ->
          send(self(), :gate)
          rest

        [] ->
          []
      end

    {Enum.map(now, &{:event, state.turn, &1}), %{state | rest: rest}}
  end

  defp steps("calls") do
    calls = for id <- ~w(c1 c2 c3), do: %Message.ToolCall{id: id, name: "x", arguments: %{}}

    Enum.map(calls, &{:tool_call, &1}) ++
      [{:message_end, :tool_use, %{}}, :gate] ++
      Enum.map(calls, &{:tool_result, &1.id, {:ok, "r"}}) ++ [{:text_delta, "end"}]
  end

  defp steps("partial"), do: [{:text_delta, "hel"}, :gate, {:text_delta, "lo"}]
  defp steps("fail"), do: [{:text_delta, "hel"}, :gate, {:error, :boom}]

  defp steps("dangling"),
    do: [{:tool_call, %Message.ToolCall{id: "d", name: "x", arguments: %{}}}]

  defp steps("dup_id") do
    [
      {:tool_call, %Message.ToolCall{id: "t", name: "read", arguments: %{}}},
      {:tool_call, %Message.ToolCall{id: "t", name: "bash", arguments: %{}}},
      {:message_end, :tool_use, %{}},
      {:tool_result, "t", {:ok, "one"}},
      :gate,
      {:tool_result, "t", {:ok, "two"}},
      {:text_delta, "end"}
    ]
  end
end
