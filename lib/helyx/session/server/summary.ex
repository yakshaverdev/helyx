defmodule Helyx.Session.Server.Summary do
  @moduledoc false
  # The summary call of a session (docs/features/summary-compaction.md),
  # the only writer of `summary_call` in `Helyx.Session.Server.State`. A
  # plan of the Compaction plugin starts it: a provider process of its own
  # for the provider and model of the turn, under the hands, with no tools
  # and no resume id, that gets one `{:turn, id, context}`. Its text deltas
  # are the summary. The call is `:running` until its terminal or a
  # failure, then `:ending` until the hands send its `provider_down`; the
  # wait after a turn holds until then (`TurnLoop.progress/1`). A plan that
  # comes while the last call ends waits in `next` for that end.

  import Helyx.Session.Server.Events, only: [emit: 3]
  import Helyx.Session.Server.State, only: [ask: 4]

  alias Helyx.Session.{Hands, Id, ProviderProcess, Turn}
  alias Helyx.Session.Server.{Prepare, Records, State, TurnLoop}

  @enforce_keys [:start, :id, :plan]
  defstruct [:pid, :start, :id, :plan, :next, text: [], bytes: 0, status: :running]

  # `start` is the ref of the start request; `pid` is nil until the answer
  # of the hands.
  @type t :: %__MODULE__{
          pid: pid() | nil,
          start: reference(),
          id: String.t(),
          plan: Helyx.Summary.Plan.t(),
          next: Helyx.Summary.Plan.t() | nil,
          text: iodata(),
          bytes: non_neg_integer(),
          status: :running | :ending
        }

  # Asks the hands to start the summary call of `plan` for the current
  # turn; their answer comes to `started/2`.
  @spec start(State.t(), Helyx.Summary.Plan.t()) :: State.t()
  def start(%State{summary_call: %__MODULE__{status: :ending} = call} = state, plan),
    do: %{state | summary_call: %{call | next: plan}}

  def start(%State{summary_call: nil, activity: %Turn{} = turn} = state, plan) do
    args = %{
      provider: turn.provider,
      model: turn.model.model,
      tools: [],
      opts: [resume_id: nil, resume_usage: nil] ++ State.base_opts(state),
      session: self()
    }

    start = Hands.start_provider(state.hands, turn.provider, ProviderProcess.run(args))
    %{state | summary_call: %__MODULE__{start: start, id: Id.new(), plan: plan}}
  end

  # The answer of the hands to the start. A call that ended before it
  # stops its process at once, and waits for its `provider_down`. A start
  # that fails ends the call with no process.
  @spec started(State.t(), {:ok, pid()} | {:error, String.t()}) :: State.t()
  def started(%State{summary_call: call} = state, {:ok, pid}) do
    if call.status == :ending,
      do: Process.exit(pid, {:shutdown, :aborted}),
      else: send(pid, :start)

    %{state | summary_call: %{call | pid: pid}}
  end

  def started(state, {:error, text}), do: ended(state, text)

  # Whether a summary call is open for the turn: running, or a plan that
  # waits for the end of the last call.
  @spec open?(State.t()) :: boolean()
  def open?(%State{summary_call: %__MODULE__{status: :running}}), do: true
  def open?(%State{summary_call: %__MODULE__{next: %Helyx.Summary.Plan{}}}), do: true
  def open?(_state), do: false

  # The turn ended: a running call stops, also one whose start has no
  # answer yet (`started/2`), and a waiting plan is dropped.
  @spec stop(State.t()) :: State.t()
  def stop(%State{summary_call: %__MODULE__{status: :running, pid: pid} = call} = state) do
    if pid, do: Process.exit(pid, {:shutdown, :aborted})
    %{state | summary_call: %{call | status: :ending}}
  end

  def stop(%State{summary_call: %__MODULE__{} = call} = state),
    do: %{state | summary_call: %{call | next: nil}}

  def stop(state), do: state

  # A message of the summary call's process: the server matched its pid or
  # its id. Only its `provider_down` counts once the call ends.
  @spec handle(term(), State.t()) :: State.t()
  def handle({:provider_down, _pid, reason}, state), do: ended(state, reason)

  def handle(_message, %State{summary_call: %__MODULE__{status: :ending}} = state), do: state

  def handle({:provider_ready, pid}, %State{summary_call: call} = state) do
    context = %{call.plan.context | tools: []}
    ask(state, pid, {:turn, call.id, context}, :reply)
    state
  end

  def handle({:stream_event, _id, {:text_delta, text}}, %State{summary_call: call} = state) do
    bytes = call.bytes + byte_size(text)

    if bytes > Helyx.Summary.max_bytes(),
      do: end_call(state, {:error, "the summary is over #{Helyx.Summary.max_bytes()} bytes"}),
      else: %{state | summary_call: %{call | text: [call.text, text], bytes: bytes}}
  end

  def handle({:stream_event, _id, {:message_end, _, _}}, state), do: state
  def handle({:stream_event, _id, {:thinking_delta, _}}, state), do: state

  # Only a complete answer is a summary: a cut or refused text would
  # replace the messages that it covers.
  def handle(
        {:stream_end, _id, {:done, %{stop_reason: :end_turn}}},
        %State{summary_call: call} = state
      ) do
    case IO.iodata_to_binary(call.text) do
      "" -> end_call(state, {:error, "the summary is empty"})
      text -> end_call(state, {:ok, text})
    end
  end

  def handle({:stream_end, _id, {:done, %{stop_reason: reason}}}, state),
    do: end_call(state, {:error, "the summary ended with the stop reason #{reason}"})

  def handle({:stream_end, _id, {:error, reason}}, state), do: end_call(state, {:error, reason})

  # A tool call, a tool request, a context request, or any other event:
  # the summary call has no tools and no turn of the session.
  def handle(message, state), do: end_call(state, {:error, {:bad_summary_event, message}})

  # The end of the call's process, or a start that failed: a running call
  # fails, and a plan that waited starts.
  defp ended(%State{summary_call: call} = state, reason) do
    state = %{state | summary_call: nil}
    state = if call.status == :running, do: fail(state, reason), else: state

    case call.next do
      %Helyx.Summary.Plan{} = plan -> start(state, plan)
      nil -> TurnLoop.progress(state)
    end
  end

  # The call ends: its process closes, and the turn goes on with the
  # summary or with the failure.
  defp end_call(%State{summary_call: call} = state, result) do
    ask(state, call.pid, :close, :close)
    state = %{state | summary_call: %{call | status: :ending}}

    case result do
      {:ok, text} ->
        summary = %Helyx.Summary{
          text: text,
          first_kept_id: call.plan.first_kept_id,
          tokens_before: call.plan.tokens_before
        }

        state |> Records.summary(summary) |> Prepare.summarized()

      {:error, reason} ->
        fail(state, reason)
    end
  end

  # A failed summary keeps the previous state: a compaction turn fails with
  # it, and any other turn goes on with the context of the last summary,
  # after a notice.
  defp fail(%State{activity: %Turn{compact: text}} = state, reason) when is_binary(text),
    do: TurnLoop.fail_turn(failed(reason), state)

  defp fail(state, reason),
    do: state |> emit(:notice, %{text: failed(reason)}) |> Prepare.start(nil)

  defp failed(reason), do: "the summary failed: " <> Helyx.Reason.text(reason)
end
