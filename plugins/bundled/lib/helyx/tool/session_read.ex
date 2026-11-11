defmodule Helyx.Tool.SessionRead do
  @moduledoc """
  The coordinator tool `session_read`: the transcript of a running session
  that the user of the calling session may read, newest messages first to
  fit, or with a `question` the answer of a child session that reads it,
  as the agent tool runs a child (`Helyx.Subagent`). The read takes the
  check of the wire `history` (`Helyx.Hub.authorize/4`). See
  `docs/features/coordinator.md` for the bounds.
  """

  @behaviour Helyx.Tool

  alias Helyx.{Coordinator, Message, Session}

  # The newest messages that a read takes, the most of a snapshot tail.
  @tail 1_000
  # The bytes of transcript that a child reads with the question; the result
  # without a question has the bound of every tool result.
  @child_bytes 262_144
  # The bound of a question: the text of a child prompt is the question and
  # the transcript, far under `Helyx.Session.max_text_bytes/0`.
  @max_question_bytes 16_384
  @left_out "[earlier messages left out]\n\n"

  @impl true
  def name, do: "session_read"

  @impl true
  def concurrent?, do: true

  @impl true
  def description do
    "Read the transcript of a running session, newest messages kept. With a question, a " <>
      "helper agent reads the transcript and gives only its answer to the question."
  end

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "id" => %{"type" => "string", "description" => "The id of the session"},
        "question" => %{
          "type" => "string",
          "description" => "Optional: what to find out from the transcript"
        }
      },
      "required" => ["id"]
    }
  end

  @impl true
  def run(%{"id" => id} = args, cwd) do
    question = Map.get(args, "question", "")

    with :ok <- checked(id, question),
         {:ok, env} <- Coordinator.setup(),
         :ok <- authorized(env, id),
         {:ok, text} <- read(Coordinator.session(env, id), budget(question)) do
      answer(env, text, question, cwd)
    else
      {:error, text} when is_binary(text) -> {:error, "session_read: " <> text}
    end
  end

  def run(_args, _cwd), do: {:error, "session_read needs an id"}

  # The child stays held while its owner reports no stop (`Helyx.Subagent`).
  @impl true
  def release(children, _mode, deadline), do: Helyx.Subagent.release(children, deadline)

  defp checked(id, question) do
    cond do
      not Coordinator.id?(id) -> {:error, "the id must be a session id"}
      not is_binary(question) -> {:error, "the question must be a string"}
      byte_size(question) > @max_question_bytes -> {:error, "the question is too long"}
      true -> :ok
    end
  end

  defp authorized(env, id) do
    case Helyx.Hub.authorize(env.hub, env.user, "history", %{"session" => id}) do
      :ok -> :ok
      {:error, reason} -> {:error, Coordinator.text(reason)}
    end
  end

  defp budget(""), do: Message.max_result_bytes()
  defp budget(_question), do: @child_bytes

  # The snapshot is read and rendered in a process of its own: its
  # subscription ends with it, so no event of the session reaches the Task
  # of the call, and the Task holds only the text within the budget.
  defp read(session, budget) do
    task =
      Task.async(fn ->
        case Session.subscribe(session, tail: @tail) do
          {:ok, snapshot, _ref} -> {:ok, render(session.id, snapshot, budget)}
          {:error, reason} -> {:error, Coordinator.text(reason)}
        end
      end)

    Task.await(task, :infinity)
  end

  defp answer(_env, text, "", _cwd), do: {:ok, text}

  defp answer(env, text, question, cwd) do
    context = env.context

    opts = [
      model: context.model,
      cwd: cwd,
      provider_opts: context.provider_opts,
      model_context: context.model_context,
      parent: %{session_id: context.session_id, call_id: context.call_id},
      # The child reads the text of its prompt and runs no tool.
      tools: []
    ]

    prompt =
      "Answer the question from the transcript of a session below. Give only the answer.\n\n" <>
        "Question: " <> question <> "\n\nTranscript:\n\n" <> text

    case Helyx.Subagent.run(env.core, context.session_id, opts, prompt) do
      {:error, {:start, reason}} ->
        {:error, "session_read: the helper agent did not start: " <> Coordinator.text(reason)}

      {:error, text} ->
        {:error, "session_read: " <> text}

      ok ->
        ok
    end
  end

  # The newest messages that fit in `budget` bytes with the head line, in
  # order. A message that does not fit is cut to its end and is the last
  # one kept, so the text never passes the budget.
  @doc false
  def render(id, snapshot, budget) do
    state = if snapshot.turn, do: "a turn runs", else: "no turn runs"
    head = "session #{id}, #{state}\n\n"
    room = budget - byte_size(head) - byte_size(@left_out)
    {parts, cut?} = newest(Enum.reverse(snapshot.messages), room, [])
    left_out = if cut? or snapshot.older > 0, do: @left_out, else: ""
    IO.iodata_to_binary([head, left_out | parts])
  end

  defp newest([], _room, acc), do: {acc, false}

  defp newest([message | rest], room, acc) do
    part = part(message) <> "\n\n"

    if byte_size(part) <= room,
      do: newest(rest, room - byte_size(part), [part | acc]),
      else: {[Helyx.Text.cap(part, room, :tail) | acc], true}
  end

  defp part(%Message{role: :user} = m), do: "user: " <> Message.text(m)

  defp part(%Message{role: :assistant, content: content} = m) do
    calls = for %Message.ToolCall{name: name} <- content, do: " [tool call: #{name}]"
    IO.iodata_to_binary(["assistant: ", Message.text(m) | calls])
  end

  defp part(%Message{role: :tool_result} = m),
    do: "tool result (#{m.tool_name}): " <> Message.text(m)
end
