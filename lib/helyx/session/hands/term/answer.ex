defmodule Helyx.Session.Hands.Term.Answer do
  @moduledoc false
  # The answers that the session sends to its hands: the answer to an ask, to a
  # UI block, and to a transcript request. The answers that the hands send are
  # in `Helyx.Session.Hands.Term.Answer.Hands`.

  alias Helyx.Session
  alias Helyx.Session.Hands.Term.Data

  @kinds [
    ask_answer: "hands.ask_answer",
    show_answer: "hands.show_answer",
    transcript_answer: "hands.transcript_answer"
  ]

  @doc false
  def kinds, do: @kinds

  @doc false
  def direction(_tag), do: :session_to_hands

  def check(%{t: :ask_answer, instance: instance, ok: true, answer: answer} = term) do
    if map_size(term) == 4 and Data.id?(instance) and Session.check_answer(answer) == :ok,
      do: {:ok, term},
      else: :error
  end

  def check(%{t: :ask_answer, instance: instance, error: error} = term) do
    if map_size(term) == 3 and Data.id?(instance) and error in [:no_client, :not_running],
      do: {:ok, term},
      else: :error
  end

  def check(%{t: :show_answer, instance: instance, result: result} = term) do
    if map_size(term) == 3 and Data.id?(instance) and result in [:ok, :too_many],
      do: {:ok, term},
      else: :error
  end

  def check(%{t: :show_answer, instance: instance, error: error} = term) do
    if map_size(term) == 3 and Data.id?(instance) and error in [:not_running, :too_many_blocks],
      do: {:ok, term},
      else: :error
  end

  def check(%{t: :transcript_answer, instance: instance, messages: messages} = term) do
    if map_size(term) == 3 and Data.id?(instance) and Data.list?(messages, &Data.message?/1),
      do: {:ok, term},
      else: :error
  end

  def check(%{t: :transcript_answer, instance: instance, error: error} = term) do
    if map_size(term) == 3 and Data.id?(instance) and Data.reason?(error),
      do: {:ok, term},
      else: :error
  end

  def check(_term), do: :error

  # --- the JSON map of each answer ---

  @doc false
  def encode(%{t: :ask_answer, ok: true} = term) do
    {:ok,
     %{
       "t" => "hands.ask_answer",
       "instance" => term.instance,
       "ok" => true,
       "answer" => term.answer
     }}
  end

  def encode(%{t: :ask_answer} = term) do
    {:ok,
     %{
       "t" => "hands.ask_answer",
       "instance" => term.instance,
       "error" => Atom.to_string(term.error)
     }}
  end

  def encode(%{t: :show_answer, result: result} = term) do
    {:ok,
     %{
       "t" => "hands.show_answer",
       "instance" => term.instance,
       "result" => Atom.to_string(result)
     }}
  end

  def encode(%{t: :show_answer} = term) do
    {:ok,
     %{
       "t" => "hands.show_answer",
       "instance" => term.instance,
       "error" => Atom.to_string(term.error)
     }}
  end

  def encode(%{t: :transcript_answer, error: error} = term) do
    {:ok, %{"t" => "hands.transcript_answer", "instance" => term.instance, "error" => error}}
  end

  def encode(%{t: :transcript_answer} = term) do
    {:ok,
     %{
       "t" => "hands.transcript_answer",
       "instance" => term.instance,
       "messages" => Enum.map(term.messages, &Data.message_to_map/1)
     }}
  end

  # --- the answer of a JSON map ---

  @doc false
  def decode(%{"t" => "hands.ask_answer", "ok" => true} = map) do
    Data.decode_fields(map, ~w(instance ok answer), fn [instance, true, answer] ->
      check(%{t: :ask_answer, instance: instance, ok: true, answer: answer})
    end)
  end

  def decode(%{"t" => "hands.ask_answer"} = map) do
    Data.decode_fields(map, ~w(instance error), fn [instance, error] ->
      with {:ok, error} <- answer_error(error) do
        check(%{t: :ask_answer, instance: instance, error: error})
      end
    end)
  end

  def decode(%{"t" => "hands.show_answer", "result" => result} = map) when is_binary(result) do
    Data.decode_fields(map, ~w(instance result), fn [instance, result] ->
      with {:ok, result} <- show_result(result) do
        check(%{t: :show_answer, instance: instance, result: result})
      end
    end)
  end

  def decode(%{"t" => "hands.show_answer"} = map) do
    Data.decode_fields(map, ~w(instance error), fn [instance, error] ->
      with {:ok, error} <- show_error(error) do
        check(%{t: :show_answer, instance: instance, error: error})
      end
    end)
  end

  def decode(%{"t" => "hands.transcript_answer", "messages" => messages} = map)
      when is_list(messages) do
    Data.decode_fields(map, ~w(instance messages), fn [instance, messages] ->
      with {:ok, messages} <- to_messages(messages) do
        check(%{t: :transcript_answer, instance: instance, messages: messages})
      end
    end)
  end

  def decode(%{"t" => "hands.transcript_answer"} = map) do
    Data.decode_fields(map, ~w(instance error), fn [instance, error] ->
      check(%{t: :transcript_answer, instance: instance, error: error})
    end)
  end

  def decode(_map), do: :error

  defp answer_error("no_client"), do: {:ok, :no_client}
  defp answer_error("not_running"), do: {:ok, :not_running}
  defp answer_error(_error), do: :error

  defp show_result("ok"), do: {:ok, :ok}
  defp show_result("too_many"), do: {:ok, :too_many}
  defp show_result(_result), do: :error

  defp show_error("not_running"), do: {:ok, :not_running}
  defp show_error("too_many_blocks"), do: {:ok, :too_many_blocks}
  defp show_error(_error), do: :error

  defp to_messages(messages) do
    messages
    |> Enum.reduce_while({:ok, []}, fn message, {:ok, acc} ->
      case Data.to_message(message) do
        {:ok, message} -> {:cont, {:ok, [message | acc]}}
        :error -> {:halt, :error}
      end
    end)
    |> Data.reversed()
  end
end
