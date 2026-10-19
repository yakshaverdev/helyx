defmodule Helyx.Test.SummaryProvider do
  @moduledoc false
  # A model provider for the summary tests (summary-compaction.md). A call
  # whose system prompt is "SUMMARIZE" is a summary call: the text of its
  # one message selects the answer. "ok" the text "the summary", "max" a
  # text of exactly 65,536 bytes, "big" one byte more, "fail" an error,
  # "tool" a tool call, "empty" no text, "cut" a text cut at max_tokens,
  # "hang" a stream that blocks. Any
  # other call streams every message of the context as "role:text" lines,
  # unless the last user message starts with "overflow" and the context has
  # no summary, or is "overflow_always": then the call fails with a context
  # overflow. The message `{:again, why}` sends a second context request
  # for the open turn. A provider option `report: pid` sends each `init/3`
  # options to `pid`.
  @behaviour Helyx.Provider
  @behaviour Helyx.Provider.Loop

  @done {:done, %{stop_reason: :end_turn, usage: nil}}

  @impl true
  def id, do: "sum"

  @impl Helyx.Provider
  def init(model, _tools, opts) do
    if pid = opts[:report], do: send(pid, {:sum_init, opts})
    {:ok, Helyx.Provider.Loop.new(__MODULE__, model, opts)}
  end

  @impl Helyx.Provider
  defdelegate request(request, from, state), to: Helyx.Provider.Loop

  @impl Helyx.Provider
  def info({:again, :auto}, state), do: {:ok, [{:need_context, state.turn}], state}
  def info({:again, why}, state), do: {:ok, [{:need_context, state.turn, why}], state}
  def info(message, state), do: Helyx.Provider.Loop.info(message, state)

  @impl true
  def stream(_model, %Helyx.Context{system: "SUMMARIZE", messages: [message]}, _opts) do
    case Helyx.Message.text(message) do
      "ok" -> {:ok, [{:text_delta, "the "}, {:text_delta, "summary"}, @done]}
      "max" -> {:ok, [{:text_delta, String.duplicate("x", 65_535) <> "y"}, @done]}
      "big" -> {:ok, [{:text_delta, String.duplicate("x", 65_536)}, {:text_delta, "y"}, @done]}
      "fail" -> {:error, :boom}
      "tool" -> {:ok, [{:tool_call, %Helyx.Message.ToolCall{id: "c", name: "x", arguments: %{}}}]}
      "empty" -> {:ok, [@done]}
      "cut" -> {:ok, [{:text_delta, "half"}, {:done, %{stop_reason: :max_tokens, usage: nil}}]}
      "hang" -> {:ok, Stream.repeatedly(fn -> Process.sleep(:infinity) end)}
    end
  end

  def stream(_model, %Helyx.Context{messages: messages}, _opts) do
    last = messages |> Enum.filter(&(&1.role == :user)) |> List.last() |> Helyx.Message.text()
    summary? = Enum.any?(messages, &String.starts_with?(Helyx.Message.text(&1), "S:"))

    if last == "overflow_always" or (String.starts_with?(last, "overflow") and not summary?) do
      {:ok, [{:error, {:context_overflow, "too long"}}]}
    else
      lines = Enum.map_join(messages, "\n", &"#{&1.role}:#{Helyx.Message.text(&1)}")
      {:ok, [{:text_delta, lines}, @done]}
    end
  end
end

defmodule Helyx.Test.SummaryPlugin do
  @moduledoc false
  # A compaction plugin for the summary tests. With a summary, the context
  # is "S:<text>" and the messages from its first kept message on. It
  # sends `{:compact, trigger}` to the controller of `Helyx.Test.Connected`
  # of its Core, if any.
  #
  # A plan keeps the last user message, has tokens_before 42, and has a
  # mode as the text of the summary call. With any trigger but nil, a last
  # user message "summarize:<mode>" that no summary keeps asks with the
  # mode. Else `:manual` asks with "ok", or "fail" for the instructions
  # "fail", and `:overflow` with "ok", or the mode of "overflow:<mode>".
  # "summarize:again" asks with any trigger, "summarize:bad_id" names an
  # id that no message has, and "plugin_error" returns an error at
  # `:manual`.
  @behaviour Helyx.Compaction

  alias Helyx.{Context, Message}

  @impl true
  def compact(context, opts) do
    ctl = Process.whereis(Helyx.Test.Connected.controller(opts[:core]))
    if ctl, do: send(ctl, {:compact, opts[:trigger]})
    summary = opts[:summary]
    user = context.messages |> Enum.filter(&(&1.role == :user)) |> List.last()
    text = user && Message.text(user)
    kept? = summary != nil and summary.first_kept_id == user.id

    case mode(opts[:trigger], text, kept?, opts[:instructions]) do
      nil -> with_summary(context, summary)
      :error -> {:error, "nope"}
      :bad_id -> plan(%{user | id: "missing"}, "ok")
      mode -> plan(user, mode)
    end
  end

  defp mode(:manual, "plugin_error", _kept?, _instructions), do: :error
  defp mode(_trigger, "summarize:again", _kept?, _instructions), do: "ok"
  defp mode(_trigger, "summarize:bad_id", _kept?, _instructions), do: :bad_id
  defp mode(trigger, "summarize:" <> mode, false, _instructions) when trigger != nil, do: mode
  defp mode(:manual, _text, _kept?, "fail"), do: "fail"
  defp mode(:manual, _text, _kept?, _instructions), do: "ok"
  defp mode(:overflow, "overflow:" <> mode, _kept?, _instructions), do: mode
  defp mode(:overflow, _text, _kept?, _instructions), do: "ok"
  defp mode(_trigger, _text, _kept?, _instructions), do: nil

  defp plan(user, mode) do
    context = %Context{system: "SUMMARIZE", messages: [Message.user(mode)]}
    {:summarize, %Helyx.Summary.Plan{context: context, first_kept_id: user.id, tokens_before: 42}}
  end

  defp with_summary(context, nil), do: context

  defp with_summary(context, summary) do
    kept = Enum.drop_while(context.messages, &(&1.id != summary.first_kept_id))
    %{context | messages: [Message.user("S:" <> summary.text) | kept]}
  end
end
