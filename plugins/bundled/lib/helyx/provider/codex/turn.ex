defmodule Helyx.Provider.Codex.Turn do
  @moduledoc false
  # The turn of the program of `Helyx.Provider.Codex`: the open of its
  # thread, the replay of a fresh one, the `turn/start` of a model turn, its
  # interrupt, and the answers to its requests. The functions take and give
  # the provider state.

  import Helyx.Provider.Codex.Wire, only: [open: 2, push: 2, reply: 3, rpc: 3, send_line: 2]

  alias Helyx.{HarnessIO, Message, ProviderError}
  alias Helyx.Provider.Codex
  alias Helyx.Provider.Codex.{Items, Program, Replay, State}

  # The thread is open: the waiting request goes on.
  def opened(%State{phase: {:compacting, _id, from}, fresh?: true} = state) do
    # An interrupt of the compaction waits for its turn, and none comes.
    state = interrupted(push(reply(state, from, :ok), [HarnessIO.no_history(Codex.id())]))
    %{state | phase: :idle}
  end

  def opened(%State{phase: {:compacting, _id, _from}} = state),
    do: rpc(state, "thread/compact/start", %{threadId: state.thread})

  def opened(%State{phase: {:opening, id, from, prompt, history}, fresh?: true} = state),
    do: replay(%{state | fresh?: false}, id, from, prompt, history)

  def opened(%State{phase: {:opening, id, from, prompt, _history}} = state),
    do: start_turn(state, id, from, prompt)

  # The program's turn id comes with the answer, before `turn/started`
  # (research note); a pending interrupt goes out then.
  def answer("turn/start", %{"result" => %{"turn" => %{"id" => turn}}}, state) do
    phase = {:running, State.turn_id(state), turn, :model}
    send_interrupt(reply(%{state | phase: phase}, State.from(state), :ok))
  end

  def answer(
        "thread/inject_items",
        %{"result" => _},
        %State{phase: {:injecting, id, from, prompt}} = state
      ),
      do: start_turn(state, id, from, prompt)

  def answer(
        "thread/compact/start",
        %{"result" => _},
        %State{phase: {:compacting, id, from}} = state
      ),
      do: reply(%{state | phase: {:compacting, id, nil}}, from, :ok)

  def answer(
        "turn/interrupt",
        %{"id" => id, "error" => _} = response,
        %{interrupt: {:sent, from, id}} = state
      ),
      do: reply(%{state | interrupt: nil}, from, {:error, failure("turn/interrupt", response)})

  # The turn's end, not this answer, ends an interrupt. An error after the
  # turn's end, such as `no active turn to interrupt` (research note),
  # belongs to no interrupt, also when a later turn's interrupt is sent.
  def answer("turn/interrupt", _response, state), do: state

  # An error answer to `turn/start` or `thread/inject_items` fails the turn,
  # and the provider process stops.
  def answer(method, response, state),
    do: reply(State.clear_from(state), State.from(state), {:error, failure(method, response)})

  def failure(method, response) do
    text = Items.error_message(response) || "unexpected response"
    ProviderError.reason(Codex.id(), method, text, {:codex, method, ""})
  end

  # A pending interrupt goes out when the turn id is known.
  def send_interrupt(
        %State{interrupt: {:pending, from}, phase: {:running, _id, turn, _mode}} = state
      ) do
    {rpc_id, state} = open(state, "turn/interrupt")

    send_line(state, %{
      id: rpc_id,
      method: "turn/interrupt",
      params: %{threadId: state.thread, turnId: turn}
    })

    %{state | interrupt: {:sent, from, rpc_id}}
  end

  def send_interrupt(state), do: state

  # The interrupt ends with the turn. A later answer to a sent request is
  # not due, and is dropped.
  def interrupted(%State{interrupt: {:pending, from}} = state),
    do: reply(%{state | interrupt: nil}, from, :ok)

  def interrupted(%State{interrupt: {:sent, from, id}} = state),
    do: reply(%{state | interrupt: nil, due: Map.delete(state.due, id)}, from, :ok)

  def interrupted(state), do: state

  defp replay(state, id, from, prompt, history) do
    case Replay.items(history, Codex.id()) do
      {:error, reason} -> reply(state, from, {:error, reason})
      {:ok, items, cut} -> inject(state, id, from, prompt, items, cut)
    end
  end

  defp inject(state, id, from, prompt, [], cut),
    do: state |> push(Program.resume_events(state, cut)) |> start_turn(id, from, prompt)

  defp inject(state, id, from, prompt, items, cut) do
    state = push(state, Program.resume_events(state, cut))

    {rpc_id, state} =
      open(%{state | phase: {:injecting, id, from, prompt}}, "thread/inject_items")

    send_line(state, [
      ~s({"id":#{rpc_id},"method":"thread/inject_items","params":{"threadId":),
      JSON.encode!(state.thread),
      ~s(,"items":[),
      Enum.intersperse(items, ","),
      "]}}"
    ])

    state
  end

  defp start_turn(state, id, from, prompt) do
    input =
      for %Message{content: blocks} <- prompt,
          %Message.Text{text: text} <- blocks,
          text != "",
          do: %{type: "text", text: text}

    rpc(%{state | phase: {:starting, id, from}}, "turn/start", %{
      threadId: state.thread,
      input: input
    })
  end
end
