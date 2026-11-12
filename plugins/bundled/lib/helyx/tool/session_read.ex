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
  alias Helyx.Tool.Args

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
          "maxLength" => @max_question_bytes,
          "default" => "",
          "description" => "Optional: what to find out from the transcript"
        }
      },
      "required" => ["id"]
    }
  end

  @impl true
  def run(args, cwd) do
    with {:ok, args} <- Args.check(args, parameters()),
         :ok <- checked(args["id"]),
         {:ok, env} <- Coordinator.setup(),
         :ok <- authorized(env, args["id"]),
         {:ok, text} <- read(Coordinator.session(env, args["id"]), budget(args["question"])) do
      answer(env, text, args["question"], cwd)
    else
      {:error, text} when is_binary(text) -> {:error, "session_read: " <> text}
    end
  end

  # The child stays held while its owner reports no stop (`Helyx.Subagent`).
  @impl true
  def release(children, _mode, deadline), do: Helyx.Subagent.release(children, deadline)

  defp checked(id) do
    if Coordinator.id?(id),
      do: :ok,
      else: {:error, "the id must be a session id"}
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
  # of the call, and the Task holds only the text within the budget. A
  # session that a stop unloaded is read from its file, with no process
  # (docs/features/idle-unload.md).
  defp read(session, budget) do
    task =
      Task.async(fn ->
        case Session.subscribe(session, tail: @tail) do
          {:ok, snapshot, _ref} -> {:ok, render(session.id, snapshot, budget)}
          {:error, :session_not_found} -> read_saved(session, budget)
          {:error, reason} -> {:error, Coordinator.text(reason)}
        end
      end)

    Task.await(task, :infinity)
  end

  # A stopped session is read from its file, as a live idle session is read
  # from its snapshot: no turn, the same messages, the same budget.
  defp read_saved(%Session{core: core, id: id}, budget) do
    with dir when is_binary(dir) <- Helyx.Core.config(core, :sessions_dir),
         {:ok, path, cwd} <- Helyx.Session.File.pick(dir, nil, id: id),
         {:ok, resumed, _tail, _limits} <- Helyx.Session.File.read_picked(path, cwd, []) do
      {:ok, render_body(id, resumed.messages, false, false, budget)}
    else
      {:error, reason} -> {:error, Coordinator.text(reason)}
      _missing -> {:error, Coordinator.text(:session_not_found)}
    end
  end

  defp answer(_env, text, "", _cwd), do: {:ok, text}

  defp answer(env, text, question, cwd) do
    prompt =
      "Answer the question from the transcript of a session below. Give only the answer.\n\n" <>
        "Question: " <> question <> "\n\nTranscript:\n\n" <> text

    # The child reads the text of its prompt and runs no tool.
    case Helyx.Subagent.run(env.context, cwd, [], prompt) do
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
    render_body(id, snapshot.messages, snapshot.turn != nil, snapshot.older > 0, budget)
  end

  # The text of the messages, with the head line and a note when messages are
  # left out.
  defp render_body(id, messages, turn?, older?, budget) do
    state = if turn?, do: "a turn runs", else: "no turn runs"
    head = "session #{id}, #{state}\n\n"
    room = budget - byte_size(head) - byte_size(@left_out)
    {parts, cut?} = newest(Enum.reverse(messages), room, [])
    left_out = if cut? or older?, do: @left_out, else: ""
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
